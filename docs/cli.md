# CLI compatibility

Compared against the [Docker Engine CLI](https://docs.docker.com/reference/cli/docker/). This document lists the Docker-compatible commands Macker ships, then the options that are still missing or accepted without matching Docker’s behavior.

Not compared: Macker-only commands (`setup`, `fetch-runtime`, `doctor`, `status`, `helper`). The CLI package ships `macker compose` with private Compose and Buildx binaries. There is no standalone `macker buildx` command. Swarm, checkpoint, engine plugins, secrets and configs are not implemented. Unsupported management commands are recognized; see below.

## Official `docker` CLI and Compose

`macker compose` runs the packaged upstream Compose client with Macker’s Unix socket. Project options, arguments, terminal streams and exit codes pass through to Compose. Use `macker -H unix:///path/to/macker.sock compose …` for an explicit endpoint. Its client state (including Buildx and client-side registry configuration) lives under `~/.macker/compose`, or `<dir>/compose` with `macker --config <dir>`. It honors `macker context use` when no host override is set. It ignores the ambient Docker context and does not edit `~/.docker`.

Alternatively, the official `docker compose` plugin reads your `compose.yaml` and manages the project; Macker runs the containers through the Docker Engine API. Tested with Docker CLI 29.8.2 and Compose 5.5.0. To use Macker for one project without changing your active Docker context:

```bash
macker setup                         # creates the `macker` context; never switches the active one
docker --context macker compose up -d
docker --context macker compose ps
docker --context macker compose down
macker doctor                        # docker CLI, compose plugin, context, socket, API version
```

To make Macker your default, run `docker context use macker`. `DOCKER_HOST=unix://…/macker.sock` also works. See [Compose compatibility testing](develop.md#compose-compatibility-testing) for the acceptance suite and what CI verifies.

- API versions: `/v1.24` … `/v1.44` path prefixes and unversioned paths (served as 1.44) are accepted; anything newer gets Docker's `client version … is too new` 400, older gets `… is too old`. Version-dependent shapes are honored where they differ in that range (`volumes/prune` defaults to anonymous-only from 1.42; non-TTY attach/exec/logs report `application/vnd.docker.multiplexed-stream` from 1.42).
- `version` / `info` report the container platform (`linux` / `arm64`, `aarch64`), not the Mac.
- Foreground `docker run` works as with Docker: `wait?condition=next-exit|removed` returns its header at once and the status at exit; stdout and stderr stay separate; `-i` stdin EOF reaches the process; `-t` resizes; `--sig-proxy` signals are delivered (use `--init` so PID 1 handles `SIGTERM`).
- `docker kill -s SIG` delivers the signal and does not wait; only `SIGKILL` waits for the exit.
- `docker logs` preserves stdout/stderr and capture times, including on replay. `--timestamps`, `--since`, and `--until` use those times; `--tail` can read recent records without loading the whole log.
- Events carry the container's labels as actor attributes; `events --filter label=…` works.
- `docker build` / `docker compose build` use BuildKit through a daemon-managed builder and load the result without `--load`: [buildkit.md](buildkit.md).
- A container's writable filesystem survives `stop` / `start` and daemon restarts; it is discarded by `rm`. `docker cp` into a created or stopped container is applied at its next start, before the process runs.
- `pull` by digest (`alpine@sha256:…`), `images --filter reference=` globs (`alpine*`), `RestartCount`, and Docker's `port is already allocated` error for a host port held by another container match Docker.

`--format` (`images`, `history`, `search`, `version`, `info`, `events`, `system df`, `inspect`, `volume ls`) supports `table`, `{{.Field}}` (including dotted paths), `{{json .}}`, `{{json .Field}}`, and `json`. No pipeline functions, `if`, or `range`.

Networking model: [networking.md](networking.md). BuildKit: [buildkit.md](buildkit.md).

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

CLI options are wired. `--hostname` (`-h` on `run` / `create`) sets the container hostname. `--ip6` assigns static IPv6 on dual-stack bridge networks; `-p` supports bracketed IPv6 bindings such as `[::1]:8080:80`. `--network container:<name>` (and Compose `network_mode: service:…`) is rejected as not supported: each container is a separate MicroVM with its own kernel, so there is no network namespace to share; put the containers on one user-defined network instead. `macvlan` / `ipvlan` are not implemented. `--platform` must be `linux/arm64` (no x86_64 emulation); other platforms are rejected for `run`, `create` and `pull`. `--volume-driver` must be `local`. `--rm` and `--restart` conflict. Foreground `--rm` is removed by the CLI after wait; `-d --rm` uses engine AutoRemove. `--read-only` mounts the root filesystem read-only. `--sysctl`, `--ulimit`, and `--security-opt no-new-privileges` are applied in the guest. `--init` runs a minimal init as PID 1 (signal forwarding, zombie reaping). `--stop-signal` / `--stop-timeout` are used by `stop`. `-p` fails with Docker's `port is already allocated` when another running container holds the same host address and port.

`--privileged`, `--cap-add` and `--cap-drop` are applied inside the container's own MicroVM with Docker's rules (default set, `ALL`, add-wins-over-drop, `unknown capability` errors): privileged gets every capability and no masked or read-only `/proc` / `/sys` paths, and the VM's devices are visible. The VM boundary is unchanged, so none of this reaches the Mac. `exec` inherits the container's set; `exec --privileged` gets all.

Rejected with an error naming the option (each container is its own MicroVM, so these would otherwise be silently ignored): `--security-opt` other than `no-new-privileges`, `--pid`, `--ipc` (other than `private` / `shareable`), `--uts`, `--userns`, `--cgroupns host`, `--cgroup-parent`, `--device`, `--gpus`, `--device-cgroup-rule`, `--group-add`, `--link`, `--storage-opt`, `--annotation`, `--oom-score-adj`, `--oom-kill-disable`, `--pids-limit`, `--shm-size`, `-c` / `--cpu-shares`, `--cpu-period`, `--cpu-quota`, `--cpu-rt-*`, `--cpuset-*`, `--memory-reservation`, `--memory-swap` (other than `-1` or equal to `--memory`), `--memory-swappiness`, `--blkio-weight*`, `--device-read/write-*`, `--log-driver` (other than `json-file`), `--log-opt`, `--runtime`, `--isolation`, `--network-disabled`, `--mount` types other than `bind` / `volume` / `tmpfs`, and Windows-only `--cpu-count` / `--cpu-percent` / `--io-maxbandwidth` / `--io-maxiops`.

| Accepted but different | Notes                                                                                               |
| ---------------------- | --------------------------------------------------------------------------------------------------- |
| `--dns`                | Guest still queries the gateway so container names resolve; recursion uses these servers            |
| `--mac-address`        | Stored on the endpoint; virtio-net overwrites it at start                                           |
| `--link-local-ip`      | Stored on the endpoint; unused by the dataplane                                                     |
| healthcheck            | Probed while running; `ps` shows `(healthy)` / `(unhealthy)` / `(health: starting)`                 |
| `--restart`            | `always` / `unless-stopped` also start after daemon restart (`unless-stopped` skips a prior `stop`) |
| `--cpus`               | Rounded from NanoCpus to the MicroVM's vCPU count (`nproc` in the guest)                            |
| `--memory`             | Sizes the whole MicroVM (guest `MemTotal`); minimum 64MB. Without it the VM gets 1 GiB + agent headroom |
| `--restart`            | `on-failure:N` stops after N restarts; `RestartCount` is reported and reset by a user `start`        |
| `--tmpfs`              | Host directory + virtiofs (emptied on each start), not a kernel tmpfs                               |

### `update`

`--memory` / `-m`, `--cpus`, and `--restart` are applied. `0` leaves the previous limit unchanged. A running MicroVM is not resized; the new limit is stored and used on the next start, and the API returns that as a warning. Other resource flags are accepted and returned as warnings, not applied. `--restart` with `--rm` is a conflict.

### `ps` / `container ls`

`-s` SIZE is the guest disk image file size (`SizeRw` and `SizeRootFs` are the same). Supports `--filter health=`. No `isolation` / `is-task` filters.

### `rm` / `container rm`

`--link` is a legacy no-op.

### `logs`

`--details` is accepted and does not change output (no log attributes are recorded). Log files written by older Macker versions (plain text) are converted on load; their lines get the container's finish time and count as stdout.

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

The official `docker build` (BuildKit via buildx) is served by the daemon-managed BuildKit builder: [buildkit.md](buildkit.md). The rest of this section is `macker build` and `DOCKER_BUILDKIT=0 docker build`, which use the classic builder. CLI options are wired. `--iidfile`, `--network` (`container:` / `macvlan` / `ipvlan` rejected), `--add-host`, and `-m` / `--memory` apply to each `RUN` MicroVM.

| Accepted but no-op / different                                                                                                   | Notes                                                          |
| -------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| `--cache-from`                                                                                                                   | Classic builder does not use external cache sources            |
| `--rm`, `--force-rm`                                                                                                             | Intermediate containers are always removed; cannot be disabled |
| `--compress`                                                                                                                     | Context is never gzipped                                       |
| `--memory-swap`, `-c` / `--cpu-shares`, `--cpu-period`, `--cpu-quota`, `--cpuset-*`, `--ulimit`, `--shm-size`, `--cgroup-parent` | `RUN` resources; only `--memory` is applied                    |
| `--security-opt`, `--isolation`, `--squash`                                                                                      | Windows / experimental                                         |
| `--platform`                                                                                                                     | Accepted; builds host only, with a warning                     |
| Context as a URL or `-` (stdin)                                                                                                  | Local directory only                                           |

BuildKit-only syntax (`RUN --mount`, heredocs, `--secret`, `--ssh`) is rejected by the classic builder; use the official `docker build`.

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
