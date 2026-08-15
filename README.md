# Macker

macOS-native Linux containers. The daemon speaks the Docker Engine API over a UNIX socket and boots each container in a MicroVM (Apple `containerization` + Virtualization.framework).

| Path | What it is |
| --- | --- |
| `app/` | SwiftUI GUI (`io.macker.app`) |
| `daemon/` | SPM package: `App` (daemon) and `macker` (CLI) |

Requirements: Apple Silicon, macOS 15+.

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

`run` does not pull for you. First `start` can take a while (unpack rootfs + boot the VM).

Stop the daemon with Ctrl+C, then wipe images / containers / volumes / networks (keeps kernel and initfs):

```bash
make -C daemon reset
```

## Socket

The daemon listens on:

`~/Library/Application Support/io.macker.daemon/macker.sock`

Override with `--socket`, `MACKER_HOST`, or `DOCKER_HOST` (`unix://…` or an absolute path).

`/var/run/docker.sock` is Docker’s name. Only `macker setup` (optionally `--force`) creates a symlink to `macker.sock`. Leave it alone if it already points at Podman or Docker Desktop.

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
| `sign-app.sh` | `make app` / `sign` | Ad-hoc sign the debug daemon (Virtualization entitlement) |
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
- `content/`, `volumes/`, `containers/`, `networks/` — engine state (`make reset`)

Guest versions are pinned in `daemon/Sources/ContainerEngine/RuntimePin.json` (`containerization`, `kata`). `daemon/.runtime/` is a packaging cache only (gitignored), not the runtime store.

## GUI

Open `app/Macker.xcodeproj`. Debug uses Xcode’s default `MARKETING_VERSION` (`1.0`). Archive with:

```bash
xcodebuild -project app/Macker.xcodeproj \
  MARKETING_VERSION=1.2.3 CURRENT_PROJECT_VERSION=42
```
