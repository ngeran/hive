# Phase 4 — cRPD Routing Fabric on Clabernetes

Ten Juniper **cRPD** (containerized routing protocol daemon, 25.4R1-S2.3)
routers running as a service-provider fabric on the HIVE k3s cluster, managed
by **Clabernetes** (containerlab-on-kubernetes, v0.7.x). The topology and its
point-to-point links live in Kubernetes; the routers themselves ship **no
routing config** — all interface/IGP/MPLS/BGP configuration is pushed via
automation (PyEZ / JSNAPy over NETCONF), which is the point of the lab.

```
            ┌──────────────────────────────┐
            │        P-core (full mesh)    │
            │   p1 ─── p2                  │
            │   │ ╲ ╱  │                   │
            │   │  ╳   │                   │
            │   │ ╱ ╲  │                   │
            │   p3 ─── p4                  │
            └──┬─────┬──┴─────┬─────┬──────┘
        p1,p2 │     │ p3,p4  │     │
          ┌───┴─┐ ┌──┴────┐ ┌─┴───┐ │
          │ rr1 ├──┐   ┌──┼─┐ rr2│ │      rr1──rr2 interconnect
          └─────┘  └───┼──┘ └────┘ │
                 ┌────┴───┐  ┌─────┴──┐
                 │  pe1   │  │  pe2   │
                 └───┬────┘  └────┬───┘
                     │ ce1        │ ce2
```

## Host prerequisites (one-time)

| Requirement | Check / fix |
|---|---|
| k3s running (≥ v1.31) | `kubectl get nodes` |
| cRPD image in local registry | `curl -s localhost:5000/v2/crpd/tags/list` → `25.4R1-S2.3` |
| **MPLS kernel modules loaded** | `ls /proc/sys/net/mpls` — if empty: `sudo modprobe mpls_router mpls_iptunnel`; persist with `boot.kernelModules = [ "mpls_router" "mpls_iptunnel" ];` in NixOS |
| Clabernetes operator | `kubectl -n c9s get pods` — else `just operator` |

> ⚠️ **Without the MPLS modules the fabric silently breaks**: cRPD's per-interface
> init fails (`Error talking to the kernel`), the data interfaces (eth1+) never
> register with rpd, and no protocol will form adjacencies.

## Files

