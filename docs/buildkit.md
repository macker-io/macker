# BuildKit

The official `docker build`, `docker buildx build` and `docker compose build` / `up --build` work against Macker with no environment overrides and leave the image in Macker's image store, the same as against Docker Engine.

## How it works

```text
docker build ──buildx "docker" driver──► mackerd  POST /grpc     (h2c)  ─┐
                                          mackerd  POST /session  (h2c)  ─┤ relay
                                                                          ▼
                     hidden MicroVM "macker-buildkit": moby/buildkit:buildx-stable-1 (buildkitd)
                                                                          │ image exporter
                                                                          ▼
                                       mackerd imports the result into its image store
```

1. **Driver selection.** buildx probes `POST /grpc`. Because Macker answers it, buildx picks its `docker` driver (as with Docker Engine), so `docker build -t x .` loads the result without `--load`. `/_ping` reports `Builder-Version: 2`.
2. **Builder VM.** On the first BuildKit call the daemon pulls `moby/buildkit:buildx-stable-1` and boots it as a hidden system container (`--privileged` inside its own MicroVM, `--init`). It is not listed by `docker ps`, does not emit events, and does not use a Docker volume. Its state (`/var/lib/buildkit`) lives on an ext4 disk image at `<store>/buildkit/state.ext4` (sparse, 64 GiB) because BuildKit's overlayfs snapshotter cannot use a virtiofs share. The VM is stopped with the daemon and booted again on the next build; the cache survives.
3. **Relay.** Each `/grpc` or `/session` connection gets its own `buildctl dial-stdio` stream into the builder. `/grpc` is relayed per HTTP/2 stream; `/session` is carried inside BuildKit's `Control/Session` stream (`BytesMessage` frames), which is what standalone `buildkitd` expects. Reads are paced by writes on both legs.
4. **Export.** Docker's daemon has a private `moby` exporter. The relay rewrites it to BuildKit's standard `image` exporter. When the `Solve` call succeeds, the daemon copies the exported index, manifests, configs and layers out of the builder's content store, registers them under the requested names, and only then forwards the response, so the image exists when `docker build` returns. The reported image ID is the local one.

## What works

- Dockerfile frontend features: `# syntax=`, heredocs, `RUN --mount=type=cache|bind|tmpfs|secret|ssh`, multi-stage, `--target`, `--build-arg`, `--secret`, `--ssh`, `-q`, `--iidfile`, build contexts.
- `-o type=oci|docker|local,dest=…` (written by the client through the session) and `--push`.
- `docker compose build` and `up --build` (bake and non-bake).
- `docker buildx du` / `prune`, `docker builder prune` against the builder cache.
- The classic builder is still used for `DOCKER_BUILDKIT=0 docker build` and for `macker build`.

## Limits

- The default worker advertises `linux/arm64`. Some BuildKit images can emulate AMD64 during a build; this does not imply Macker can run the resulting AMD64 container. A multi-platform index can be imported with the default `docker` driver and `-t`, or exported with `-o type=oci`. Explicit multi-platform `--load` is rejected by Buildx's Docker exporter on this API version; omit it to use the default import path.
- Local import keeps available provenance/SBOM manifests. If BuildKit reports an attestation but its blob is no longer available, Macker omits that attestation and reports the resulting local index digest and descriptor. Missing image layers or configs still fail the build.
- A fresh store may need to download the builder image and boot a MicroVM, which can exceed Buildx's default 20-second inspection timeout. Use `docker buildx inspect default --bootstrap --timeout 120s` on first use. Concurrent requests share the same readiness probe.
- Run `COMPAT_STORE="$(mktemp -d /tmp/macker-bx.XXXXXX)" scripts/compat/run.sh buildx` for the official-client smoke suite after signing the daemon (`make app`) and staging runtime assets (`make fetch-runtime`). The **Buildx Smoke** workflow can run this suite on a trusted Apple Silicon runner labeled `macker-vm`.
- `FROM` resolves through the registry, not Macker's local store: an image that only exists locally (built with the classic builder, or loaded) cannot be used as a base by a BuildKit build. Push it, or build the base with BuildKit too.
- Builders created with `docker buildx create --driver docker-container` start, but their state volume is a virtiofs share, on which BuildKit's overlayfs snapshots mount read-only, so builds fail with `read-only file system`. Use the default builder.
