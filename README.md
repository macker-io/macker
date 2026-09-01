# Macker

macOS-native Linux containers. The daemon speaks the Docker Engine API over a UNIX socket and boots each container in a MicroVM (Apple `containerization` + Virtualization.framework).

This is a **CLI preview**. There is no GUI on this release line. Not Docker Desktop: no Compose, no BuildKit/buildx, no Swarm.

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

Do **not** run `macker setup` unless you want to alias `docker` to `macker` and point `/var/run/docker.sock` at Macker.

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

## Build

Classic Docker builder only (`DOCKER_BUILDKIT=0`). Each `RUN` boots a throwaway MicroVM. BuildKit syntax (`# syntax=`, heredocs, `RUN --mount`, bake) is not implemented.

```bash
macker build -t demo:latest .
macker run --rm demo:latest
macker builder prune
```

The official `docker` CLI talking to `macker.sock` defaults to BuildKit on 23+ and will fail. Use `macker build`.

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

- Apple Silicon only. No Compose, Swarm, buildx, plugins, secrets, or configs.
- `macvlan` / `ipvlan` / `--net=container:` / IPv6 are not implemented.
- Many Docker flags are accepted as no-ops (see [docs/cli.md](docs/cli.md)).
- `macker setup` is opt-in and will fight Docker Desktop if you already use it.

Apache-2.0. See [LICENSE](LICENSE).
