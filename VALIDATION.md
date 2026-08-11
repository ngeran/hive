# redcell-range — Verification & Validation

Run top to bottom the first time, to understand every layer. After that,
jump to whichever section matches what you're debugging.

---

## 1. Cluster level — is Kubernetes itself healthy?

```bash
kubectl get nodes -o wide
```
**What you're checking:** `STATUS = Ready`. The other columns
(`INTERNAL-IP`, `OS-IMAGE`, `KERNEL-VERSION`) confirm it's actually your
NixOS box and not some stale kubeconfig pointing elsewhere.

```bash
kubectl top nodes
```
**What you're checking:** current CPU/memory usage vs. capacity. If memory
is near 100%, that's why a pod might be stuck `Pending` — Kubernetes won't
schedule a pod it can't fit.

```bash
kubectl get pods -n kube-system
```
**What you're checking:** these are Kubernetes' own internals — CoreDNS
(cluster DNS), Traefik (ingress), metrics-server, local-path-provisioner
(storage). All should be `Running`/`Completed`. If **CoreDNS** isn't
`Running`, every `*.svc.cluster.local` DNS lookup you've been relying on
(like `juice-shop.targets.svc.cluster.local`) breaks cluster-wide — this is
the single most important pod in the list to check first.

```bash
curl -s localhost:5000/v2/
```
**What you're checking:** your local image registry responds `{}`. If this
hangs or errors, no `just push` in any phase will work.

---

## 2. Namespace / resource inventory — what exists right now?

```bash
kubectl get all -A | grep -E 'redcell|targets|monitoring|netflow'
```
**What you're checking:** one command, everything this project owns —
every Deployment, Pod, Service, ReplicaSet across all four namespaces. This
is your "is anything missing" bird's-eye view.

```bash
kubectl get namespaces
```
**What you're checking:** `redcell`, `targets`, `monitoring` (and
`netflow` if you deployed it) all present. If one's missing, that phase's
`00-namespace.yaml` never got applied.

---

## 3. Phase 1 — `redcell-workspace` (attacker pod)

```bash
kubectl get deployment redcell-workspace -n redcell
```
**Checking:** `READY = 1/1`. If it says `0/1`, the pod isn't up yet or is
crashing — go to the pod-level check next.

```bash
kubectl describe deployment redcell-workspace -n redcell
```
**Checking:** scroll to `Events` at the bottom. A healthy deploy shows
`ScalingReplicaSet` → `Scaled up`. Anything else here (`FailedCreate`,
image errors) is the actual root cause of a stuck rollout.

