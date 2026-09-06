# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

HIVE (κυψέλη) is a hands-on network-security + observability lab on a local
single-node k3s cluster. It deploys an "attacker" toolbox pod, a deliberately
vulnerable target (OWASP Juice Shop), and a Prometheus/Loki/Grafana stack that
visualizes the attack live. The core loop is: run a scan from the attacker pod →
watch the dashboard react.

This is an **infrastructure-as-manifests** repo, not an application codebase.
There is no build system for app code, no test suite, and no linter. Every
change is a Kubernetes manifest, a Nix package list, or a `just` recipe.

## Phases and namespaces

The repo is split into numbered phase directories. Each is independent and
deployed in order; later phases assume earlier ones exist.

| Dir | Namespace | Deployment(s) | Image source |
|---|---|---|---|
| `01-workspace/` | `redcell` | `redcell-workspace` | **built locally via Nix** (`localhost:5000/redcell-range:latest`) |
| `02-target/` | `targets` | `juice-shop` | public (`bkimminich/juice-shop:latest`) |
| `03-monitoring/` | `monitoring` | `prometheus`, `loki`, `grafana` + `promtail` DaemonSet | public images |

Only Phase 1 builds a custom image. Phases 2 and 3 consume pre-built public
images — no `flake.nix`, no build step.

**`04-netflow/` does not exist yet**, despite being referenced in the README and
VALIDATION.md. It is planned, not implemented. Don't go looking for it.

## The build/deploy pipeline (Phase 1 only)

Phase 1 is the only phase with a build step, and it follows Nikos's
Nix-image → k3s pipeline. From `01-workspace/`:

```
nix build .#image          # builds an OCI tarball into ./result (no Dockerfile, no docker daemon)
skopeo copy ... result →   # pushes the tarball to the local registry at localhost:5000
kubectl apply -f manifests/  + rollout restart   # applies + force-repulls (imagePullPolicy: Always)
```

`just deploy` chains all three. The other phases' `just deploy` skip build/push
and just `kubectl apply` + rollout.

**Two non-obvious gotchas:**
- **Nix flakes only see committed files.** After editing `flake.nix`, you must
  `git add -A && git commit` before `just deploy`, or the build silently uses the
  old version (and may warn "Git tree is dirty").
- **Fixed tag `:latest` + `imagePullPolicy: Always` is intentional.** k3s
  re-pulls on every rollout restart rather than trusting a stale cached
  `:latest`. Don't "fix" this by adding version tags or changing to `IfNotPresent`.

### Adding a tool to the attacker pod

Add a line to the `securityTools` list in `01-workspace/flake.nix`, then
`direnv allow && just deploy`. Nothing else changes. The image ships *only* the
packages listed there — Nix images have no base layer of standard utilities, so
things like `coreutils` are explicit dependencies.

## Common commands

All commands run from inside the relevant phase directory (each phase has its own
`justfile`):

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
```

Every phase also has `just clean` (`kubectl delete -f manifests/`). Tear down in
**reverse** order (03 → 02 → 01).

To start/stop without deleting (preserves config), scale to 0/1:
`kubectl scale deploy/<name> -n <ns> --replicas=0`

There are **no tests and no lint** in this repo. Validation is manual and
documented in `VALIDATION.md` (cluster → namespace → per-phase → cross-cutting
RBAC, ending with a one-shot health-check paste).

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
  UI click-through needed.

- **No PersistentVolumeClaims anywhere.** Prometheus metrics, Loki logs, and
  Grafana config are all ephemeral — nothing survives a pod restart. Intentional
  for a learning lab.

## Doc/code drift to be aware of

`README.md` and `VALIDATION.md` describe a few things that are **not yet in the
manifests** — they read as forward-looking/aspirational:
- A provisioned Grafana dashboard ("Juice Shop — Attack Surface",
  uid `redcell-juice-shop`) — there is **no dashboard ConfigMap**; the Grafana
  deployment mounts only the datasources ConfigMap.
- A cAdvisor Prometheus scrape job and `nodes/proxy` RBAC — the Prometheus config
  has only `prometheus` and `kubernetes-pods` jobs.
- The `04-netflow` phase (see above).

If a task points you at any of these, they need to be *created*, not found.
