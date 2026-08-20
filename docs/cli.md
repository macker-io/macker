# CLI compatibility

Compared against the [Docker Engine CLI](https://docs.docker.com/reference/cli/docker/). This document lists the Docker-compatible commands Macker ships, then the options that are still missing or accepted without matching Docker’s behavior.

Not compared: Macker-only commands (`setup`, `fetch-runtime`, `doctor`, `status`, `helper`). Not shipped: Compose, Swarm, buildx, checkpoint, plugins, secrets, configs, and other Docker product surfaces.

`--format` (`images`, `history`, `search`, `version`, `info`, `events`, `system df`, `inspect`, `volume ls`) supports `table`, `{{.Field}}` (including dotted paths), and `json`. No pipeline functions, `if`, or `range`.

Networking model: [networking.md](networking.md). BuildKit follow-up: [buildkit.md](buildkit.md).

## Commands

| Area      | Commands                                                                                                                                                                                                                                 |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Container | `run`, `create`, `start`, `stop`, `restart`, `kill`, `rm`, `pause`, `unpause`, `rename`, `logs`, `wait`, `top`, `stats`, `attach`, `exec`, `cp`, `export`, `diff`, `commit`, `port`, `ps` / `container ls`, `inspect`, `container prune` |
| Image     | `pull`, `push`, `images` / `image ls`, `rmi` / `image rm`, `tag`, `history`, `search`, `inspect`, `save`, `load`, `import`, `image prune`, `build`                                                                                       |
| Builder   | `build`, `builder prune`                                                                                                                                                                                                                 |
| Volume    | `volume ls`, `create`, `inspect`, `rm`, `prune`                                                                                                                                                                                          |
| Network   | `network ls`, `create`, `inspect`, `rm`, `connect`, `disconnect`, `prune`                                                                                                                                                                |
| System    | `version`, `info`, `events`, `system df`, `system prune`, `login`, `logout`                                                                                                                                                              |

Options are complete (no extra notes below) for: `pause`, `unpause`, `rename`, `wait`, `diff`, `port`, `attach`, `login`, `logout`, `kill`, `export`, `cp`, `rmi`, `search`, `save`, `image prune`, `version`, `info`, `events`, `system df`, `system prune`, `volume ls`, `volume create`, `volume inspect`, `volume rm`, `volume prune`, `network ls`, `network inspect`, `network rm`, `network disconnect`, `network prune`, `start`, `stop`, `restart`, `exec`, `inspect`, `top`, `container prune`, `history`.

## Container

### `run` / `create`

CLI options are wired. `--hostname` has no short `-h` (reserved for `--help`). `--ip6` is rejected. `--network container:` / `macvlan` / `ipvlan` are not implemented. `--volume-driver` must be `local`. `--rm` and `--restart` conflict. Foreground `--rm` is removed by the CLI after wait; `-d --rm` uses engine AutoRemove.

| Accepted but no-op / different                                                              | Notes                                                                                                      |
| ------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `--dns`                                                                                     | Guest still queries the gateway so container names resolve; recursion uses these servers                   |
| `--mac-address`                                                                             | Stored on the endpoint; virtio-net overwrites it at start                                                  |
| `--link-local-ip`                                                                           | Stored on the endpoint; unused by the dataplane                                                            |
| `--privileged`, `--read-only`, `--init`, `--group-add`                                      | Visible on inspect (`--init` is not); guest config is unchanged                                            |
| healthcheck                                                                                 | Probed while running; `ps` shows `(healthy)` / `(unhealthy)` / `(health: starting)`                        |
| `--restart`                                                                                 | `always` / `unless-stopped` also start after daemon restart (`unless-stopped` skips a prior `stop`)        |
| `--cpus`                                                                                    | Rounded from NanoCpus to a vCPU count                                                                      |
| Resource / cap / device / log / ulimit / sysctl / cgroup / namespaces other than `--memory` | Accepted on the CLI; most never reach the API                                                              |
| `--tmpfs`                                                                                   | Host directory + virtiofs, not a kernel tmpfs                                                              |
| Windows: `--cpu-count`, `--cpu-percent`, `--io-maxbandwidth`, `--io-maxiops`                | Not implemented                                                                                            |

### `ps` / `container ls`

`-s` SIZE is the guest disk image file size (`SizeRw` and `SizeRootFs` are the same). No `health` / `isolation` / `is-task` filters.

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

`--opt` is stored on inspect and does not change the dataplane. `--ipv6` / IPv6 `--subnet` is rejected. `--ipam-driver` must be `default`. `--driver` is `bridge` only. Swarm options are not planned: `--attachable`, `--ingress`, `--config-from`, `--config-only`, `--scope`.

### `network connect`

`--link` is treated as an alias. `--ip6` is rejected (no IPv6). Accepted but unused: `--link-local-ip`, `--driver-opt`, `--gw-priority`. Connecting a running container that has no bridge NIC yet still returns 501 (no virtio-net hot-plug).

## Volume

`volume create --driver` is `local` only. Cluster Volume options are not implemented.
