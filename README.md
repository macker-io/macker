# Macker

macOS-native Linux containers. The daemon speaks the Docker Engine API over a UNIX socket and boots each container in a MicroVM (Apple `containerization` + Virtualization.framework).

| Path | What it is |
| --- | --- |
| `app/` | SwiftUI GUI (`io.macker.app`) |
| `daemon/` | SPM package: `App` (daemon) and `macker` (CLI) |

Requirements: Apple Silicon, macOS 15+ (MicroVMs). Container networking (`bridge` / `host`) requires macOS 26+.

## Local debug

Do not run `macker setup` unless you intend to rewrite your `docker` alias and `/var/run/docker.sock`. Kernel/initfs come from `fetch-runtime`.

```bash
git submodule update --init --recursive

make -C daemon fetch-runtime   # guest kernel + vminit → daemon store
make -C daemon run             # build, ad-hoc sign, start the daemon
```

In another terminal:

```bash
cd daemon
./.build/debug/macker doctor
./.build/debug/macker pull hello-world
./.build/debug/macker run --rm hello-world
```

`run` / `create` pull the image if it is missing locally. First `start` can take a while (unpack rootfs + boot the VM).

Container records survive daemon restart (`ps -a`). MicroVMs do not: a graceful stop marks them `Exited (143)`; a crash marks them `Exited (255)`. `--rm` containers that were running are removed on restore. `ps` hides stopped containers.

Stop the daemon with Ctrl+C, then wipe images / containers / volumes / networks (keeps kernel and initfs):

```bash
make -C daemon reset
```

## Run, attach, and exec

Foreground `run` attaches live stdio (create → attach → start). `-i` keeps stdin open; `-t` allocates a guest TTY (raw host terminal + window resize). `attach` reconnects to a running container. `exec` starts another process in a running MicroVM.

```bash
./.build/debug/macker run --rm alpine echo hello
./.build/debug/macker run --rm -it alpine sh
./.build/debug/macker run -dit --name sh alpine sh
./.build/debug/macker attach sh
./.build/debug/macker run -d --name web -p 18080:80 nginx
./.build/debug/macker exec web cat /usr/share/nginx/html/index.html
./.build/debug/macker exec -it web sh
echo hello | ./.build/debug/macker exec -i web cat
```

Official `nginx` does not include `wget` / `curl`. Use `cat` on the static files, or `exec` into `alpine`.

| Flag | `run` / `exec` | Effect |
| --- | --- | --- |
| `-d` | both | Detach; `run` prints the container ID |
| `-i` | both | Forward stdin |
| `-t` | both | Guest PTY; host raw mode when stdin/stdout are TTYs |
| `--rm` | `run` | Remove the container when it exits |
| `-w` / `-e` / `-u` | `exec` | Working dir, env, user |

Without `-t`, Ctrl-C on foreground `run` stops the container. `attach` without a TTY proxies SIGINT/SIGTERM/SIGHUP/SIGQUIT; with a TTY, `ctrl-p ctrl-q` detaches and leaves the container running. `exec` without `-t` proxies the same signals to the exec process, not the container. `Ctrl-D` / `exit` should restore the host terminal (`stty sane` if it does not).

## Socket

The daemon listens on:

`~/Library/Application Support/io.macker.daemon/macker.sock`

Override with `--socket`, `MACKER_HOST`, or `DOCKER_HOST` (`unix://…` or an absolute path).

`/var/run/docker.sock` is Docker’s name. Only `macker setup` (optionally `--force`) creates a symlink to `macker.sock`. Leave it alone if it already points at Podman or Docker Desktop.

## Networking

Each container is a MicroVM with its own kernel, so this is not Linux `bridge` + `veth`. The Docker names still apply:

| `--network` | What Macker does |
| --- | --- |
| `bridge` (default) | virtio-net on a vmnet NAT network (`172.17.0.0/16`). Same-network containers can reach each other by name (`/etc/hosts`). `-p` publishes TCP on the Mac via a userspace proxy. |
| `host` | NAT NIC like bridge. `-p` is ignored. Image `EXPOSE` (and create `ExposedPorts`) are published 1:1 on the Mac (`80` → `localhost:80`). Guest `127.0.0.1` is **not** the Mac loopback. |
| `none` | No NIC. |

