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
| `App/` | SwiftUI desktop preview (`io.macker.app`) — not on the CLI release line |
| `ClientTransport/` | Unix HTTP transport shared by the desktop app and CLI |
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
| `smoke` | Signed daemon on an isolated `--store`: image pinning, writable layer and logs across restart, signal delivery, and IPv4/IPv6 port publishing (`SMOKE_SKIP_VM=1` skips MicroVMs) |

```bash
VERSION=1.2.3 make dist
CERT_NAME='Developer ID Application: …' NOTARIZE=1 VERSION=1.2.3 make dist
VERSION=1.2.3 make pkg
make sync-runtime ARGS='kata 3.28.0'
```

Debug builds report version `0.0.0`. Pass `VERSION=` (or `MACKER_VERSION=`) when packaging.

CLI prefix layout (`docs/packaging.md`): `bin/macker` + `bin/mackerd` are exec wrappers around `libexec/macker/` (binaries + SwiftPM `*.bundle`). Guest kernel/initfs live in `share/macker/runtime/`. Preview users install that tarball with `scripts/install.sh`, not Homebrew.

## Compose compatibility testing

[PR CI](../.github/workflows/test.yml) runs `make test`. It does not run the official Docker CLI or boot a MicroVM. To test Compose against a signed local daemon, install the [tested client versions](cli.md#official-docker-cli-and-compose) and run from the repo root:

```bash
make app macker fetch-runtime
ONLY=compose_basic scripts/compat/run.sh compose  # one project: up, exec, logs, down
scripts/compat/run.sh compose compose2            # both Compose runtime suites
```

The [harness](../scripts/compat/run.sh) uses the clients on `PATH` and prints their versions. It resets containers, networks, and volumes in its test store; use a dedicated `COMPAT_STORE`, never a product store. Other suites cover the Docker CLI, builds, and context setup.

**Remaining CI work:**

- [ ] Pin the Docker CLI and Compose plugin versions; verify artifact checksums and assert the versions before running tests.
- [ ] Pin fixture images by arm64 digest so a tag update cannot change the workload under test.
- [ ] Require official-client contract tests and signed MicroVM runtime tests in CI. Disable host-route changes for these jobs; test helper/utun behavior separately on a dedicated runner.
- [ ] Run a non-blocking job against the latest clients to detect compatibility changes.

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
- `content/`, `volumes/`, `containers/`, `networks/`, `auth.json` — engine state (`make reset` keeps `auth.json`). Container metadata is `containers/<id>.json`; Each container's writable `containers/<id>/rootfs.ext4` survives stop/start and daemon restart and is deleted when the container is removed.

Guest versions are pinned in `Sources/ContainerEngine/RuntimePin.json` (`containerization`, `kata`). `.runtime/` is a packaging cache only (gitignored), not the runtime store.

## GUI

On macOS 26.5+, open `App/Macker.xcodeproj` and run the **Macker** scheme with `mackerd` already running (for example, `make run` from another terminal). Containers, Images, Networks, and Volumes share one periodic refresh loop with the menu bar. The Images page filters images by container references (including stopped containers), and supports pulling, loading image archives, importing root filesystem archives, exporting, copying references, and deleting unused images. The other resource pages are read-only. Use **Refresh** or ⌘R to refresh immediately. Close the window and reopen it via **Open Macker** in the menu bar. Quitting the app leaves the daemon running. The fish's stripe is bright when a container is running; its eye blinks during an active classic build or BuildKit solve reported by `GET /macker/status`. Older daemons fall back to container list data without a build indicator. With Reduce Motion enabled, the eye remains visible and the menu still shows build activity.

The app connects to the default Macker Unix socket and does not use `DOCKER_HOST`. To test against an isolated daemon, set `MACKER_HOST=unix:///absolute/path/to/macker.sock` in the Xcode Run scheme. The desktop app is not sandboxed because it connects directly to the existing daemon socket outside its app container. It keeps the hardened runtime enabled and needs neither root nor virtualization entitlements.

For a local command-line build without a development team:

```bash
xcodebuild -project App/Macker.xcodeproj -scheme Macker -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/desktop \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
open .build/desktop/Build/Products/Debug/Macker.app
```

The Dock icon is the layered [`AppIcon.icon`](../App/Macker/AppIcon.icon), opened with Icon Composer. The Dock and menu bar share the [`MackerFish.svg`](../App/Artwork/MackerFish.svg) outline. After editing the fish geometry, run `python3 scripts/generate-desktop-icons.py` on macOS to regenerate the transparent foreground layer and the monochrome menu bar variants. Edit the Dock background in Icon Composer, not in the foreground layer.

Debug uses Xcode's default `MARKETING_VERSION` (`1.0`). Archive with:

```bash
xcodebuild -project App/Macker.xcodeproj \
  MARKETING_VERSION=1.2.3 CURRENT_PROJECT_VERSION=42
```
