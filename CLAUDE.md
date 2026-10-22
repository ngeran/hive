# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

HIVE (κυψέλη) is a hands-on network-security + observability lab on a local
single-node k3s cluster (host: `nixos-btw`, LAN IP `10.0.0.31`). It deploys an
"attacker" toolbox pod, a deliberately vulnerable target (OWASP Juice Shop), a
Prometheus/Loki/Grafana stack that visualizes the attack live, a 10-node
Juniper cRPD routing fabric on clabernetes, and NetBox as IPAM/source-of-truth.
The core loops are: run a scan from the attacker pod → watch the dashboard
react; push config to the fabric → verify it with JSNAPy.

This is an **infrastructure-as-manifests** repo, not an application codebase.
There is no test suite and no linter. Every change is a Kubernetes manifest, a
Nix package list, a `just` recipe, or (for the fabric) a JSNAPy test file.

## Phases and namespaces

The repo is split into numbered phase directories. Each is independent and
deployed in order; later phases assume earlier ones exist.

| Dir | Namespace(s) | Deployment(s) | Image source |
|---|---|---|---|
| `01-workspace/` | `redcell` | `redcell-workspace` | **built locally via Nix** (`localhost:5000/redcell-range:latest`, `python3.withPackages`) |
| `02-target/` | `targets` | `juice-shop` | public (`bkimminich/juice-shop:latest`) |
| `03-monitoring/` | `monitoring` | `prometheus`, `loki`, `grafana` + `promtail` DaemonSet, netconf-exporter Deployment, pihole | public images (exporter reuses the phase-01 image) |
| `04-routing/` | `topology` (+ `c9s` = clabernetes operator) | 10 cRPD router pods via clabernetes `Topology` CR | **no image build** — crpd image pre-pushed to `localhost:5000`, operator from ghcr |
| `05-netbox/` | `netbox` | `netbox` + `netbox-db` (postgres) + `netbox-redis` | **built locally via Nix** (`localhost:5000/hive-netbox:latest`, **uv2nix** from `pyproject.toml`+`uv.lock`) |

Phases 01 and 05 build images (with different Nix mechanisms — see below).
Phase 04 builds nothing; phase 02/03 consume public images.

## The build/deploy pipelines

Phases 01 and 05 follow Nikos's Nix-image → k3s pipeline. From the phase dir:

```
nix build .#image          # builds an OCI tarball into ./result (no Dockerfile, no docker daemon)
skopeo copy ... result →   # pushes the tarball to the local registry at localhost:5000
kubectl apply -f manifests/  + rollout restart   # applies + force-repulls (imagePullPolicy: Always)
```

`just deploy` chains all three. Phase 04's `just deploy` only applies
manifests (no image); rewiring the fabric after topology changes is
`just redeploy` (deletes all router pods; the operator recreates them).

**Two non-obvious gotchas (apply to every phase):**
- **Nix flakes only see committed files.** After editing `flake.nix` (or any
  file the flake consumes), you must `git add -A && git commit` before
  `just deploy`, or the build silently uses the old version.
- **Fixed tag `:latest` + `imagePullPolicy: Always` is intentional.** k3s
  re-pulls on every rollout restart rather than trusting a stale cached
  `:latest`. Don't "fix" this by adding version tags or changing to `IfNotPresent`.

### Adding a tool to the attacker pod (01-workspace)

Add a line to the `securityTools` list (or `python3.withPackages`) in
`01-workspace/flake.nix`, then `direnv allow && just deploy`. Nothing else
changes. The image ships *only* the packages listed there — Nix images have
no base layer of standard utilities, so things like `coreutils` are explicit
dependencies.

### Phase 05 (NetBox) dependency rules — different from phase 01

Phase 05 builds its Python env with **uv2nix** from a top-level
`pyproject.toml` + `uv.lock`. The dependency pins **must mirror
`05-netbox/app/requirements.txt`** (the vendored NetBox 4.0.0's own locked
requirements) exactly. Every historical crash in this phase came from drift:
an unpinned `django-debug-toolbar` resolved to 6.x and broke NetBox's
unconditionally-loaded strawberry middleware on every request. To upgrade
NetBox: swap the whole `app/` tree *and* the pin set together. Full story +
from-scratch procedure: `05-netbox/REDEPLOY.md` (authoritative for that
phase; its `README.md` is a stale scaffold template).

### Phase 04 (routing fabric) credentials

NETCONF/SSH to the routers: **`admin`** or **`root`**, both `manolis1` (host
NodePorts `10.0.0.31:3100X` ssh / `3200X` NETCONF, or
`<node>.topology.svc.cluster.local:830` in-cluster). Both accounts are seeded
by the startup ConfigMap. (A 2026-09-06 live-password rotation once left the
committed root hash matching no known password; the ConfigMap now carries a
regenerated `manolis1` hash — salt `MnLs2026` — for both accounts.) Junos
automation tooling (PyEZ + JSNAPy) lives in 04-routing's devShell, not
in the attacker pod.

## Common commands

All commands run from inside the relevant phase directory (each phase has its
own `justfile`):