`macker network ls|create|rm|inspect|connect|disconnect|prune` works. Builtin `bridge` / `host` / `none` cannot be removed. `connect` / `disconnect` only apply while the container is stopped.

```bash
./.build/debug/macker network ls
./.build/debug/macker run --rm alpine wget -qO- https://example.com
./.build/debug/macker run -d --name web -p 18080:80 nginx
curl http://127.0.0.1:18080
./.build/debug/macker run -d --name hostweb --network host nginx
curl http://127.0.0.1:80
```

Host-mode `curl localhost:80` uses the image `EXPOSE` 1:1 proxy, not `-p`. Binding Mac port 80 fails if something else already owns it.

vmnet NAT uses the same `com.apple.security.virtualization` entitlement as Apple’s containerization examples. `com.apple.vm.networking` is restricted; claiming it on an ad-hoc signed daemon gets the process SIGKILL’d at launch.

## Roadmap

Daily `bridge` / `host` / `none`, plus `run -it` / `exec`, is in place. Command completeness, gaps, and the implementation order are in [docs/cli-status.md](docs/cli-status.md).

## Make targets

Run these from the repo root (`make -C daemon …`) or from `daemon/`. Prefer Make over calling `scripts/` directly.

| Target | Purpose |
| --- | --- |
| `app` | Debug-build the daemon and ad-hoc sign it |
| `macker` | Debug-build the CLI |
| `run` | `app`, then start the daemon |
| `sign` | Re-sign an already-built debug `App` |
| `fetch-runtime` | Download the pinned kernel + vminit into the store |
| `reset` | Delete store `content/`, `containers/`, `volumes/`, `networks/` |
| `bundle` | Release `dist/MackerDaemon.app` |
| `pkg` | Release `.app` + `dist/MackerDaemon.pkg` |
| `check` | Fail if `RuntimePin.json` ≠ containerization submodule tag |
| `sync-runtime` | Show or set pins (`ARGS='containerization 0.42.0'`) |
| `sync-runtime-latest` | Bump pins to GitHub latest stable |

```bash
VERSION=1.2.3 make -C daemon pkg
make -C daemon sync-runtime ARGS='kata 3.28.0'
```

Debug builds report version `0.0.0`. Pass `VERSION=` (or `MACKER_VERSION=`) when packaging.

## Scripts (`daemon/scripts/`)

Make targets call these. They are not only for local debug.

| Script | Used by | Role |
| --- | --- | --- |
| `sign-app.sh` | `make app` / `sign` | Ad-hoc sign the debug daemon (`com.apple.security.virtualization`) |
| `fetch-runtime.sh` | `make fetch-runtime`; packaging if `.runtime` is missing | Install kernel/initfs into the store; optional staging dir |
| `reset-store.sh` | `make reset` | Wipe engine state; keep `runtime/`, `initfs.ext4`, `daemon-id` |
| `package.sh` | `make bundle` / `pkg` | Release `.app` (`package.sh`) or `.app`+`.pkg` (`package.sh pkg`) |
| `sync-runtime.sh` | `make check` / `sync-runtime*` | Edit pins and the submodule; does not download artifacts |
| `lib.sh` | sourced by the others | Shared paths and helpers |

`fetch-runtime` and `sync-runtime` stay separate: one downloads the current pin, the other changes the pin.

## Store and pins

Daemon data lives in `~/Library/Application Support/io.macker.daemon/`:

- `macker.sock` — API socket (removed when the daemon exits)
- `runtime/vmlinux`, `initfs.ext4` — guest kernel and initfs
- `content/`, `volumes/`, `containers/`, `networks/`, `auth.json` — engine state (`make reset` keeps `auth.json`). Container metadata is `containers/<id>.json`; MicroVM disks under `containers/<id>/` are recreated on each start.

Guest versions are pinned in `daemon/Sources/ContainerEngine/RuntimePin.json` (`containerization`, `kata`). `daemon/.runtime/` is a packaging cache only (gitignored), not the runtime store.

## GUI

Open `app/Macker.xcodeproj`. Debug uses Xcode’s default `MARKETING_VERSION` (`1.0`). Archive with:

```bash
xcodebuild -project app/Macker.xcodeproj \
  MARKETING_VERSION=1.2.3 CURRENT_PROJECT_VERSION=42
```