```bash
kubectl get pod -n redcell -o wide
```
**Checking:** `STATUS = Running`, `RESTARTS = 0` (a climbing restart count
means it's crash-looping). The `NODE` column confirms which node it landed
on (you only have one, `nixos-btw`, but this matters once you ever add a
second).

```bash
kubectl describe pod -n redcell -l app=redcell-workspace
```
**Checking:** the `Containers` section shows `Image:
localhost:5000/redcell-range:latest` and `State: Running`. The
`Security Context` line should show the capabilities you set
(`NET_RAW`, `NET_ADMIN`) — confirms the least-privilege config actually
applied, not silently ignored.

### App-level: are the tools actually there?
```bash
kubectl exec -n redcell deploy/redcell-workspace -- nmap --version
kubectl exec -n redcell deploy/redcell-workspace -- which sqlmap hydra gobuster nikto tcpdump masscan
```
**Checking:** a version string, and a real path for every tool (e.g.
`/bin/sqlmap`). If any `which` comes back empty, that tool's line is
missing from `flake.nix`'s `securityTools` list — add it and `just deploy`
again.

### Resource usage right now
```bash
kubectl top pod -n redcell
```
**Checking:** CPU/memory currently in use vs. the `limits` you set
(`1 CPU / 1Gi` in the manifest). Useful to run *during* an `nmap -p-` scan
to see it actually working.

---

## 4. Phase 2 — `juice-shop` (target)

```bash
kubectl get deployment,svc -n targets
```
**Checking:** Deployment `1/1`, and a Service `juice-shop` with
`TYPE = ClusterIP`, `PORT(S) = 3000/TCP`.

```bash
kubectl describe pod -n targets -l app=juice-shop
```
**Checking:** same as Phase 1 — `Image`, `State: Running`, no restart
churn in `Events`.

### App-level: is it actually serving requests?
```bash
kubectl exec -n redcell deploy/redcell-workspace -- curl -s -o /dev/null -w "%{http_code}\n" http://juice-shop.targets.svc.cluster.local:3000/
```
**Checking:** prints `200`. This is the single most important command in
this whole document — it proves DNS resolution, network routing between
namespaces, and the app itself are *all* working, in one line, without
needing an interactive shell.

### DNS resolution specifically (if the above fails)
```bash
kubectl exec -n redcell deploy/redcell-workspace -- getent hosts juice-shop.targets.svc.cluster.local
```
**Checking:** an IP address comes back (something in `10.43.x.x`, the
cluster's internal Service IP range). If this fails but CoreDNS is
`Running` (section 1), double check the Service name/namespace match
exactly what you're querying.

---

## 5. Phase 3 — monitoring stack

This is the most component-heavy phase — validate each piece individually,
then the connections between them.

### 5a. All four pods up
```bash
kubectl get pods -n monitoring
```
**Checking:** `prometheus`, `loki`, `promtail`, `grafana` all `Running`.
Note `promtail` is a DaemonSet — one pod per node (you have one node, so
one pod; this is correct, not under-scaled).

### 5b. Prometheus — is it actually scraping targets?
```bash
kubectl port-forward -n monitoring svc/prometheus 9090:9090
```
Leave that running, open a **second terminal**:
```bash
curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep -E '"health"|"job"'
```
**Checking:** every job (`prometheus`, `kubernetes-pods`, `cadvisor`)
shows `"health": "up"`. A `"down"` cAdvisor target usually means the RBAC
`nodes/proxy` permission (from the fix we made) didn't apply — recheck
`01-prometheus-rbac.yaml` got included in `just deploy`.
Ctrl-C the port-forward when done.

### 5c. Loki — is it healthy and receiving logs?
```bash
kubectl port-forward -n monitoring svc/loki 3100:3100
```
Second terminal:
```bash
curl -s http://localhost:3100/ready
```
**Checking:** prints `ready`.
```bash
curl -s -G http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query={namespace="targets"}' \
  --data-urlencode 'limit=5' | python3 -m json.tool | grep -A2 '"line"' | head -20
```
**Checking:** actual log lines from Juice Shop appear. Empty result here
(with no error) means Promtail isn't shipping logs — check 5d next.
Ctrl-C the port-forward when done.

### 5d. Promtail — is it reading node logs?
```bash
kubectl logs -n monitoring daemonset/promtail --tail=20
```
**Checking:** no repeating error lines. A common one:
`error opening path /var/log/pods/...` — means the `hostPath` mount isn't
seeing what it expects; confirm k3s (not some other CRI) is what's
running, since the log path convention in `08-promtail-config.yaml` is
k3s/containerd-specific.

### 5e. Grafana — datasources + dashboard provisioned correctly
```bash
kubectl port-forward -n monitoring svc/grafana 3000:3000
```
Second terminal:
```bash
curl -s -u admin:redcell-admin http://localhost:3000/api/health
```
**Checking:** `{"database": "ok", ...}`.
```bash
curl -s -u admin:redcell-admin http://localhost:3000/api/datasources | python3 -m json.tool | grep -E '"name"|"type"'
```
**Checking:** both `Prometheus` and `Loki` listed — confirms the
provisioning ConfigMap actually loaded, not just that the pod is up.
```bash
curl -s -u admin:redcell-admin http://localhost:3000/api/search?query=Juice | python3 -m json.tool
```
**Checking:** returns the dashboard's `uid: redcell-juice-shop` — confirms
the dashboard JSON ConfigMap was mounted and picked up.
Ctrl-C the port-forward when done.

### 5f. End-to-end: does the dashboard react to real activity?
```bash
kubectl exec -n redcell deploy/redcell-workspace -- nmap -Pn -sV -p- juice-shop.targets.svc.cluster.local
```
Then in the browser, refresh
`http://<your-ip>:30300/d/redcell-juice-shop` — **Network RX** and **CPU**
panels should show a visible spike within ~15–30 seconds of the scan
finishing (Prometheus's `scrape_interval` is 15s, so there's always a
small lag).

---

## 6. Cross-cutting: RBAC (why can Prometheus/Promtail even see pods?)

```bash
kubectl auth can-i list pods --as=system:serviceaccount:monitoring:prometheus -A
kubectl auth can-i list pods --as=system:serviceaccount:monitoring:promtail -A
```
**Checking:** both print `yes`. This directly tests the ClusterRole/
ClusterRoleBinding files — if either prints `no`, that service account's
RBAC manifest either wasn't applied or has a typo in the `subjects`/
`roleRef` names.

---

## 7. One-shot health check (run this first, every time)

```bash
echo "=== Nodes ===" && kubectl get nodes && \
echo "=== Registry ===" && curl -s localhost:5000/v2/ && echo && \
echo "=== All pods ===" && kubectl get pods -A | grep -E 'redcell|targets|monitoring|netflow|NAMESPACE' && \
echo "=== Juice Shop reachable? ===" && \
kubectl exec -n redcell deploy/redcell-workspace -- curl -s -o /dev/null -w "HTTP %{http_code}\n" http://juice-shop.targets.svc.cluster.local:3000/
```
**Checking:** one paste, ~5 seconds, tells you if the whole lab is healthy
or points you straight at which layer to investigate further up this
document.
