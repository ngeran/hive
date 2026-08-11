# HIVE- κυψέλη

A hands-on network security + observability lab running on a local k3s
Kubernetes cluster. You get an "attacker" toolbox, a deliberately vulnerable
target to practice against, and a dashboard that shows you the attack as it
happens.

No prior Kubernetes experience required to *run* this lab — this README
covers every command you need. You don't need to understand Kubernetes
internals to use it, only to know that `kubectl` is "the command that talks
to the cluster," the same way `git` is "the command that talks to your repo."

---

## What you're building

| Phase | Folder | What it is |
|---|---|---|
| 1 | `01-workspace/` | The "attacker" pod — a container with nmap, sqlmap, hydra, gobuster, etc. already installed |
| 2 | `02-target/` | OWASP Juice Shop — an intentionally vulnerable web app to practice against |
| 3 | `03-monitoring/` | Prometheus + Loki + Grafana — a dashboard showing traffic/CPU/logs live |
| 4 | `04-netflow/` | Optional — lets the attacker pod see your real home network, plus flow-data collection |

Each phase is independent. You can deploy 1 and 2 only, and stop there, and
everything still works.

---

## One-time setup (do this once)

You need `direnv`, `nix`, `just`, `kubectl`, and `skopeo` on your machine —
if you're following this on Nikos's NixOS setup these are already available.

Before deploying anything, confirm the cluster is actually running:

```bash
kubectl get nodes
```
Expect to see one node listed with status `Ready`. If this command errors
or hangs, the cluster isn't running — stop here and get that fixed first
(this README assumes a working cluster, not how to set one up).

Confirm the local image registry is up too:
```bash
curl -s localhost:5000/v2/
```
Expect it to print `{}`. If it doesn't respond, the registry isn't running.

---

## Deploying the lab

Deploy phases **in order** — later phases assume earlier ones already exist
(Phase 2's target needs Phase 1's namespace concept understood; Phase 3
needs Phase 1 and 2 running to have anything to monitor).

### Phase 1 — the attacker toolbox
```bash
cd 01-workspace
direnv allow          # only needed the first time, or after editing flake.nix
just deploy
```
This step takes the longest the first time (building the image from
scratch) — a minute or two is normal, not stuck.

