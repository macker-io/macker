# Experimental K3s on Macker

K3s is an opt-in CLI experiment, not a supported release feature. A single-node `linux/arm64` probe on Apple Silicon reaches `Ready`, and a client Pod can fetch an HTTP response from another Pod via its Pod IP, ClusterIP, and Service DNS name. The probe stops and starts the MicroVM, checks that the Service UID is unchanged, and repeats the traffic checks. It runs in an isolated daemon store without modifying the installed runtime. The API is published on an automatically assigned `127.0.0.1` port. The probe checks the actual listener and verifies `/readyz` from the host before and after restart using TLS and a private kubeconfig. It never modifies `~/.kube/config`.

## Reproduce

```sh
make cli
# Use a Docker context backed by a native ARM64 Linux builder with bind mounts.
DOCKER_CONTEXT=orbstack scripts/build-k3s-probe-kernel.sh
MACKER_KERNEL="$PWD/.build/k3s-probe/vmlinux" scripts/smoke-k3s.sh
```

The build script takes the configuration embedded in the packaged Kata 3.17.0 kernel and builds upstream Linux 6.12.28 with `BRIDGE_NETFILTER` and the legacy `physdev` match built in. It verifies the kernel source checksum and writes only to the chosen output directory. The daemon pulls the official `rancher/k3s:v1.34.3-k3s1` image on first start. The smoke script requires host `kubectl`, `lsof`, and `timeout`; it drives the lifecycle through the Macker CLI without Docker.

## What the probe established

- The bundled Kata kernel has legacy IPv4 iptables NAT, but no `NF_TABLES`, `BRIDGE_NETFILTER`, `VXLAN`, or loadable modules. The default K3s iptables selection fails at kube-proxy startup. Selecting the image's legacy tools and Flannel `host-gw` lets the stock kernel reach `Ready` and pass direct Pod-to-Pod traffic, but ClusterIP still times out. With the two built-in bridge options added, ClusterIP and Service DNS both pass.
- Image-declared virtiofs volumes cannot host the Kine Unix socket or kubelet's root (cAdvisor expects a block device). The managed node skips those volumes and attaches a dedicated 16 GiB ext4 disk at `/k3s-state`, with separate server/containerd and kubelet directories. Containerd uses overlayfs.
- This is an IPv4, single-node networking probe. NetworkPolicy, Traefik, and ServiceLB are disabled. The probe doesn't establish support for those features or persistent volumes.

## CLI experiment

Start a **separate** daemon with `MACKER_EXPERIMENTAL_K3S=1` and `MACKER_KERNEL` pointing to the experimental kernel. `MACKER_KERNEL` applies to all MicroVMs in that daemon, so use a separate store. Target its socket explicitly:

```sh
macker -H unix:///path/to/test/macker.sock k3s start
macker -H unix:///path/to/test/macker.sock k3s kubeconfig ./macker-k3s.yaml
kubectl --kubeconfig ./macker-k3s.yaml get nodes
macker -H unix:///path/to/test/macker.sock k3s stop
```

`start` prints the loopback endpoint after MicroVM startup, not Kubernetes readiness. Retry `kubeconfig` if K3s is still starting. It writes an admin credential file with mode `0600` and never overwrites an existing file; use a new path to refresh it after restart. `stop` retains cluster state in `k3s/state.ext4` under the daemon store.

## Next milestone

Package a per-VM K3s kernel so existing containers can keep using the default runtime. Add status and explicit cluster reset, then verify importing a Macker-built image into K3s's separate containerd store.
