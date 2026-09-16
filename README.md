# Lab: configuration, state, and load

The hands-on part of the session: three labs, one per act — configuration and
Ingress, persistent state, and load. There are two copies of the lab, one per
container runtime. **Use the folder that matches your laptop, and work only inside it.**

| Your laptop runs | Folder | Start with |
|---|---|---|
| Docker Desktop | [`docker/`](docker/) | [`docker/README.md`](docker/README.md) |
| Podman or Podman Desktop | [`podman/`](podman/) | [`podman/README.md`](podman/README.md) |

**Not sure which you have?** Run:

```bash
docker version
```

If the `Server` section mentions **Podman Engine**, or `docker` isn't installed but
`podman` is, use `podman/`. Otherwise use `docker/`.

## Before the session

Run the pre-flight check from your folder. It checks your tools, pulls the slow images,
and builds and deletes a practice cluster:

```bash
cd lab/docker    # or lab/podman
bash scripts/preflight.sh
```

If you already have a cluster called `exchange`, the check skips that last step rather
than delete it.

## What's different between the two

The app, the manifests and the exercises are the same. Only these differ:

| | Docker | Podman |
|---|---|---|
| One-time setup | none | rootful machine, Docker-compatible socket, and a `host-gateway` fix so k3d can start (README section 0a) |
| Build command | `docker build` | `podman build` |
| Image name | `exchange-gateway:v1` | `localhost/exchange-gateway:v1` — Podman prefixes every image it builds |
| Manifests | `image: exchange-gateway:v1` | `image: localhost/exchange-gateway:v1` |
| `preflight.sh` | warns if the machine is actually running Podman | checks the three Podman setup steps |
| `reset.sh` | removes images with `docker rmi` | removes images with `podman rmi` |

## Keeping the two in step

Every change to the app, a manifest, a script or the workbook belongs in **both**
folders. A check enforces it:

```bash
python3 lab/check-consistency.py
```

It passes only if the folders match everywhere except the runtime-specific parts it
lists: the Podman setup in Lab 0, the preflight script, a few troubleshooting entries,
and runtime spellings such as `podman build` and the `localhost/` image prefix. When it
fails, it names the file or README section and shows the first differing line.

It also runs automatically before every commit that touches `lab/docker` or
`lab/podman`, and refuses the commit if they've drifted. Git doesn't copy hook settings
when a repository is cloned, so in a fresh clone switch it on once:

```bash
git config core.hooksPath .githooks
```
