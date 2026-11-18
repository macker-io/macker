# CLI compatibility

Compared against the [Docker Engine CLI](https://docs.docker.com/reference/cli/docker/). This document lists the Docker-compatible commands Macker ships, then the options that are still missing or accepted without matching Docker’s behavior.

Not compared: Macker-only commands (`setup`, `fetch-runtime`, `doctor`, `status`, `helper`). Not implemented as working product surfaces: Compose, buildx, and Swarm membership. `plugin`, `checkpoint`, `swarm`, `node`, `service`, `secret`, `config`, and `stack` are recognized; see below.

`--format` (`images`, `history`, `search`, `version`, `info`, `events`, `system df`, `inspect`, `volume ls`) supports `table`, `{{.Field}}` (including dotted paths), `{{json .}}`, `{{json .Field}}`, and `json`. No pipeline functions, `if`, or `range`.

Networking model: [networking.md](networking.md). BuildKit follow-up: [buildkit.md](buildkit.md).

## Commands

| Area      | Commands                                                                                                                                                                                                                                 |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Container | `run`, `create`, `start`, `stop`, `restart`, `update`, `kill`, `rm`, `pause`, `unpause`, `rename`, `logs`, `wait`, `top`, `stats`, `attach`, `exec`, `cp`, `export`, `diff`, `commit`, `port`, `ps` / `container ls` (`ps`, `list`), `inspect`, `container prune` |
| Image     | `pull`, `push`, `images` / `image ls` (`list`), `rmi` / `image rm`, `tag`, `history`, `search`, `inspect`, `save`, `load`, `import`, `image prune`, `build` / `image build`                                                       |
| Builder   | `build`, `builder prune`                                                                                                                                                                                                                 |
| Volume    | `volume ls` (`list`), `create`, `inspect`, `rm`, `prune`                                                                                                                                                                                 |
| Network   | `network ls` (`list`), `create`, `inspect`, `rm`, `connect`, `disconnect`, `prune`                                                                                                                                                       |
| System    | `version`, `info`, `events`, `system df`, `system prune`, `login`, `logout`                                                                                                                                                              |
| Plugin    | `plugin ls`, `inspect`, `install`, `enable`, `disable`, `rm`, `create`, `push`, `set`, `upgrade`                                                                                                                                         |
| Swarm     | `swarm`, `node`, `service`, `secret`, `config`, `stack` (commands recognized; this node is not a swarm manager)                                                                                                                          |
| Other     | `checkpoint`, `context`, `manifest`, `trust`, `system dial-stdio`                                                                                                                                                                       |

Options are complete (no extra notes below) for: `pause`, `unpause`, `rename`, `wait`, `diff`, `port`, `attach`, `login`, `logout`, `kill`, `export`, `cp`, `rmi`, `search`, `save`, `image prune`, `version`, `info`, `events`, `system df`, `system prune`, `volume ls`, `volume create`, `volume inspect`, `volume rm`, `volume prune`, `network ls`, `network inspect`, `network rm`, `network disconnect`, `network prune`, `start`, `stop`, `restart`, `exec`, `inspect`, `top`, `container prune`, `history`.

## Container

### `run` / `create`

CLI options are wired. `--hostname` (`-h` on `run` / `create`) sets the container hostname. `--ip6` assigns static IPv6 on `--ipv6` bridge networks. `-p` supports bracketed IPv6 host bindings such as `[::1]:8080:80`. `--network container:` / `macvlan` / `ipvlan` are not implemented. `--volume-driver` must be `local`. `--rm` and `--restart` conflict. Foreground `--rm` is removed by the CLI after wait; `-d --rm` uses engine AutoRemove.

| Accepted but no-op / different                                                              | Notes                                                                                                      |
| ------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `--dns`                                                                                     | Guest still queries the gateway so container names resolve; recursion uses these servers                   |
| `--mac-address`                                                                             | Stored on the endpoint; virtio-net overwrites it at start                                                  |
| `--link-local-ip`                                                                           | Stored on the endpoint; unused by the dataplane                                                            |
| `--privileged`, `--read-only`, `--group-add`                                               | `--privileged` grants all Linux capabilities and drops masked/readonly paths inside the MicroVM; `--read-only` / `--group-add` are inspect-only |
| `--init`, `--cap-add`, `--cap-drop`, `--sysctl`, `--ulimit`, `--security-opt no-new-privileges` | Applied to the MicroVM container config at start |
| healthcheck                                                                                 | Probed while running; `ps` shows `(healthy)` / `(unhealthy)` / `(health: starting)`                        |
| `--restart`                                                                                 | `always` / `unless-stopped` also start after daemon restart (`unless-stopped` skips a prior `stop`)        |
| `--cpus`                                                                                    | Rounded from NanoCpus to a vCPU count                                                                      |
| Device / log / cgroup / namespaces / `--shm-size` / other resources                         | Sent to the API and returned as create warnings; the guest is unchanged                                   |
| `--tmpfs`                                                                                   | Host directory + virtiofs, not a kernel tmpfs                                                              |
| Windows: `--cpu-count`, `--cpu-percent`, `--io-maxbandwidth`, `--io-maxiops`                | Not implemented                                                                                            |

### `update`

`--memory` / `-m`, `--cpus`, and `--restart` are applied. `0` leaves the previous limit unchanged. A running MicroVM is not resized; the new limit is stored and used on the next start, and the API returns that as a warning. Other resource flags are accepted and returned as warnings, not applied. `--restart` with `--rm` is a conflict.

### `ps` / `container ls`

`-s` SIZE is the guest disk image file size (`SizeRw` and `SizeRootFs` are the same). Supports `--filter health=`. No `isolation` / `is-task` filters.

### `rm` / `container rm`

`--link` is a legacy no-op.

### `logs`

`--details` is accepted and does not change output.

### `stats`

No BLOCK I/O column (guest `/proc` has none). `--format` `.BlockIO` is always `0B / 0B`.

### `commit`

`--pause` is accepted and ignored (the snapshot goes through the guest and cannot freeze the MicroVM).

## Image

### `pull`

`--disable-content-trust` is accepted and unused (no content trust).

### `push`

`--disable-content-trust` is accepted and unused (no image signing).

### `images` / `image ls`

Missing: `--tree`.

### `load`

`--platform` is accepted and unused; a warning is printed (vendored load has no platform filter).

### `import`

`--platform` is host only.

### `build` / `builder build`

Classic builder only (`DOCKER_BUILDKIT=0`), not buildx. CLI options are wired. `--iidfile`, `--network` (`container:` / `macvlan` / `ipvlan` rejected), `--add-host`, and `-m` / `--memory` apply to each `RUN` MicroVM.

| Accepted but no-op / different                                                                                                   | Notes                                                          |
| -------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| `--cache-from`                                                                                                                   | Classic builder does not use external cache sources            |
| `--rm`, `--force-rm`                                                                                                             | Intermediate containers are always removed; cannot be disabled |
| `--compress`                                                                                                                     | Context is never gzipped                                       |
| `--memory-swap`, `-c` / `--cpu-shares`, `--cpu-period`, `--cpu-quota`, `--cpuset-*`, `--ulimit`, `--shm-size`, `--cgroup-parent` | `RUN` resources; only `--memory` is applied                    |
| `--security-opt`, `--isolation`, `--squash`                                                                                      | Windows / experimental                                         |
| `--platform`                                                                                                                     | Accepted; builds host only, with a warning                     |
| Context as a URL or `-` (stdin)                                                                                                  | Local directory only                                           |

BuildKit syntax (`# syntax=`, heredocs, `RUN --mount`, `--secret`, `--ssh`, bake, multi-platform) is out of scope; see [buildkit.md](buildkit.md).

### `builder prune`

Shipped: `-f`, `-a` / `--all`, `--filter` (`until`, `id`). `--all` also drops dangling digest images that are not in the cache index. Accepted but unused: `--keep-storage`, `--reserved-space`, `--max-used-space`, `--min-free-space`.

## Network

### `network create`

`--opt` is stored on inspect and does not change the dataplane. `--ipv6` allocates a ULA `/64` (or uses the given IPv6 `--subnet` / `--gateway`) on `bridge` networks; `--ipv4=false` (IPv6-only) is not supported. `--ipam-driver` must be `default`. `--driver` is `bridge` only. Swarm options are not planned: `--attachable`, `--ingress`, `--config-from`, `--config-only`, `--scope`.

### `network connect`

`--link` is treated as an alias. `--ip6` assigns a static IPv6 address on `--ipv6` bridge networks. Accepted but unused: `--link-local-ip`, `--driver-opt`, `--gw-priority`. Connecting a running container that has no bridge NIC yet still returns 501 (no virtio-net hot-plug).

## Volume

`volume create --driver` is `local` only. Cluster Volume options are not implemented.

## Plugin, Swarm, checkpoint

These commands exist so `docker` aliased to `macker` does not report an unknown command, and so the official `docker` CLI talking to the socket does not get `page not found`.

`plugin ls` is an empty list. Install, pull, and create return 501. Inspect, enable, disable, rm, push, set, and upgrade return 404 `plugin "…" not found`.

`node`, `service`, `task`, `secret`, `config`, and swarm reads return 503 with Docker's non-manager message. `swarm init` and `swarm join` return 501 (`swarm is not implemented`). `stack deploy` and `stack config` are Compose and return that Compose is not implemented. Other `stack` commands hit the Swarm APIs and get the non-manager error.

`checkpoint` returns 501 `checkpoint is not supported on this runtime` after the container is resolved. A missing container is 404.

`context` is stored under `~/.macker` (`~/.docker` when the binary is invoked as `docker`). `--host` / `-H`, `--context` / `-c`, and `--config` before the subcommand select the daemon. `MACKER_HOST` and `DOCKER_HOST` still override the current context. Only `unix://` endpoints are supported.

`manifest inspect` fetches the registry manifest through `GET /distribution/{name}/json`. Manifest lists (`create`, `annotate`, `push`, `rm`) are not implemented. `trust` commands are recognized; signing is not implemented. `trust inspect` still resolves the registry descriptor and reports no signatures. `system dial-stdio` proxies the selected UNIX socket over stdin and stdout.
