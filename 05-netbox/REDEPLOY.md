# Phase 05 — NetBox: Postmortem & Redeploy Guide

> Authoritative doc for this phase (the `README.md` here is a stale scaffold
> template). Fixed 2026-09-06, commits `2bf7f92` + `48b38c5`.

## TL;DR — redeploy from scratch

Yes, it's the standard pipeline (`nix build` → `skopeo` → `kubectl`). From
`05-netbox/`:

```bash
just clean                      # kubectl delete -f manifests/ (wipes the DB — see gotcha 1)
git add -A && git commit        # flakes only see the git index — never skip
just deploy                     # build + push + apply + rollout (takes ~2–4 min)
kubectl -n netbox exec -it deploy/netbox -- bash -c \
  'PY=$(ls -d /nix/store/*-netbox-env/bin/python | head -n1) && "$PY" manage.py createsuperuser'
just forward-bg                 # http://localhost:8001
```

---

## What was wrong

**Symptom:** every page returned `500 — TypeError: get_show_toolbar()
missing 1 required positional argument: 'async_mode'` (Python 3.11.11,
NetBox 4.0.0).

### Root cause: dependency drift, not a DEBUG problem

The image's dependencies were listed by hand in `05-netbox/pyproject.toml`
with most packages **unpinned**, so `uv.lock` resolved whatever was newest:
`django-debug-toolbar 6.3.0`, `strawberry-graphql 0.219.2`,
`strawberry-graphql-django 0.25.0`, `gunicorn 26.x`. NetBox 4.0.0 is built
and tested against its own pins in `app/requirements.txt`
(`django-debug-toolbar==4.3.0`, `strawberry-graphql==0.227.3`,
`strawberry-graphql-django==0.39.2`, …).

The killer detail: NetBox 4.0's `settings.py` loads
`strawberry_django.middlewares.debug_toolbar.DebugToolbarMiddleware` in
`MIDDLEWARE` **unconditionally**. ddt 6.x changed the `get_show_toolbar()`
signature to require `async_mode`, so the old strawberry middleware raised
`TypeError` on **every request** — `DEBUG` was never consulted. That is why
the whole loop of "fixes" changed nothing:

| Attempt | Why it couldn't work |
|---|---|
| `DEBUG = False` in `configuration.py` | The strawberry debug middleware is loaded regardless of `DEBUG` |
| Purging / disabling the toolbar package | `debug_toolbar` is in NetBox's `INSTALLED_APPS`; imports still hit the mismatched API |
| `EXTRA_MIDDLEWARE = [...]` (whitenoise) | **Not a NetBox setting.** `settings.py` reads no middleware from `configuration.py` — silently ignored |
| `sys.modules` hack to stub the toolbar | Fragile, and the real fix is the dependency set, not masking it |

### Secondary breakage found while fixing the above

1. **psycopg without `[binary]`** — pure-Python psycopg `dlopen`s libpq at
   import; a Nix `dockerTools` image has no system libpq, so
   `import psycopg` failed and Django fell back to a missing `psycopg2` →
   init container crashloop. The `psycopg-binary` wheel bundles libpq.
2. **sdist-only packages with no `[build-system]`** — `django-pglocks`,
   `sgmllib3k`, `promise` built without setuptools under uv2nix → build
   failure. Fixed with `resolveBuildSystem { setuptools = [ ]; }` overrides
   in `flake.nix`.
3. **Static files wiped on every pod start** — `/app/netbox/static` is an
   emptyDir, so a one-off manual `collectstatic` dies with the pod. Now a
   `collectstatic` **initContainer** runs on every pod start.
4. **Scaffold leftovers** — `just deploy` was also applying `pyapp`
   template manifests into the `default` namespace (a crashlooping
   Deployment), plus a stray file literally named `1`. Both deleted.

## What changed (file by file)

| File | Change |
|---|---|
| `pyproject.toml` | Mirrors `app/requirements.txt` (NetBox 4.0.0's own pins) exactly; `psycopg[binary,pool]==3.1.18` (upstream's `[c]` has no buildable wheel here); only addition: `whitenoise==6.7.0` |
| `uv.lock` | Regenerated from the pinned set |
| `app/hive_wsgi.py` *(new)* | Real whitenoise wiring: injects `WhiteNoiseMiddleware` into `settings.MIDDLEWARE` (position 1, after Prometheus) before `get_wsgi_application()`. gunicorn entrypoint is now `hive_wsgi:application` |
| `flake.nix` | `PYTHONPATH=/app:/app/netbox`; `hive_wsgi:application` entrypoint; setuptools injection for the 3 sdist-only packages |
| `app/netbox/netbox/configuration.py` | `DEBUG = False` kept (production mode); dead `EXTRA_MIDDLEWARE` / `STATIC_ROOT` lines removed with explanatory comments |
| `manifests/fastapi/02-deployment.yaml` | `collectstatic` initContainer; `runAsGroup`/`fsGroup: 1000` |
| `justfile` | rollout timeout 300 s; `forward-bg` / `forward-stop` recipes |
| deleted | `manifests/fastapi/deployment.yaml`, `manifests/fastapi/service.yaml` (pyapp templates), stray file `1` |

