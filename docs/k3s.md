# Experimental K3s on Macker

K3s is an opt-in CLI experiment, not a supported release feature. A single-node `linux/arm64` probe on Apple Silicon reaches `Ready`, and a client Pod can fetch an HTTP response from another Pod via its Pod IP, ClusterIP, and Service DNS name. The probe stops and starts the MicroVM, checks that the Service UID is unchanged, reads a previously written marker from a `local-path` PVC, and repeats the traffic checks. It runs in an isolated daemon store without modifying the installed runtime. The API is published on an automatically assigned `127.0.0.1` port. The probe checks the actual listener and verifies `/readyz` from the host before and after restart using TLS and a private kubeconfig. It never modifies `~/.kube/config`.

## Reproduce

```sh
make cli
# Use a Docker context backed by a native ARM64 Linux builder with bind mounts.
DOCKER_CONTEXT=orbstack scripts/build-k3s-probe-kernel.sh
MACKER_K3S_KERNEL="$PWD/.build/k3s-probe/vmlinux" scripts/smoke-k3s.sh
```

The build script takes the configuration embedded in the packaged Kata 3.17.0 kernel and builds upstream Linux 6.12.28 with `BRIDGE_NETFILTER` and the legacy `physdev` match built in. It verifies the kernel source checksum and writes only to the chosen output directory. The daemon pulls the official `rancher/k3s:v1.34.3-k3s1` image on first start. The smoke script requires host `kubectl`, `lsof`, and `timeout`; it drives the lifecycle through the Macker CLI without Docker and compares the running K3s and ordinary container kernel versions on the same daemon.

## What the probe established

- The bundled Kata kernel has legacy IPv4 iptables NAT, but no `NF_TABLES`, `BRIDGE_NETFILTER`, `VXLAN`, or loadable modules. The default K3s iptables selection fails at kube-proxy startup. Selecting the image's legacy tools and Flannel `host-gw` lets the stock kernel reach `Ready` and pass direct Pod-to-Pod traffic, but ClusterIP still times out. With the two built-in bridge options added, ClusterIP and Service DNS both pass.
- Image-declared virtiofs volumes cannot host the Kine Unix socket or kubelet's root (cAdvisor expects a block device). The managed node skips those volumes and attaches a dedicated 16 GiB ext4 disk at `/k3s-state`, with separate server/containerd and kubelet directories. Containerd uses overlayfs.
- This is an IPv4, single-node networking probe. NetworkPolicy, Traefik, and ServiceLB are disabled. The PVC check covers the bundled `local-path` provisioner only; it does not establish support for other storage backends.

## CLI experiment

Start the daemon with `MACKER_EXPERIMENTAL_K3S=1`. The tagged macOS CLI release workflow builds and bundles the K3s kernel at `share/macker/runtime/vmlinux-k3s`, so release users do not need to compile it. Local `make cli` / `make dist` builds omit it unless you set `MACKER_K3S_KERNEL=/absolute/path/to/vmlinux` at build time. You can also set that variable on the daemon to use an existing kernel without repackaging. A configured override takes precedence and must point to a readable kernel file. K3s never falls back to the default kernel, and ordinary containers and BuildKit continue using the normal runtime. To try it with an isolated daemon, target its socket explicitly:

```sh
macker -H unix:///path/to/test/macker.sock k3s start --wait
macker -H unix:///path/to/test/macker.sock k3s status
macker -H unix:///path/to/test/macker.sock k3s kubeconfig ./macker-k3s.yaml
kubectl --kubeconfig ./macker-k3s.yaml get nodes
macker -H unix:///path/to/test/macker.sock k3s stop
```

`start` alone reports MicroVM startup. `start --wait` checks both the Kubernetes API and node readiness; a readiness timeout does not stop the VM. `status` reports the current state and loopback endpoint if running. `kubeconfig` writes an admin credential file with mode `0600` and never overwrites an existing file; use a new path to refresh it after restart.

`stop` retains cluster state in `k3s/state.ext4` under the daemon store. To permanently remove the stopped cluster, run `macker k3s reset --confirm` against the same daemon. This deletes cluster objects, PVC data on the cluster disk and K3s's image cache, but does not delete Macker images or host-side kubeconfig files.

## Use local build images

Pass `--k3s` when building with the native Macker CLI to sync the build's tagged image to the running K3s node:

```sh
macker build --k3s -t demo:dev .
```

A Pod can use `image: demo:dev` and `imagePullPolicy: Never` without a registry. The command returns success only after the sync finishes. If sync fails, the build remains available in Macker's local store. After fixing the cluster, run `macker k3s image sync demo:dev` to retry without rebuilding. The same command works for tags produced by Compose or Buildx, as long as the image was loaded into the same Macker daemon's image store. Rebuild with the same tag and recreate the Pod to use the new image. Running Pods are not restarted by sync.

This is opt-in per invocation for the native classic builder; ordinary builds, Compose, and Buildx are unchanged. There is no global registry interception or pull policy override. K3s keeps its own copy of the synced image.

## Release artifacts

The macOS release workflow builds the kernel on a native ARM64 Linux runner and checks that the macOS CLI archive contains the exact kernel it produced. The matching Linux source, Kata base configuration, final K3s configuration, and build script are published separately as `k3s-kernel-source.tar`, with a checksum in `SHA256SUMS`.