**Validate it worked:**
```bash
kubectl get pods -n redcell
```
Expect one pod, `STATUS = Running`. If it's not `Running` after a minute,
see [Troubleshooting](#troubleshooting) below.

### Phase 2 — the target
```bash
cd ../02-target
just deploy
```
**Validate:**
```bash
just status
```
Expect one pod, `juice-shop-...`, `STATUS = Running`.

**Validate the attacker can actually reach it** (this is the real test —
confirms the whole point of the lab works):
```bash
cd ../01-workspace
just shell
```
You're now *inside* the attacker pod. Run:
```bash
curl -s http://juice-shop.targets.svc.cluster.local:3000/ | head -5
```
Expect to see the start of an HTML page (`<!doctype html>` etc.). If you see
that, Phases 1 and 2 are both confirmed working together.
```bash
exit
```
to leave the pod and return to your normal terminal.

### Phase 3 — the dashboard
```bash
cd ../03-monitoring
just deploy
```
This one deploys several components at once (Prometheus, Loki, Grafana) —
give it a minute or two.

**Validate:**
```bash
just status
```
Expect four `Running` pods: `prometheus-...`, `loki-...`, `promtail-...`,
`grafana-...`.

**Open the dashboard in a browser:**
```bash
kubectl get nodes -o wide --no-headers | awk '{print $1, $6}'
```
This prints your machine's IP address, e.g. `nixos-btw  10.0.0.86`. Open
`http://10.0.0.86:30300` in a browser (use *your* printed IP, not this
example one).

Log in: username `admin`, password `redcell-admin`.

Go to **Dashboards → Redcell Range → Juice Shop — Attack Surface**. You
should see four panels (two may show "No data" until you generate some
traffic — that's expected and fixed in the next step).

### Phase 4 — optional, skip unless you specifically want it
See the comments in `04-netflow/manifests/` — this phase gives the attacker
pod visibility into your real home network, which is a bigger privilege
step than Phases 1–3. Only do this once you're comfortable with everything
above.

---

## Running an actual test (seeing the dashboard react)

```bash
cd 01-workspace
just shell
```
Inside the pod:
```bash
nmap -Pn -sV -p- juice-shop.targets.svc.cluster.local
gobuster dir -u http://juice-shop.targets.svc.cluster.local:3000/ -w /dev/null -q
```
(`-w /dev/null` is a placeholder wordlist so the command runs without
downloading anything extra — swap in a real wordlist file later once you
have one.)

While that's running, refresh the Grafana dashboard in your browser (
`http://<your-ip>:30300`) — the **Network RX** and **CPU** panels should
visibly spike within about 15 seconds, and the **live logs** panel should
scroll with Juice Shop's own request logs as the scan hits it.

That reaction — scan runs, dashboard visibly moves — is the core loop this
whole lab is built around.

---

## Stopping the lab

Stopping ≠ deleting. `replicas: 0` keeps everything configured but not
running, so starting back up later is instant — no rebuild needed.

```bash
kubectl scale deploy/redcell-workspace -n redcell     --replicas=0
kubectl scale deploy/juice-shop        -n targets     --replicas=0
kubectl scale deploy/prometheus        -n monitoring  --replicas=0
kubectl scale deploy/loki              -n monitoring  --replicas=0
kubectl scale deploy/grafana           -n monitoring  --replicas=0
```

## Starting it back up

```bash
kubectl scale deploy/redcell-workspace -n redcell     --replicas=1
kubectl scale deploy/juice-shop        -n targets     --replicas=1
kubectl scale deploy/prometheus        -n monitoring  --replicas=1
kubectl scale deploy/loki              -n monitoring  --replicas=1
kubectl scale deploy/grafana           -n monitoring  --replicas=1
```

**Check everything's back up:**
```bash
kubectl get pods -n redcell
kubectl get pods -n targets
kubectl get pods -n monitoring
```
All should read `Running` within about 30 seconds.

---

## Tearing down completely (deletes everything, including Grafana's config)

Run from each phase's own directory, in **reverse** order:
```bash
cd 04-netflow    && just clean     # if you deployed it
cd ../03-monitoring && just clean
cd ../02-target     && just clean
cd ../01-workspace  && just clean
```
This deletes the namespaces and everything in them. It does **not** delete
your local Docker registry's stored images — those stay, so redeploying
later is fast (no rebuild needed unless you changed `flake.nix`).

---

## Everyday commands cheat sheet

| I want to... | Command |
|---|---|
| See what's running | `kubectl get pods -A` |
| Get into the attacker pod | `cd 01-workspace && just shell` |
| See the attacker pod's logs | `cd 01-workspace && just logs` |
| See Juice Shop's logs | `cd 02-target && just logs` |
| Rebuild + redeploy after editing `flake.nix` | `cd 01-workspace && just deploy` |
| Restart a stuck pod | `kubectl rollout restart deploy/<name> -n <namespace>` |
| Open Grafana | `http://<your-machine-ip>:30300` (admin / redcell-admin) |

---

## Troubleshooting

| Symptom | What it means | Fix |
|---|---|---|
| `Error from server (NotFound): namespaces "X" not found` | Kubernetes tried to create something before the namespace it belongs in existed | Already fixed in this repo's `justfile`s — if you still see it, check that `deploy:` applies `00-namespace.yaml` first |
| `just deploy` fails on `skopeo` with an HTTPS/TLS error | `skopeo` assumed the registry needs HTTPS; it only speaks plain HTTP | Confirm `push:` in `01-workspace/justfile` includes `--dest-tls-verify=false` |
| `nmap` says "Host seems down" but `curl` to the same host works | k3s's network drops the ping probe nmap sends by default; the actual service is fine | Add `-Pn` to any `nmap` command: `nmap -Pn -sV <target>` |
| Pod stuck `Pending` | Usually not enough CPU/memory free on the node | `kubectl describe pod <name> -n <namespace>` — look at the bottom `Events` section for the real reason |
| Pod `CrashLoopBackOff` | The container starts, then dies, repeatedly | `kubectl logs <pod-name> -n <namespace> --previous` shows the last crash's output |
| `ImagePullBackOff` | Kubernetes can't find/pull the image | Confirm the registry is up (`curl -s localhost:5000/v2/`), and the image name in `manifests/*.yaml` matches what `just push` actually pushed |
| Grafana dashboard panels all say "No data" | Nothing's generated traffic yet, or Prometheus hasn't scraped yet (15s interval) | Wait 15–30 seconds, or run the test commands under "Running an actual test" above |
| `direnv: error ... is blocked` | Normal, happens after any edit to `.envrc` or moving the folder | Run `direnv allow` |
| Nix build is dirty / "Git tree is dirty" warning | You have uncommitted changes and Nix flakes only see committed (staged) files | `git add -A && git commit -m "..."` before `just deploy` |

If none of these match what you're seeing, the single most useful piece of
information to get is:
```bash
kubectl describe pod <the-stuck-pod-name> -n <its-namespace>
```
and read the `Events` section at the very bottom — it almost always says in
plain English what's actually wrong.
