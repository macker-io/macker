# Macker

macOS-native Linux containers. The daemon speaks the Docker Engine API over a UNIX socket and boots each container in a MicroVM (Apple `containerization` + Virtualization.framework).

This is a **CLI preview**. There is no GUI on this release line. The official `docker` CLI, `docker compose`, and `docker build` (BuildKit) work against it as a drop-in engine; Swarm does not.

**Requirements:** Apple Silicon. macOS 15+ to boot MicroVMs. **macOS 26+** for `bridge` / `host` networking.

Command completeness: [docs/cli.md](docs/cli.md). Networking: [docs/networking.md](docs/networking.md). Building from source: [docs/develop.md](docs/develop.md).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/macker-io/macker/main/scripts/install.sh | bash
```

That downloads the newest GitHub Release tarball (including prereleases) into `~/.macker`, puts `macker` / `mackerd` on your PATH, and starts a LaunchAgent (`io.macker.daemon`).

```bash
# pin a version
curl -fsSL https://raw.githubusercontent.com/macker-io/macker/main/scripts/install.sh | bash -s -- 0.1.0-alpha.1

# files only, no LaunchAgent
curl -fsSL https://raw.githubusercontent.com/macker-io/macker/main/scripts/install.sh | bash -s -- --no-service

# remove ~/.macker, PATH line, and the agent
curl -fsSL https://raw.githubusercontent.com/macker-io/macker/main/scripts/install.sh | bash -s -- --uninstall
```

`macker setup` registers a Docker context named `macker` for the official `docker` CLI (see below). It does not switch your active context, edit shell files, or touch `/var/run/docker.sock` unless you pass `--docker-socket`.

Optional: `sudo macker helper install` so the Mac can `curl` container IPs over utun. `-p` works without it.

## Quick start

Open a new terminal after install (PATH), then:

```bash
macker doctor
macker pull hello-world
macker run --rm hello-world
macker run --rm alpine echo hello
macker run --rm -it alpine sh
macker run -d --name web -p 18080:80 nginx
curl http://127.0.0.1:18080
macker exec web cat /usr/share/nginx/html/index.html
```

`run` / `create` pull the image if it is missing. First start unpacks a rootfs and boots a VM, so it is slower than Docker on Linux.

Foreground `run` attaches stdio. `-i` keeps stdin open; `-t` is a guest TTY. Without `-t`, Ctrl-C on foreground `run` stops the container.

```bash
macker run -dit --name sh alpine sh
macker attach sh
macker exec -it web sh
echo hello | macker exec -i web cat
```

Official `nginx` has no `wget` / `curl` — `cat` the static files, or `exec` into `alpine`.

## Compose

From a directory with a `compose.yaml`:

```bash
macker compose up -d --build
macker compose logs
macker compose down
```

The CLI package includes Docker Compose and its Buildx build provider. No Docker Desktop, separate Docker CLI/plugins, or `macker setup` is needed. This does not install a `docker` command or change your Docker context.

## Official `docker` CLI and Compose

The official `docker` CLI (29.x) and `docker compose` plugin work against Macker (Docker Engine API 1.24–1.44). Register the context once:

```bash
macker setup                              # creates the `macker` docker context (idempotent)
docker --context macker run --rm alpine echo hello
docker --context macker compose up -d
docker context use macker                 # optional: make Macker the default engine
macker doctor                             # docker CLI, compose plugin, context, socket, API
```

`macker setup --force` repoints an existing `macker` context that targets something else; `macker setup --uninstall` removes it (only if it points at Macker); `--docker-socket` also links `/var/run/docker.sock` (opt-in). `DOCKER_HOST=unix://…/macker.sock` works as well.

`--privileged` and `--cap-add` / `--cap-drop` apply inside the container's own MicroVM. Options a MicroVM cannot honor (`--pid host`, `--device`, `--network container:…`, `--platform linux/amd64`, …) fail with an error instead of being ignored. Details: [docs/cli.md](docs/cli.md#official-docker-cli-and-compose).

## Build

`docker build` and `docker compose build` use BuildKit (Dockerfile `# syntax=`, heredocs, `RUN --mount`, secrets) through a builder MicroVM the daemon manages, and the image lands in Macker's store as with Docker Engine: [docs/buildkit.md](docs/buildkit.md).

```bash
docker --context macker build -t demo:latest .
docker --context macker run --rm demo:latest
```

`macker build` (and `DOCKER_BUILDKIT=0 docker build`) use the classic builder: each `RUN` boots a throwaway MicroVM, and BuildKit-only syntax is rejected.

## Socket

Default:

`~/Library/Application Support/io.macker.daemon/macker.sock`

Override with `--socket`, `--store`, `MACKER_HOST`, or `DOCKER_HOST`. Only one daemon may own a given store.

## Networking

Docker network *names* apply (`bridge` / `host` / `none`). Underneath, each container is a MicroVM — not Linux `bridge` + `veth`. Details: [docs/networking.md](docs/networking.md).

| `--network` | What Macker does |
| --- | --- |
| `bridge` (default) | Userspace L3. Same-network containers reach each other. `-p` publishes on the Mac. |
| `host` | vmnet NAT. `-p` is ignored; image `EXPOSE` is 1:1 on localhost. Guest `127.0.0.1` is not the Mac. |
| `none` | No NIC. |

```bash
macker run --rm alpine wget -qO- https://example.com
macker run -d --name web -p 18080:80 nginx
curl http://127.0.0.1:18080
```

## Preview limits

- Apple Silicon only, `linux/arm64` images only (no x86_64 emulation). No Swarm, plugins, secrets, or configs.
- `bridge` supports dual-stack IPv6 (`macker network create --ipv6 NAME`); IPv6-only and `host`-mode IPv6 are not supported. `macvlan` / `ipvlan` / `--net=container:` are not implemented.
- Docker flags that need a shared host kernel (host namespaces, host devices, cgroup knobs) are rejected; a few others are approximated (see [docs/cli.md](docs/cli.md)).
- `buildx` builders created with `--driver docker-container` do not work (their state volume cannot back overlayfs); use the default builder.

Apache-2.0. See [LICENSE](LICENSE).