## Full from-scratch redeploy, step by step

Each step has a verification gate — don't move on if it fails.

### 0. Prerequisites

```bash
kubectl get nodes                      # node Ready
curl -s localhost:5000/v2/             # {} — local registry up
```

If the registry is down: `sudo systemctl start k3s` (first-ever start needs
`sudo mkdir -p /persist/var/lib/rancher/k3s`).

### 1. Tear down (skip if the netbox namespace is already clean)

```bash
cd 05-netbox
just clean        # deletes everything in manifests/, including the namespace
```

`just clean` deletes the namespace → **the Postgres data is gone** (no PVC,
by design for this lab) → the admin user must be recreated (step 4).

### 2. Stage and build

```bash
git add -A && git commit -m "…"   # REQUIRED — flakes see the git index, not the working tree
just deploy                       # build + push + apply + rollout status (300 s timeout)
```

First build from an empty Nix store takes several minutes (uv2nix builds
every wheel); later builds are cached.

### 3. Verify the rollout

```bash
kubectl -n netbox get pods                                  # all Running
kubectl -n netbox logs -l app=netbox -c collectstatic       # "178 static files copied"
kubectl -n netbox logs -l app=netbox -c netbox --tail=5     # gunicorn 22.0.0, 3 workers booted
```

### 4. Create the admin user (fresh DB only)

```bash
kubectl -n netbox exec -it deploy/netbox -- bash -c \
  'PY=$(ls -d /nix/store/*-netbox-env/bin/python | head -n1) && "$PY" manage.py createsuperuser'
```

(The glob is needed because Nix store paths are content-hashed — the venv
path changes with every dependency change.)

Existing DB? Reset a forgotten password instead:

```bash
kubectl -n netbox exec -it deploy/netbox -- bash -c \
  'PY=$(ls -d /nix/store/*-netbox-env/bin/python | head -n1) && "$PY" manage.py changepassword admin'
```

### 5. Smoke test

```bash
just forward-bg     # or: just forward   (foreground)
curl -o /dev/null -w '%{http_code}\n' http://localhost:8001/login/     # 200
curl -o /dev/null -w '%{http_code}\n' http://localhost:8001/graphql/   # 200
curl -o /dev/null -w '%{http_code}\n' http://localhost:8001/static/setmode.js   # 200
```

`/graphql/` is the canary — it was the endpoint that always 500'd.

## Day-2 operations

```bash
just logs            # tail gunicorn
just forward         # foreground port-forward
just forward-bg      # background — survives terminal close (log: /tmp/netbox-forward.log)
just forward-stop    # kill every netbox port-forward
just deploy          # any code/manifest change: edit → git add -A → just deploy
```

## Gotchas

1. **No PVCs — the DB is ephemeral.** Deleting/recreating the `netbox-db`
   *pod* (rollout restart, node reboot) wipes Postgres → re-run
   `createsuperuser`. Intentional for a lab; add a PVC to
   `01-db-redis.yaml` if that hurts.
2. **Never bump a dependency by hand.** The pin set must mirror
   `app/requirements.txt` of the vendored NetBox version. Upgrading NetBox
   = swap the whole `app/` tree *and* the pin set together.
3. **Adding a Python dep:** edit `pyproject.toml` → `nix run nixpkgs#uv --
   lock --python 3.11` → if it's sdist-only with no `[build-system]`, add a
   `resolveBuildSystem` override in `flake.nix` → `git add -A` → `just
   deploy`.
4. **`git add -A` before every build.** Unstaged changes are invisible to
   Nix — the build silently uses the old tree.
5. **`kubectl exec … -- sh` fails** — Nix images ship no shell at /bin/sh
   path expected by kubectl defaults; use `-- bash -c` (bash IS in the
   image).
6. **`:8001` is the forward, not the app.** The container listens on 8001,
   the Service maps 80 → 8001, `just forward` maps localhost:8001 → 80.
