# Python template — FastAPI *or* plain script

One scaffold, **two variants**. Pick one and everything (image entrypoint,
manifests, justfile) follows it.

| `variant` | Use case | Entrypoint | K8s resource |
|---|---|---|---|
| `"fastapi"` (default) | HTTP service / API | `uvicorn main:app` on :8080 | `Deployment` + `Service` |
| `"script"` | a script that runs and exits (worker, batch job, CLI) | `python /app/script.py` | `Job` (runs to completion) |

## Switch variant

Set the same value in **two** places (kept in sync — the flake builds the image,
the justfile deploys the matching manifest):

```nix
# flake.nix
variant = "fastapi";   # or "script"
```
```just
# justfile
variant := "fastapi"   # or "script"
```

That's it — `just deploy` does the rest.

## Layout

```
├── flake.nix               # variant switch → image (entrypoint + venv via uv2nix)
├── pyproject.toml          # ─┐ SINGLE source of truth for Python deps
├── uv.lock                 # ─┘ (uv2nix builds the venv for BOTH dev shell + image)
├── justfile                # variant-aware build / push / deploy / run / logs
├── app/
│   ├── main.py             # FastAPI app    (variant = "fastapi")
│   └── script.py           # plain script   (variant = "script")
└── manifests/
    ├── fastapi/            # Deployment + Service (variant = "fastapi")
    └── script/             # Job                 (variant = "script")
```

`just deploy` only applies `manifests/<variant>/`, so the unused variant's
manifests are inert — leave them or delete them.

## Run

```bash
# local — the devShell venv (built from pyproject.toml/uv.lock via uv2nix)
just run

# change deps: edit pyproject.toml → `uv lock` (in the devShell) → rebuild
# build → push (skopeo, no docker) → deploy to k3s
just deploy
just logs          # tail (Deployment for fastapi, Job pod for script)
just forward       # port-forward :8080 (fastapi only)
```

> The devShell's venv IS the image's venv (uv2nix, from uv.lock) — no
> `pip install`, no requirements.txt, no drift.

## Notes

- **Deps are the SAME for local dev and the image** — both come from
  `pyproject.toml` + `uv.lock` via [uv2nix](https://github.com/pyproject-nix/uv2nix).
  Edit `pyproject.toml`, run `uv lock` (in the devShell), then `just build`.
  (This kills the old requirements.txt-vs-withPackages drift that once caused a
  fastapi-version-mismatch HTTP 500 in prod.)
- **Re-running a Job:** Jobs are immutable, so `just deploy` deletes +
  re-applies `manifests/script/job.yaml` after each edit.
