# Docker Compose Integration Plan

**Archived proposal — not a support matrix or a list of outstanding work.** The official-client integration landed on `main` in `83cd8d5`. The API 1.41-only target, BuildKit deferral, and blanket IPv6 exclusion below are historical. See [CLI compatibility](../cli.md), [BuildKit](../buildkit.md), and the [remaining CI work](../develop.md#compose-compatibility-testing) for current information.

Decision: Use the official Docker CLI and Docker Compose plugin with Macker as the Docker Engine API backend.

Delivery strategy: Ship small, vertically testable compatibility milestones (`C0`–`C8`) instead of one cross-layer implementation.

## 1. Goal

Allow an existing Compose project within Macker's documented compatibility profile to switch its container backend without adopting a Macker-specific YAML format or orchestration model.

The intended user workflow is:

```bash
macker setup
docker --context macker compose up -d
docker --context macker compose ps
docker --context macker compose down
```

Users may explicitly select the context when they want Macker as their current Docker backend:

```bash
docker context use macker
```

Macker-specific host and runtime operations remain under the `macker` command:

```bash
macker doctor
macker status
macker fetch-runtime
macker helper status
```

The compatibility promise applies only to fields and commands marked supported in the published matrix. Unsupported workloads must not require Macker-specific changes to otherwise supported Compose files, but Macker will not claim that every valid Compose file works unchanged.

## 2. Architecture decision

### 2.1 Decision

Docker Compose remains the orchestration client. Macker will not implement its own Compose YAML parser, project reconciler, dependency graph, profiles, interpolation, or scaling logic.

```text
compose.yaml
    |
    v
Official Docker CLI + Compose plugin
    |
    | Docker Engine API over a UNIX socket
    v
DockerAPIAdapter
    |
    | validated, protocol-neutral specs and results
    v
ContainerEngine
    |
    | narrow privileged host-network operations
    v
macker-helper
```

### 2.2 Alternatives not selected

- **Native Swift Compose implementation:** rejected because it would duplicate Compose parsing and reconciliation, drift from the specification, and create a second orchestration product.
- **Bundled Compose as the first step:** deferred because API compatibility can be validated with an externally installed, pinned client before Macker takes on binary distribution and update responsibilities.
- **`alias docker="macker"`:** rejected for Compose because it prevents the official Docker CLI from discovering its Compose plugin.
- **Default replacement of `/var/run/docker.sock`:** rejected because it can disrupt Docker Desktop, Podman, or another engine and is less reversible than a Docker context.

### 2.3 Consequences

- Compose compatibility is primarily a Docker Engine API contract problem.
- Macker must track the request and response behavior of tested official clients.
- Client-side features such as YAML parsing, profiles, interpolation, dependency planning, and project hashing remain outside Macker.
- Runtime limitations such as MicroVM cost, unsupported network drivers, and missing BuildKit remain Macker product constraints and must be surfaced clearly.

## 3. Responsibility and seam contracts

These are architecture boundaries, not requirements to introduce heavyweight protocols or classes. Pure value types and translation functions are preferred when sufficient.

### 3.1 Official client to setup CLI

Conceptual seams:

- `DockerToolchainProbe`: discovers the Docker CLI, Compose plugin, versions, context state, and API negotiation result.
- `DockerContextManager`: ensures or removes the Macker context through an explicit, idempotent state machine.
- `SetupEnvironment`: provides process execution, filesystem/home/environment access, and output so setup can be tested without touching the real user account.

Rules:

- `mackerd` and `ContainerEngine` never invoke the Docker CLI or manage Docker contexts.
- Setup never edits Docker CLI internals.
- Setup never switches the active context implicitly.
- Doctor consumes the same read-only probe rather than reimplementing context and toolchain interpretation.

### 3.2 Docker HTTP to API adapter

Conceptual seams:

- `DockerAPIVersionPolicy`: minimum, maximum, numeric comparison, unversioned behavior, and precise errors.
- Docker request/response DTOs: official wire names, casing, field locations, and version-specific shapes.
- DTO translators and serializers: validate Docker semantics and convert to or from protocol-neutral engine values.

Rules:

- Docker API versions, wire casing, Compose compatibility dispositions, and client syntax remain in `DockerAPIAdapter` or `CliCore`.
- Version-specific behavior must not leak into `ContainerEngine`.
- Do not add new Docker presentation or parsing concerns to `ContainerEngine`; cleaning existing leakage is a separate refactor unless a milestone directly requires it.

### 3.3 API adapter to container engine

The adapter passes validated, protocol-neutral specifications to the engine.

```text
DockerCreateContainerRequest
          |
          v
DockerContainerCreateTranslator
          |
          +-- supported
          +-- approximated
          +-- rejected
          +-- inert-default
          |
          v
EngineContainerCreateSpec
```

Rules:

- Compose labels are opaque metadata dictionaries in `ContainerEngine`.
- `ContainerEngine` does not interpret `com.docker.compose.*` keys.
- Engine invariants are still validated by the engine even after adapter validation.
- Avoid a monolithic mockable engine protocol; pure translators plus the existing temporary engine are sufficient for most adapter tests.

### 3.4 Container engine to privileged helper

Introduce a narrow host-route control seam before Compose runtime tests:

```text
HostRouteController
    +-- disabled       # Compose CI and ordinary isolated tests
    +-- automatic      # normal product behavior
    +-- real helper    # dedicated privileged smoke test
```

Rules:

- An isolated `--store` and socket must not imply permission to mutate machine-global utun interfaces or routes.
- Compose CI uses host-route control disabled; published ports and bridge outbound traffic do not require the helper.
- Helper/utun behavior is tested separately in a serialized, explicitly privileged job.

### 3.5 Runtime and host platform

Keep one source of truth for each platform view:

```text
RuntimePlatform: os=linux, architecture=arm64
HostPlatform:    os=macOS, architecture=<host canonical value>
```

- Image selection and Docker runtime-facing fields use `RuntimePlatform`.
- Host diagnostics use `HostPlatform`.
- `DockerAPIAdapter` maps platform values to Docker's canonical strings.

## 4. Compatibility policy

### 4.1 API version policy

For the initial milestones:

```text
minimumAPIVersion = 1.41
maximumAPIVersion = 1.41
```

Expected behavior:

- Unversioned handshake endpoints are accepted as required by the official client.
- API 1.41 requests are accepted.
- Versions lower than 1.41 return an accurate "client too old" response.
- Versions higher than 1.41 return an accurate "client too new" response.
- Versions are compared numerically by components, not as raw strings.

Do not lower the minimum until old-version route, request, response, and error conformance has been tested. Accepting an older path prefix while returning unversioned 1.41 shapes is not compatibility.

### 4.2 Field disposition policy

Every Compose-emitted field observed in a supported workflow is classified as one of:

| Disposition | Meaning |
| --- | --- |
| `supported` | Macker implements the required semantics and round-trip behavior. |
| `approximated` | Macker implements documented, intentionally different semantics that are safe for the stated use. |
| `rejected` | A non-default value fails with an actionable error. |
| `inert-default` | A harmless empty/default value sent by the official client may be accepted and ignored. |

Rules:

- Do not blanket-reject unknown JSON keys; official clients may send harmless forward-compatible defaults.
- Explicitly decode known correctness-, security-, isolation-, persistence-, and connectivity-sensitive fields and reject unsupported non-default values.
- An actionable error includes the field path, rejection reason, and a non-zero client exit status.
- Each rejected category has a negative route or Compose fixture test.
- No new silent no-op is allowed for a non-default setting that affects correctness, security, isolation, persistence, or connectivity.

### 4.3 Client support policy

- CI pins one Docker CLI version and one Compose plugin version as the blocking compatibility baseline.
- A non-blocking job tracks the latest supported upstream client to detect drift.
- A client version becomes supported only after the full milestone matrix passes.
- Updating the pinned client is a reviewed compatibility change, not an automatic dependency bump.
- Classic builder support is explicitly tied to a tested client version that still honors `DOCKER_BUILDKIT=0`.

### 4.4 Persistence and downgrade policy

- Compose compatibility milestones should avoid destructive store migrations.
- New persisted metadata must be additive and decode old records with safe defaults.
- Tests load at least one pre-change container/network/volume record when a persisted model changes.
- If a future milestone requires an irreversible migration, it needs a separate migration and downgrade decision before implementation.

## 5. Initial capability matrix

This matrix defines ownership and planned delivery. It must be updated by each milestone before merge.

| Compose capability | Owner/resolution | Macker API/runtime dependency | Initial disposition | Milestone |
| --- | --- | --- | --- | --- |
| YAML parsing, interpolation, profiles | Compose client | None | Client-owned | C0 |
| `environment`, `env_file` | Compose resolves; API carries `Config.Env` | Create/inspect round-trip | Supported | C2 |
| `command`, `entrypoint`, working dir, user | Compose + image config | Create/inspect/image inspect | Supported | C2 |
| Project/service/config-hash labels | Compose creates values | Opaque persistence and filters | Supported | C2 |
| Stop signal and timeout | Compose request | Correct Config wire location and runtime stop | Supported | C2/C3 |
| Detached single-service lifecycle | Compose orchestrates | Create/start/list/logs/exec/stop/remove | Supported | C3 |
| Custom bridge network and aliases | Compose orchestrates | Network create/connect/inspect + DNS | Supported | C4 |
| Published ports | Compose request | Port publisher | Supported | C4 |
| Named volumes | Compose orchestrates | Idempotent create/inspect/mount/remove | Supported | C5 |
| Bind mounts | Compose resolves host path | Mount translation and virtiofs semantics | Supported within documented scope | C5 |
| Health check | Compose request + engine state | Health loop and inspect state | Supported | C5 |
| `depends_on: service_healthy` | Compose orchestrates | Accurate health inspect | Supported | C5 |
| Restart policy and daemon restart | Compose config + engine | Persisted policy and state transition | Supported within documented Macker semantics | C5 |
| Docker context setup | Macker CLI | Official Docker CLI | Supported | C6 |
| Attached `up`, log follow, TTY, signals | Compose client | Streams and HTTP hijack | Deferred | C7 |
| `compose run` and one-off containers | Compose client | Wait, attach, auto-remove | Deferred | C7 |
| `/events` project isolation | Compose client | Label filters and event attributes | Deferred | C7 |
| Classic Compose build | Compose client | Classic `/build` only | Experimental | C8 |
| BuildKit/buildx/Bake | External future project | `/session` and BuildKit backend | Rejected | Future |
| Scale | Compose client | Multiple MicroVMs and port rules | Deferred | Future |
| Static IPv4 | Compose request | IPAM and network attachment | Deferred | Future |
| tmpfs | Compose request | Current host-directory approximation | Deferred pending explicit semantics | Future |
| External networks/volumes | Compose client | Inspect and ownership-safe teardown | Deferred | Future |
| IPv6, overlay, macvlan, ipvlan | Runtime | Unsupported dataplanes | Rejected | Future |
| GPU, devices, namespaces, cgroups, capabilities | Runtime | Unsupported or partial isolation controls | Rejected unless separately implemented | Future |

## 6. Iteration principles

Compose support is delivered as vertical user flows, not layer-by-layer rewrites.

Each milestone must:

1. Add one primary source of uncertainty at a time.
2. Produce one observable user workflow.
3. Add one focused fixture or contract corpus for that workflow.
4. Keep all previous milestone fixtures green.
5. Update the capability matrix and limitations.
6. Avoid unrelated refactors and future-milestone fields.
7. Avoid destructive store migrations.
8. Define an explicit rollback path.

Examples:

- Test API behavior without starting a VM.
- Test one VM before testing a multi-service network.
- Test networking before adding persistence and health dependencies.
- Test detached mode before attached streams.
- Test context setup without changing engine behavior.
- Test classic build without mixing runtime compatibility fixes.

The milestones are compatibility slices and need not dictate the repository's public semantic version numbers. A product release should contain at most one material Compose milestone until the integration is stable.

Recommended implementation branches after this plan is approved and merged:

```text
feat/compose-c0-harness
feat/compose-c1-readonly
feat/compose-c2-create
feat/compose-c3-single-service
feat/compose-c4-networking
feat/compose-c5-stateful
feat/compose-c6-context
feat/compose-c7-interactive
feat/compose-c8-classic-build
```

Each branch starts from the main branch after the previous milestone has merged. Avoid a long-lived stack of implementation branches.

## 7. Milestone C0: Reproducible toolchain and harness

### Goal

Create a green, repeatable compatibility harness without changing Macker container behavior or claiming Compose support.

### Scope

- Add a checked-in toolchain manifest containing:
  - Docker CLI version
  - Compose plugin version
  - darwin/arm64 artifact URLs
  - SHA-256 checksums
  - invocation mode
  - license/provenance references
- Add deterministic download/cache helpers.
- Print and assert both client versions in test output.
- Add Compose fixture validation with `docker compose config` as a client-only sanity check.
- Add short socket creation under `/tmp` to stay below macOS `sockaddr_un` limits.
- Reuse PID liveness, readiness timeout, and trap cleanup patterns from the existing smoke script.
- Add initial support-matrix documentation.

### Explicit non-goals

- No Docker API compatibility fixes.
- No container creation.
- No MicroVM startup.
- No user context or home-directory changes.

### Acceptance

- Tool artifacts are verified by checksum.
- The pinned Docker CLI and Compose plugin report the expected exact versions.
- All fixture files pass `docker compose config`.
- Harness startup and cleanup can be run repeatedly without leaving processes, sockets, stores, contexts, routes, networks, or volumes.
- Existing `make test` remains green.

### Rollback

Remove the toolchain manifest, helper, fixtures, and Make target; no product or store state changes exist.

## 8. Milestone C1: Handshake and read-only compatibility

### User workflow

```bash
docker --host unix:///tmp/macker-test.sock version
docker --host unix:///tmp/macker-test.sock info
DOCKER_HOST=unix:///tmp/macker-test.sock docker compose ls
docker --host unix:///tmp/macker-test.sock compose -f basic/compose.yaml ps
```

The project is empty; no images, networks, volumes, containers, or VMs are created.

### Scope

- Implement `DockerAPIVersionPolicy` with min=max=1.41 and numeric comparison.
- Define `RuntimePlatform` separately from host diagnostics.
- Correct runtime-facing `/version` and `/info` platform fields.
- Verify `/_ping`, `/version`, `/info`, and empty container list response shapes.
- Create a `DockerAPIAdapterTests` target for new adapter contracts; do not bulk-move existing tests in this milestone.
- Run the pinned official client against an isolated daemon and store.

### Acceptance

- Every command above exits 0 within a defined timeout.
- `/version` advertises API 1.41 and runtime `linux/arm64`.
- API 1.40 receives "client too old"; API 1.42 receives "client too new".
- Empty `compose ls` and `compose ps` return valid empty results.
- No runtime assets are downloaded and no helper is contacted.

### Rollback

Revert adapter policy/platform changes; no persisted format changes are allowed.

## 9. Milestone C2: Control-plane create and teardown

### User workflow

```bash
docker compose create
docker compose ps
docker compose down
```

No container is started and no MicroVM is booted.

### Scope

- Preload a deterministic local test image without registry access.
- Add the container-create DTO translator and field-disposition inventory.
- Preserve Compose labels exactly as opaque metadata.
- Implement and test the official create-to-inspect round-trip for:
  - `Cmd` and `Entrypoint` as distinct values
  - working directory and user
  - environment
  - TTY, open stdin, `StdinOnce`, and attach flags
  - stop signal and stop timeout in their official Config wire locations
  - image reference and image ID
- Expand ImageInspect contracts according to the pinned client's observed use, including platform, labels, and required Config metadata.
- Create and remove the default project network.
- Add negative tests for known security-, isolation-, persistence-, and connectivity-sensitive unsupported fields.
- Ensure list and inspect filters support Compose project labels.

### Explicit non-goals

- No start endpoint in the official-client fixture.
- No MicroVM.
- No custom network, port publishing, volume, health dependency, attached mode, or build.

### Acceptance

- `compose create`, `ps`, and `down` exit 0.
- Container, network, and image inspect assertions match the pinned client contract.
- `down` removes only resources owned by the fixture project.
- A second project with different labels is not discovered or removed.
- Every unsupported sensitive non-default fixture exits non-zero and names the rejected field path.
- No VM, helper, route, or external registry is used.

### Rollback

Revert adapter translation changes. Any persisted model field added in this milestone must be optional and backward-decodable.

## 10. Milestone C3: Detached single-service lifecycle

### User workflow

```bash
docker compose up -d
docker compose ps
docker compose logs --no-follow app
docker compose exec app <non-interactive-command>
docker compose down
```

### Fixture

One pinned arm64 Alpine image runs a long-lived non-interactive process. The image reference is pinned by digest.

### Scope

- Start and stop one MicroVM through Compose.
- Validate detached lifecycle, non-follow logs, non-TTY exec, and teardown.
- Add the host-route control seam and run Compose CI with it disabled.
- Stage pinned kernel/initfs assets into the isolated store.
- Define exact timeouts and expected container state transitions.

### Explicit non-goals

- No attached `up`, TTY, log follow, `compose run`, custom network, published port, Volume, health dependency, scale, or build.

### Acceptance

- Every command exits with its specified code before its timeout.
- `compose ps --format json` reports one running service with the expected labels and image.
- The exec command returns expected output and exit code.
- `compose down` leaves no project container or project network.
- The helper is not contacted and host routes are unchanged.
- Existing non-Compose MicroVM smoke remains green.

### Release status

This milestone may be labeled **Compose Single-Service Preview**, not general Compose support.

## 11. Milestone C4: Multi-service networking and ports

### User workflow

A two-service project starts, resolves service names, communicates over a user-defined bridge, and exposes one port to the Mac.

### Fixture

- Pinned `nginx:alpine` image
- Pinned Alpine client image
- User-defined bridge network
- Service alias
- One published localhost port

### Scope

- Network create, inspect, connect, disconnect, and remove behavior used by API 1.41 Compose.
- Primary network at create plus post-create `NetworkConnect` for additional networks.
- Service-name and alias DNS.
- Container-to-container traffic.
- Published-port traffic from the Mac.
- Project network labels and cross-project isolation.

### Acceptance

- Both services reach running state before the timeout.
- The client resolves the service name and alias and receives the expected nginx response.
- The Mac receives the expected response through the published port.
- Network inspect contains both endpoints and Compose labels.
- `down` removes only the fixture project's containers and network.
- A concurrently created second project remains intact.

### Release status

This milestone may expand the preview to **Image-Based Compose Networking Preview**.

## 12. Milestone C5: Stateful lifecycle, health, and daemon restart

### User workflow

A multi-service project uses a named volume and health dependency, survives daemon process restart according to documented Macker semantics, and can be reconciled and removed by Compose afterward.

### Scope

- Named volume create/inspect/mount/remove.
- Idempotent Docker VolumeCreate semantics for an existing compatible volume.
- Bind mounts within documented virtiofs scope.
- Health-check create and inspect round-trip.
- `depends_on: condition: service_healthy` through accurate health state.
- Restart policy persistence.
- Same-store daemon restart and Compose rediscovery.
- Explicit documentation that MicroVMs do not live through daemon restart.
- Container, network, volume, and label persistence.

### Required command/assertion sequence

1. `compose up -d` exits 0.
2. `compose ps --format json` reports the expected running/healthy states.
3. A marker is written into the named volume.
4. The daemon stops gracefully.
5. Container state transitions match documented Macker shutdown semantics.
6. The daemon restarts with the same store.
7. `compose ps` rediscovers project resources.
8. `compose up -d` correctly starts or reconciles the project.
9. The marker remains readable.
10. `compose down -v` removes project containers, networks, and non-external project volumes.

Every step has a defined exit code, resource-state assertion, and timeout.

### Explicit non-goals

- External networks and volumes.
- Attached mode, `compose run`, scale, static IPv4, tmpfs, and build.

### Release status

Passing C0–C5 qualifies for **Image-Based Compose Beta**. It does not imply interactive or build support.

## 13. Milestone C6: Docker context setup and doctor UX

### User workflow

```bash
macker setup
docker --context macker compose up -d
macker doctor
```

### Context state machine

| Existing state | Default action |
| --- | --- |
| Context absent | Create it with the absolute Macker socket endpoint. |
| Context exists and endpoint matches | Idempotent success. |
| Context exists and endpoint differs | Fail without modification and explain the conflict. |
| Explicit force/update option | Update only after explicit user authorization. |

### Rules

- Setup never changes the active context implicitly.
- Setup never modifies Docker Desktop or Podman contexts.
- New setup does not add `alias docker="macker"`.
- Existing aliases are detected; setup prints exact migration instructions but does not remove them without an explicit option.
- `/var/run/docker.sock` compatibility is opt-in.
- Context removal is explicit and only removes a context whose endpoint is confirmed to match Macker.
- Partial setup failures do not leave unrelated shell, context, or socket changes.
- Setup and Doctor share toolchain/context probing.

### Testing

- Use a temporary `DOCKER_CONFIG` and temporary home.
- Inject process execution, filesystem/environment, and output.
- Test absent, matching, foreign conflict, explicit update, and explicit removal states.
- Assert the current context and unrelated contexts are unchanged.
- Test Docker CLI missing and Compose plugin missing diagnostics.

### Acceptance

- Setup is idempotent.
- Every conflict or missing dependency has an actionable message.
- Doctor reports Docker CLI, Compose plugin, context endpoint, socket reachability, API negotiation, runtime assets, and classic-builder availability separately.
- No test touches the real user Docker config or shell startup files.

### Release status

Passing C0–C6 qualifies for a user-installable **Image-Based Compose Beta** workflow.

## 14. Milestone C7: Interactive sessions, one-off containers, and events

### User workflows

```bash
docker compose up
docker compose logs --follow
docker compose exec -it app sh
docker compose run --rm app <command>
docker compose events
```

### Scope

- Concurrent attached streams for multiple services.
- Docker stdout/stderr multiplexing.
- HTTP hijack and WebSocket behavior used by the pinned client.
- TTY resize and terminal restoration.
- Signal forwarding and detach behavior.
- Client disconnect and `compose down` stream cleanup.
- Wait conditions required by `compose run` and auto-remove behavior.
- Wait response error shape.
- `/events` `label` and `label!` filters.
- Compose labels in event `Actor.Attributes`.
- Two-project event isolation.
- `since`, `until`, and event-stream close behavior.

### Test ownership

- Adapter tests validate event filtering and wait response shapes.
- Socket/transport tests validate streams, hijack, cancellation, and concurrent close.
- Runtime E2E validates terminal, signal, one-off, and auto-remove behavior.

### Acceptance

- Attached sessions show correctly prefixed service output.
- Signals reach the intended process/container and return expected exit codes.
- TTY state is restored after exit, detach, and failure.
- `compose run --rm` leaves no one-off container.
- Event filters never deliver another project's events.
- All long-lived connections close within a defined timeout during `compose down`.

### Release status

Interactive support is advertised separately from the image-based detached Beta until C7 passes.

## 15. Milestone C8: Classic Compose build preview

### Preconditions

The pinned Docker CLI and Compose plugin must demonstrably honor:

```bash
DOCKER_BUILDKIT=0 docker --context macker compose build
```

and call classic `POST /build` rather than `/session`, buildx, or Bake.

If the pinned official client no longer provides that path, C8 is cancelled or replaced by a separate BuildKit project. It must not block image-based Compose support.

### Scope

- Single-stage local build.
- Multi-stage local build.
- Compose-generated image tags.
- Build args, target, labels, pull, and no-cache within Macker's classic-builder scope.
- Explicit rejection of BuildKit-only fields and requests.

### Acceptance

- The pinned client uses classic `/build` in a captured request trace.
- Single- and multi-stage fixture images build and run successfully.
- Unsupported BuildKit settings fail with the existing actionable guidance.
- Build support documentation names the exact tested client versions and limitations.

### Release status

Advertise as **Classic Compose Build Preview**, never as BuildKit support.

## 16. Deferred compatibility slices

Deliver each of these as a separate future milestone with its own fixture and contract:

- Scale without fixed-port collisions
- Static IPv4
- Explicit tmpfs approximation semantics
- External network ownership and teardown
- External volume ownership and teardown
- Advanced resource limits
- Additional Compose commands
- BuildKit/buildx/Bake

Do not group them into a generic "complete Compose compatibility" release.

## 17. Test architecture

### 17.1 Test layers

| Layer | Ownership | Coverage |
| --- | --- | --- |
| `DockerAPIAdapterTests` | Docker adapter | DTOs, translation, API versions, response shapes, filters, errors, field dispositions |
| `ContainerEngineTests` | Runtime domain | Lifecycle, persistence, mounts, networking, health, restart semantics |
| Socket/transport tests | NIO transport | Chunked streams, HTTP hijack, cancellation, concurrent close, body spooling |
| CLI/setup tests | `CliCore` | Toolchain probe, context state machine, dry run, rollback, alias diagnostics |
| Compose contract tests | Official client + isolated daemon | Real client negotiation and project reconciliation without VM where possible |
| Compose runtime smoke | Official client + signed daemon | Real MicroVM, DNS, ports, volumes, health, restart, streams |
| Privileged helper smoke | Serialized explicit job | utun and host-route behavior only |

Existing mixed tests do not need a bulk migration. New tests follow these ownership boundaries; existing tests move only when directly touched and doing so reduces confusion without expanding the milestone.

### 17.2 CI jobs

1. **Unit:** blocking `make test`, no official client download required unless cached.
2. **Compose contract:** blocking after C1, pinned client, isolated short socket/store, no VM or helper.
3. **Compose runtime:** blocking for milestones that claim runtime support; Apple Silicon macOS 26, signed daemon, pinned runtime assets.
4. **Latest client:** non-blocking drift detector.
5. **Privileged helper:** serialized and explicit; not part of ordinary pull-request CI unless the environment is dedicated.

### 17.3 Reproducibility requirements

- Pin image references by arm64 digest in runtime fixtures.
- Cache client tools and runtime assets by checksum.
- Verify checksums before execution.
- Record Docker CLI, Compose plugin, Macker, containerization, kernel, and initfs versions in output.
- Define registry retry, cache, and timeout behavior.
- Never depend on Docker Desktop being installed or running.
- Use a short `/tmp` socket independent of the store path.
- Always verify daemon PID liveness while waiting for readiness.
- Always trap cleanup for daemon, socket, store, containers, networks, volumes, and any explicitly enabled host-network state.

## 18. Fixture catalog

| Fixture | First used | Purpose |
| --- | --- | --- |
| `basic-config` | C0 | Compose syntax and client toolchain sanity only |
| `empty-project` | C1 | Handshake and empty list behavior |
| `create-only` | C2 | Deterministic local image, DTO translation, labels, inspect, teardown |
| `rejected-fields` | C2 | Negative fixtures for unsupported sensitive settings |
| `single-service` | C3 | Detached one-VM lifecycle, non-follow logs, non-TTY exec |
| `networked` | C4 | Two services, bridge DNS/alias, published port, project isolation |
| `stateful` | C5 | Named volume, bind mount, health dependency, restart and same-store restore |
| `interactive` | C7 | Attached output, TTY, signals, wait, auto-remove, events |
| `build-classic` | C8 | Single- and multi-stage classic build |

Every fixture has a command/assertion table containing:

- command
- expected exit code
- maximum duration
- expected JSON/inspect fields
- expected container/network/volume state
- expected host-visible output
- teardown assertions

## 19. Per-milestone merge checklist

A milestone may merge only when:

1. Its user workflow and explicit non-goals are documented.
2. Its adapter contract tests pass.
3. Its official-client fixture passes at the highest required test layer.
4. All earlier milestone fixtures remain green.
5. The capability matrix is updated.
6. Unsupported sensitive fields introduced by the workflow are classified and tested.
7. No unrelated product or architecture refactor is included.
8. No real user context, shell file, Docker config, socket, helper, or host route is changed by tests.
9. Persisted changes are additive and backward-decodable.
10. Rollback is documented and does not require destructive store repair.
11. Validation output records exact client and runtime versions.
12. Documentation distinguishes supported, approximated, rejected, client-owned, and deferred behavior.

## 20. Expected change areas by milestone

| Milestone | Likely areas |
| --- | --- |
| C0 | toolchain manifest, `scripts/`, `Makefile`, Compose fixtures, CI workflow |
| C1 | `DockerAPI.swift`, `DockerSystem.swift`, `Router.swift`, new adapter tests |
| C2 | container/image DTOs, container translator/routes, label/filter tests, create fixtures |
| C3 | runtime lifecycle tests, host-route control seam, smoke script, CI runtime provisioning |
| C4 | network DTO/routes/engine behavior, DNS/port fixtures |
| C5 | volume/health/restart/persistence behavior and fixtures |
| C6 | `Setup.swift`, `Doctor.swift`, shared toolchain/context probe, CLI tests |
| C7 | system events, wait, logs, attach/exec routes, NIO transport tests, interactive fixture |
| C8 | build route/backend tests, classic build fixture and documentation |

Likely repository files include:

- `Package.swift`
- `.github/workflows/test.yml`
- `Sources/Cli/Setup.swift`
- `Sources/Cli/Doctor.swift`
- `Sources/DockerAPIAdapter/Models/`
- `Sources/DockerAPIAdapter/Routes/`
- `Sources/DockerAPIAdapter/Server/`
- focused files under `Sources/ContainerEngine/`
- `Tests/DockerAPIAdapterTests/`
- `Tests/ContainerEngineTests/`
- `Tests/CliTests/`
- `Tests/Fixtures/Compose/`
- `scripts/compose-*.sh`
- `Makefile`
- `README.md`
- `docs/cli.md`

No Compose parser or project orchestrator should be added to `ContainerEngine`.

## 21. Release gates

### Single-Service Preview

Requires C0–C3.

### Image-Based Networking Preview

Requires C0–C4.

### Image-Based Compose Beta

Requires C0–C5.

### User-installable Image-Based Compose Beta

Requires C0–C6.

### Interactive Compose support

Requires C7 and is advertised separately until complete.

### Classic Compose Build Preview

Requires C8 and remains separate from runtime support.

No release should use an unqualified "Docker Compose compatible" claim. Release notes must name the supported profile, commands, fields, client versions, and known approximations.
