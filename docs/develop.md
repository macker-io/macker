# Building Macker from source

This is the contributor path: clone, debug-build, test, and package. End-user install is in the [README](../README.md).

Requirements: Apple Silicon, macOS 15+, Swift 6.2. Container networking (`bridge` / `host`) needs macOS 26+.

`macker setup` only registers a `macker` Docker context (it never switches the active context or edits shell files; `/var/run/docker.sock` only with `--docker-socket`). For an isolated dev daemon, point `docker` at it with `DOCKER_HOST` instead. Guest kernel/initfs come from `fetch-runtime` (or the staged `.runtime/` used by packaging).

```bash
git submodule update --init --recursive

make fetch-runtime   # guest kernel + vminit → daemon store
make run             # build, ad-hoc sign, start the daemon
```

In another terminal:

```bash
./.build/debug/macker doctor
./.build/debug/macker pull hello-world
./.build/debug/macker run --rm hello-world
```

`run` / `create` pull the image if it is missing locally. First `start` can take a while (unpack rootfs + boot the VM).

Container records survive daemon restart (`ps -a`). MicroVMs do not: a graceful stop marks them `Exited (143)`; a crash marks them `Exited (255)`. `--rm` containers that were running are removed on restore. `ps` hides stopped containers.

Stop the daemon with Ctrl+C, then wipe images / containers / volumes / networks (keeps kernel and initfs):

```bash
make reset
```

## Layout

| Path | What it is |
| --- | --- |
| `App/` | SwiftUI GUI (`io.macker.app`) — not on the CLI release line |
| `Sources/` | SPM: products `mackerd` / `macker` / `macker-helper` |
| `Vendor/containerization` | Pinned Apple containerization submodule |

## Make targets

Run these from the repo root. Prefer Make over calling `scripts/` directly.

| Target | Purpose |
| --- | --- |
| `app` | Debug-build the daemon and ad-hoc sign it |
| `macker` | Debug-build the CLI and `macker-helper` |
| `helper` | Debug-build `macker-helper` |
| `run` | `app`, then start the daemon |
| `sign` | Re-sign an already-built debug `mackerd` |
| `fetch-runtime` | Download the pinned kernel + vminit into the store |
| `reset` | Delete store `content/`, `containers/`, `volumes/`, `networks/` |
| `cli` | Release CLI prefix in `dist/cli` |
| `dist` | CLI prefix + tarball + `SHA256SUMS`. `CERT_NAME` + `NOTARIZE=1` uses Developer ID and notarytool |
| `install` | Copy `dist/cli` to `PREFIX` (default `/usr/local`) |
| `bundle` | Release `dist/MackerDaemon.app` (signing shell, not the GUI) |
| `pkg` | Release `.app` + `dist/MackerDaemon.pkg` |
| `check` | Fail if `RuntimePin.json` ≠ containerization submodule tag |
| `sync-runtime` | Show or set pins (`ARGS='containerization 0.42.0'`) |
| `sync-runtime-latest` | Bump pins to GitHub latest stable |
| `test` | Run unit tests (CLI + REST + engine; no MicroVM) |
| `smoke` | Signed daemon + alpine `run --rm` / `exec` / `-p` on an isolated `--store` (`SMOKE_SKIP_VM=1` skips MicroVMs) |

```bash
VERSION=1.2.3 make dist
CERT_NAME='Developer ID Application: …' NOTARIZE=1 VERSION=1.2.3 make dist
VERSION=1.2.3 make pkg
make sync-runtime ARGS='kata 3.28.0'
```

Debug builds report version `0.0.0`. Pass `VERSION=` (or `MACKER_VERSION=`) when packaging.

CLI prefix layout (`docs/packaging.md`): `bin/macker` + `bin/mackerd` are exec wrappers around `libexec/macker/` (binaries + SwiftPM `*.bundle`). Guest kernel/initfs live in `share/macker/runtime/`. Preview users install that tarball with `scripts/install.sh`, not Homebrew.

## Scripts (`scripts/`)

Make targets call these.

| Script | Used by | Role |
| --- | --- | --- |
| `install.sh` | README / GitHub Release | Download a release tarball into `~/.macker` |
| `sign-app.sh` | `make app` / `sign` | Ad-hoc sign the debug daemon |
| `fetch-runtime.sh` | `make fetch-runtime`; packaging if `.runtime` is missing | Install kernel/initfs into the store |
| `reset-store.sh` | `make reset` | Wipe engine state; keep `runtime/`, `initfs.ext4`, `daemon-id` |
| `package-cli.sh` | `make cli` / `dist` / `install` | CLI prefix and tarball |
| `notarize-cli.sh` | `make dist` when `NOTARIZE=1` | Submit signed `libexec/macker` to notarytool |
| `package.sh` | `make bundle` / `pkg` | Signing-shell `.app` / `.pkg` |
| `sync-runtime.sh` | `make check` / `sync-runtime*` | Edit pins and the submodule |
| `lib.sh` | sourced by the others | Shared paths and helpers |

`fetch-runtime` and `sync-runtime` stay separate: one downloads the current pin, the other changes the pin.

A `v*` tag runs `.github/workflows/release-macos.yml` (Developer ID + notarytool) and uploads the tarball, `SHA256SUMS`, and `scripts/install.sh`.

## Store and pins

Daemon data lives in `~/Library/Application Support/io.macker.daemon/`:

- `macker.sock` — API socket (removed when the daemon exits)
- `runtime/vmlinux`, `initfs.ext4` — guest kernel and initfs
- `content/`, `volumes/`, `containers/`, `networks/`, `auth.json` — engine state (`make reset` keeps `auth.json`). Container metadata is `containers/<id>.json`; MicroVM disks under `containers/<id>/` are recreated on each start.

Guest versions are pinned in `Sources/ContainerEngine/RuntimePin.json` (`containerization`, `kata`). `.runtime/` is a packaging cache only (gitignored), not the runtime store.

## GUI

Open `App/Macker.xcodeproj`. Debug uses Xcode’s default `MARKETING_VERSION` (`1.0`). Archive with:

```bash
xcodebuild -project App/Macker.xcodeproj \
  MARKETING_VERSION=1.2.3 CURRENT_PROJECT_VERSION=42
```
