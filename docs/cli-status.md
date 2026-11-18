# CLI 后续工作

Docker 兼容命令和支持完成度见 [cli.md](cli.md)（英文）。

## 建议实现顺序

按「先修已有命令的缺口，再补日常缺的命令，最后做大件」。完成度表在 [cli.md](cli.md)。

| 顺序 | 项 | 为什么排这里 |
| --- | ------------------------------------------------ | ------------------------------ |
| 1 | SwiftTCP 用户态栈（已落地；出网/`-p` 仍走本机 socket） | 控制面保留；不碰本机路由 / `pf`；方案见 [userspace-stack.md](userspace-stack.md) |
| 2 | 吞吐优化（virtio 零拷贝接入、减少 Task hop） | 对照 gvisor-tap-vsock，协议改动在 SwiftTCP 库内 |
| 3 | `bridge` IPv6 双栈（已落地：IPAM、NDP NS/NA + RS/RA、AAAA DNS、SwiftTCP 出网、`utun` `-inet6`、`-p` IPv6 绑定） | `host` 模式 IPv6 与纯 IPv6（`--ipv4=false`）暂不支持 |
| 4 | `macvlan` / `ipvlan` / `--net=container:` | 需要额外权益，ad-hoc 签不了，放最后 |