```bash
# Phase 1 (attacker) — has build/push/shell
cd 01-workspace
just deploy          # build + push + apply + restart (the full loop)
just build           # nix build only, no push
just shell           # kubectl exec into the running attacker pod
just logs            # tail pod logs

# Phase 2 / 3 (target / monitoring) — apply-only
cd 02-target  && just deploy      # or: just status | just logs
cd 03-monitoring && just deploy   # just status | just logs prometheus   (logs takes a component name)

# Phase 4 (routing fabric)
cd 04-routing
just deploy          # apply configs + Topology CR + host-access Services
just redeploy        # delete all router pods (RESETS them to startup-config!)
just status          # topology CRs + pods + operator
just ports           # NodePort table (ssh 3100X / netconf 3200X per node)
just cli p1 "show interfaces eth1"   # one-off Junos command, no login
just save-configs <name> / just load-configs <name>   # config snapshots ↔ nodes
just verify          # JSNAPy checks (tests/*.yml) against all 10 nodes

# Phase 5 (netbox)
cd 05-netbox
just deploy          # build + push + apply + restart
just forward         # port-forward :8001 (foreground)
just forward-bg      # same, background; just forward-stop kills it
```

Every phase also has `just clean` (`kubectl delete -f manifests/`). Tear down
in **reverse** order (05 → 04 → 03 → 02 → 01).

To start/stop without deleting (preserves config), scale to 0/1:
`kubectl scale deploy/<name> -n <ns> --replicas=0`

There is **no lint** in this repo. Validation is `VALIDATION.md` plus,
for the fabric, `just verify` (real JSNAPy assertions — see
`04-routing/tests/README.md`).

## Architecture details that span multiple files

- **Cross-namespace networking is the whole point.** The attacker reaches the
  target via in-cluster DNS: `http://juice-shop.targets.svc.cluster.local:3000`.
  Juice Shop's Service is `ClusterIP` only (off the LAN by default). The single
  command that proves Phases 1+2 work together is:
  `kubectl exec -n redcell deploy/redcell-workspace -- curl -s -o /dev/null -w "%{http_code}\n" http://juice-shop.targets.svc.cluster.local:3000/` → `200`.

- **Least-privilege attacker.** `redcell-workspace` runs as root but with only
  `NET_RAW` + `NET_ADMIN` capabilities (for nmap SYN scans / tcpdump promisc
  mode), not `privileged: true`. `hostNetwork: true` is commented out by default —
  uncommenting it (giving the pod the host's real LAN namespace) is called out in
  the manifest as the single biggest privilege jump in the repo.

- **Prometheus discovers targets by annotation, not hardcoded IPs.** Any pod in
  the cluster annotated `prometheus.io/scrape: "true"` is auto-scraped via the
  `kubernetes-pods` job. To make a new pod visible on the dashboard, add that
  annotation — no Prometheus config edit needed.

- **Promtail is a DaemonSet reading k3s's containerd log path** (`/var/log/pods`)
  via hostPath. This convention is k3s/containerd-specific; the config comments
  call out that a Docker-based cluster would need different path handling.

- **Grafana is the only LAN-exposed component** (NodePort 30300, admin /
  `redcell-admin`). Datasources are provisioned from a ConfigMap on startup; no
  UI click-through needed. Dashboards (MPLS Core — Routing Health) are
  provisioned via `03-monitoring/manifests/14-grafana-dashboards.yaml`.

- **The fabric is stateless between redeploys.** clabernetes re-seeds every
  router from its startup ConfigMap on any pod recreation — running configs do
  NOT survive `just redeploy` even though per-node PVCs exist. The durable
  workflow is `just save-configs <name>` → git → `just load-configs <name>`
  (live commit, no pod churn) → `just verify`.

- **NetBox static files need the initContainer.** NetBox's `settings.py`
  hardcodes `STATIC_ROOT` to `<NetBox dir>/static`; the manifest mounts an
  emptyDir there and an initContainer runs `collectstatic` on every pod start
  (it would otherwise serve nothing after restarts). `/static/` is served by
  whitenoise injected in `05-netbox/app/hive_wsgi.py` — NetBox 4.0's
  `settings.py` reads **no** middleware settings from `configuration.py`
  (`EXTRA_MIDDLEWARE` was never a real setting).

- **Mostly no PersistentVolumeClaims** — Prometheus metrics, Loki logs, and
  Grafana state are ephemeral by design (learning lab), and NetBox's DB too
  (wiping `netbox-db` means re-running `createsuperuser`). The one exception:
  04-routing's per-node PVCs (kept for lab storage, but see above — they don't
  protect running configs).

## Doc/code drift to be aware of

`README.md` and `VALIDATION.md` describe a few things that are **not yet in the
manifests** — they read as forward-looking/aspirational:
- A provisioned **Juice Shop** dashboard ("Juice Shop — Attack Surface",
  uid `redcell-juice-shop`) — the provisioned dashboards in
  `14-grafana-dashboards.yaml` are routing-fabric ones ("MPLS Core — Routing
  Health"); there is no Juice Shop dashboard yet.
- A cAdvisor Prometheus scrape job and `nodes/proxy` RBAC — the Prometheus
  config has only `prometheus` and `kubernetes-pods` jobs.

Also: `05-netbox/README.md` is a leftover scaffold template (FastAPI/pyapp) —
`05-netbox/REDEPLOY.md` is the real doc for that phase.