| File | What it is |
|---|---|
| `flake.nix` | devShell (helm, kubectl, skopeo, jq — helm is the one base tool that's missing) |
| `manifests/00-namespace.yaml` | the `topology` namespace |
| `manifests/01-crpd-configs.yaml` | per-node startup configs (ConfigMap `crpd-configs`) — hostname + root password + ssh/netconf **only** |
| `manifests/02-topology.yaml` | the Topology CR: 10 nodes, 17 links, config delivery |
| `manifests/03-host-access.yaml` | NodePort Services for host/LAN access (ssh + netconf per node) |
| `smoke/` | the 2-node validation lab used to de-risk clabernetes+cRPD |

## Common commands

```bash
just deploy     # apply configs + topology (+ watch pods come up)
just status     # topologies / nodes / links CRs + pods + operator
just ports      # host access table (nodePort per node)
just ssh p1     # ssh from the host into a router (root / clab123, then `cli`)
just cli p1 "show interfaces eth1"   # one-off Junos command, no login
just logs p1    # launcher pod logs (containerlab + vxlan wiring)
just verify     # JSNAPy state checks (tests/*.yml) against all 10 nodes
just clean      # delete the topology (operator stays; `helm -n c9s uninstall clabernetes` removes that)
```

## Topology — 17 point-to-point links

`ethN` on each node = the Nth link of that node **in the order listed in
`02-topology.yaml`**. This map is the cabling plan (also in `01-crpd-configs.yaml`):

| Node | eth1 | eth2 | eth3 | eth4 | eth5 |
|---|---|---|---|---|---|
| p1  | p2  | p3  | p4  | pe1 | rr1 |
| p2  | p1  | p3  | p4  | pe1 | rr1 |
| p3  | p1  | p2  | p4  | pe2 | rr2 |
| p4  | p1  | p2  | p3  | pe2 | rr2 |
| pe1 | p1  | p2  | ce1 | —   | —   |
| pe2 | p3  | p4  | ce2 | —   | —   |
| rr1 | p1  | p2  | rr2 | —   | —   |
| rr2 | p3  | p4  | rr1 | —   | —   |
| ce1 | pe1 | —   | —   | —   | —   |
| ce2 | pe2 | —   | —   | —   | —   |

## Accessing the routers

**From the host** (dedicated NodePort Services — no port-forwarding):

```bash
just ssh p1                                   # or manually:
ssh -p 31001 root@10.0.0.31                   # password: manolis1
```

| Node | p1 | p2 | p3 | p4 | pe1 | pe2 | rr1 | rr2 | ce1 | ce2 |
|---|---|---|---|---|---|---|---|---|---|---|
| ssh | 31001 | 31002 | 31003 | 31004 | 31005 | 31006 | 31007 | 31008 | 31009 | 31010 |
| netconf | 32001 | 32002 | 32003 | 32004 | 32005 | 32006 | 32007 | 32008 | 32009 | 32010 |

NETCONF for PyEZ/JSNAPy from the host: `10.0.0.31:3200X`, user `admin`,
password `manolis1`. (root's password was rotated on 2026-09-06 and no longer
matches anything in this repo — use `admin`.)

**From inside the cluster** (e.g. redcell-workspace): every node resolves as
`<node>.topology.svc.cluster.local` — ssh port 22, NETCONF 830:

```python
from jnpr.junos import Device
with Device(host="p1.topology.svc.cluster.local", user="admin",
            passwd="manolis1", port=830) as dev:
    print(dev.cli("show interfaces eth1"))
```

**Without any login** (through the launcher): `just cli <node> "<command>"`.

## Verifying state (JSNAPy)

`just verify` runs JSNAPy snapchecks against **all 10 nodes** over NETCONF —
one NodePort per node, tests live in `tests/*.yml` (see `tests/README.md` for
the format and cRPD quirks). Non-zero exit on any failure, so it chains well
after a config push:

```bash
just load-configs day1-ospf && just verify
just verify intf-basic           # a single suite (file name minus .yml)
```

The devShell (`nix develop` / `direnv allow`) ships the `jsnapy` CLI — it's
packaged in `flake.nix` (not in nixpkgs). First run seeds `~/.jsnapy/`.

## Saving & loading configs (named snapshots)

**The platform truth, learned the hard way:** committed Junos config is NOT
durable on its own. Every redeploy (link change, pod deletion, host reboot)
makes containerlab re-seed each node from its startup-config — anything you
pushed via NETCONF/CLI is discarded. Per-node PVCs are enabled
(`deployment.persistence` in `02-topology.yaml`) and they keep the storage
alive, but they do **not** protect the running config from that re-seed.

The durable answer is named snapshots — export running-configs to files you
keep in git, push them back on demand as live commits (seconds, no pod churn):

```bash
just save-configs day1-ospf     # saves all 10 running-configs to configs/day1-ospf/
just list-configs               # show saved snapshots
just load-configs day1-ospf     # live-commits that snapshot onto all 10 nodes
```

Workflow that survives everything: `save-configs` after each milestone →
redeploy the fabric whenever needed → `load-configs` to restore. Keep the
`configs/` directory in git and you also get config history for free.

## Adding / removing point-to-point links

Links are entries in the `links:` list of `manifests/02-topology.yaml`. The
interface name on each end (`pN:ethX`) is part of the link definition.

**Add a link** (example: a second CE1 uplink `ce1:eth2 ↔ pe1:eth4`):

1. Append to the `links:` list (use the next free ethN on each end):
   ```yaml
   - endpoints: ["ce1:eth2", "pe1:eth4"]
   ```
2. Apply + rebuild the affected nodes' wiring:
   ```bash
   kubectl apply -f manifests/02-topology.yaml
   kubectl -n topology delete pod -l c9s.run/topologyNode=ce1
   kubectl -n topology delete pod -l c9s.run/topologyNode=pe1
   ```
3. Verify:
   ```bash
   kubectl -n topology get links.c9s.run | tail   # new Link CR present
   just cli ce1 "show interfaces eth2"
   ```

**Remove a link**: delete its line from `links:`, apply, delete the two
affected launcher pods (as above).

> ⚠️ ethN is assigned **by link order per node** — if you insert/remove a link in
> the middle of the list, subsequent links renumber on that node. Appending at
> the end (or updating the interface map comment) keeps things predictable.
> Deleting the link from YAML does not auto-clean running containers — the pod
> deletion step is what re-materializes the wiring.

## Adding a cRPD

1. **Node** — in `manifests/02-topology.yaml`:
   - add to `nodes:` under the embedded containerlab topology:
     ```yaml
     p5: { startup-config: /launchfiles/p5.conf }
     ```
   - add a per-node entry under `spec.deployment.filesFromConfigMap` (the map
     is **keyed by node name** — this is how the config reaches the node):
     ```yaml
     p5: [{ configMapName: crpd-configs, filePath: /launchfiles }]
     ```
   - add its `links:` entries.
2. **Config** — in `manifests/01-crpd-configs.yaml`, add `p5.conf`:
   ```
   system {
       host-name p5;
       root-authentication { encrypted-password "$1$kBhANGnc$yFAL0Rbf1jAG9cOupGz.q0"; }  # clab123
       services { ssh; netconf { ssh; } }
   }
   ```
3. *(optional but recommended)* **Host access** — in `manifests/03-host-access.yaml`,
   copy a Service block, change name/selector to `p5`, pick free nodePorts.
4. Apply and watch:
   ```bash
   kubectl apply -f manifests/01-crpd-configs.yaml
   kubectl apply -f manifests/02-topology.yaml
   kubectl apply -f manifests/03-host-access.yaml
   kubectl -n topology get pods -w
   ```

## Removing a cRPD

Delete everything that references it — the node entry, its `filesFromConfigMap`
key, its `links:` entries, its `*.conf` in the ConfigMap, and its host-access
Service — then apply the three manifests. The operator tears the node's
launcher pod and Services down. (If a stale launcher remains:
`kubectl -n topology delete pod -l c9s.run/topologyNode=<node>`.)

## Reloading configs / redeploying

Startup configs are loaded once at deploy. To pick up an edited `*.conf`:

```bash
kubectl apply -f manifests/01-crpd-configs.yaml
kubectl -n topology delete pods --all          # full containerlab redeploy, ~90 s
```

> ⚠️ **Never `docker restart` the nested cRPD containers** (e.g. via the
> launcher). Docker recreates the network sandbox on restart and severs
> containerlab's veths — the node loses all data interfaces. Always redeploy
> through the launcher pod (`kubectl delete pod …`) instead. Also note a
> redeploy resets each node to its startup config — anything pushed via
> automation must be re-pushed.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Protocols form no adjacencies; `show interfaces ethN` → device not found | MPLS kernel modules not loaded on host | `sudo modprobe mpls_router mpls_iptunnel` + redeploy pods |
| Launcher crash-loop: `startup-config file not found` | config delivery mismatch | `spec.deployment.filesFromConfigMap` must be keyed by **node name** |
| Node unreachable after config edits | running config diverged from startup | redeploy pods (resets to ConfigMap config) |
| Manager idle, nothing reconciles | stale manager networking after k3s restart | `kubectl -n c9s rollout restart deploy/clabernetes-manager` |
| Fresh pods can't reach the API (`10.43.0.1:443` timeouts) | pod network wedged by k3s stop/start | `sudo systemctl restart k3s` |
| ssh "password wrong" after adding custom startup-config | `root-authentication` missing (the `clab123` default only applies with *no* custom config) | keep the `root-authentication` line in every `*.conf` |
| ssh password prompt loops, never accepts the password | `root-login allow` missing — Junos sshd refuses root password auth by default | keep `services { ssh { root-login allow; } … }` in every `*.conf` |
| Image pull failures in launcher | registry down / image missing | `curl -s localhost:5000/v2/crpd/tags/list` |
