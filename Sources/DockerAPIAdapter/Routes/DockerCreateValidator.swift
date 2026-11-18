import ContainerEngine
import Foundation

/// Rejects `POST /containers/create` settings Macker cannot honor.
///
/// Each container is its own MicroVM: there is no shared host kernel to join namespaces of,
/// no host devices to pass through, and no per-container cgroup/LSM knobs. (`Privileged`,
/// `CapAdd` and `CapDrop` are honored inside the guest kernel and are not listed here.) Settings in that
/// space would otherwise be silently ignored, which changes security, isolation, or
/// behavior without telling the user. Empty/default values (which the official clients
/// always send) pass.
enum DockerCreateValidator {
    struct Rejection: Error, Equatable {
        let message: String
    }

    static func validate(_ body: DockerCreateContainerRequest) throws {
        var problems: [String] = []
        func reject(_ field: String, _ flag: String, _ why: String) {
            problems.append("\(field) (\(flag)) is not supported: \(why)")
        }

        if body.NetworkDisabled == true {
            reject("NetworkDisabled", "--network-disabled", "use --network none")
        }

        if let host = body.HostConfig {
            let vm = "each container is a separate MicroVM"
            if let mode = host.PidMode, !mode.isEmpty {
                reject("HostConfig.PidMode", "--pid", "\(vm); there is no host or peer PID namespace to join")
            }
            if let mode = host.IpcMode, !["", "private", "shareable"].contains(mode) {
                reject("HostConfig.IpcMode", "--ipc", "\(vm); only private IPC is available")
            }
            if let mode = host.UTSMode, !mode.isEmpty {
                reject("HostConfig.UTSMode", "--uts", "\(vm); there is no host UTS namespace")
            }
            if let mode = host.UsernsMode, !mode.isEmpty {
                reject("HostConfig.UsernsMode", "--userns", "user namespace remapping is not available")
            }
            if let mode = host.CgroupnsMode, !["", "private"].contains(mode) {
                reject("HostConfig.CgroupnsMode", "--cgroupns", "\(vm); only a private cgroup namespace exists")
            }
            if let value = host.Cgroup, !value.isEmpty {
                reject("HostConfig.Cgroup", "--cgroup", "\(vm)")
            }
            if let value = host.CgroupParent, !value.isEmpty {
                reject("HostConfig.CgroupParent", "--cgroup-parent", "\(vm)")
            }
            if !(host.Devices ?? []).isEmpty {
                reject("HostConfig.Devices", "--device", "host devices cannot be passed into a MicroVM")
            }
            if !(host.DeviceRequests ?? []).isEmpty {
                reject("HostConfig.DeviceRequests", "--gpus", "host devices cannot be passed into a MicroVM")
            }
            if !(host.DeviceCgroupRules ?? []).isEmpty {
                reject("HostConfig.DeviceCgroupRules", "--device-cgroup-rule", "host devices cannot be passed into a MicroVM")
            }
            if (host.SecurityOpt ?? []).contains(where: { !EngineContainerRunConfig.supportedSecurityOptions.contains($0) }) {
                reject("HostConfig.SecurityOpt", "--security-opt", "seccomp/AppArmor/SELinux profiles are not applied")
            }
            if host.MaskedPaths != nil || host.ReadonlyPaths != nil {
                reject("HostConfig.MaskedPaths/ReadonlyPaths", "--security-opt systempaths", "custom path masking is not applied")
            }
            if !(host.StorageOpt ?? [:]).isEmpty {
                reject("HostConfig.StorageOpt", "--storage-opt", "the root filesystem size is fixed")
            }
            if !(host.Annotations ?? [:]).isEmpty {
                reject("HostConfig.Annotations", "--annotation", "runtime annotations are not passed to the MicroVM")
            }
            if !(host.GroupAdd ?? []).isEmpty {
                reject("HostConfig.GroupAdd", "--group-add", "supplementary groups are not applied")
            }
            if !(host.Links ?? []).isEmpty {
                reject("HostConfig.Links", "--link", "use a user-defined network and --network-alias")
            }
            if let value = host.OomScoreAdj, value != 0 {
                reject("HostConfig.OomScoreAdj", "--oom-score-adj", "not applied")
            }
            if host.OomKillDisable == true {
                reject("HostConfig.OomKillDisable", "--oom-kill-disable", "not applied")
            }
            if let value = host.PidsLimit, value > 0 {
                reject("HostConfig.PidsLimit", "--pids-limit", "not applied")
            }
            if let value = host.ShmSize, value > 0 {
                reject("HostConfig.ShmSize", "--shm-size", "not applied")
            }
            let cpuKnobs: [(String, String, Int64?)] = [
                ("CpuShares", "--cpu-shares", host.CpuShares),
                ("CpuPeriod", "--cpu-period", host.CpuPeriod),
                ("CpuQuota", "--cpu-quota", host.CpuQuota),
                ("CpuRealtimePeriod", "--cpu-rt-period", host.CpuRealtimePeriod),
                ("CpuRealtimeRuntime", "--cpu-rt-runtime", host.CpuRealtimeRuntime),
                ("CpuCount", "--cpu-count", host.CpuCount),
                ("CpuPercent", "--cpu-percent", host.CpuPercent),
                ("IOMaximumIOps", "--io-maxiops", host.IOMaximumIOps),
                ("IOMaximumBandwidth", "--io-maxbandwidth", host.IOMaximumBandwidth),
                ("BlkioWeight", "--blkio-weight", host.BlkioWeight),
                ("MemoryReservation", "--memory-reservation", host.MemoryReservation),
            ]
            for (field, flag, value) in cpuKnobs where (value ?? 0) != 0 {
                reject("HostConfig.\(field)", flag, "only --memory and --cpus are applied")
            }
            if let value = host.CpusetCpus, !value.isEmpty {
                reject("HostConfig.CpusetCpus", "--cpuset-cpus", "only --memory and --cpus are applied")
            }
            if let value = host.CpusetMems, !value.isEmpty {
                reject("HostConfig.CpusetMems", "--cpuset-mems", "only --memory and --cpus are applied")
            }
            let blkioLists: [(String, String, [DockerCreateContainerRequest.EmptyObject]?)] = [
                ("BlkioWeightDevice", "--blkio-weight-device", host.BlkioWeightDevice),
                ("BlkioDeviceReadBps", "--device-read-bps", host.BlkioDeviceReadBps),
                ("BlkioDeviceWriteBps", "--device-write-bps", host.BlkioDeviceWriteBps),
                ("BlkioDeviceReadIOps", "--device-read-iops", host.BlkioDeviceReadIOps),
                ("BlkioDeviceWriteIOps", "--device-write-iops", host.BlkioDeviceWriteIOps),
            ]
            for (field, flag, value) in blkioLists where !(value ?? []).isEmpty {
                reject("HostConfig.\(field)", flag, "only --memory and --cpus are applied")
            }
            // 0 = default; -1 = unlimited swap; equal to Memory = no swap. The guest has no swap.
            if let swap = host.MemorySwap, swap != 0, swap != -1, swap != (host.Memory ?? 0) {
                reject("HostConfig.MemorySwap", "--memory-swap", "the MicroVM has no swap")
            }
            if let value = host.MemorySwappiness, value != -1 {
                reject("HostConfig.MemorySwappiness", "--memory-swappiness", "the MicroVM has no swap")
            }
            if let type = host.LogConfig?.Type, !["", "json-file"].contains(type) {
                reject("HostConfig.LogConfig.Type", "--log-driver", "only the json-file driver is available")
            }
            if !(host.LogConfig?.Config ?? [:]).isEmpty {
                reject("HostConfig.LogConfig.Config", "--log-opt", "log driver options are not applied")
            }
            if let runtime = host.Runtime, !["", "containerization"].contains(runtime) {
                reject("HostConfig.Runtime", "--runtime", "the only runtime is containerization")
            }
            if let isolation = host.Isolation, !["", "default"].contains(isolation) {
                reject("HostConfig.Isolation", "--isolation", "the only isolation is a MicroVM")
            }
            for mount in host.Mounts ?? [] {
                let type = (mount.`Type` ?? "volume").lowercased()
                if !["bind", "volume", "tmpfs"].contains(type) {
                    reject("HostConfig.Mounts[].Type", "--mount type=\(type)", "only bind, volume and tmpfs mounts exist")
                }
                if let driver = mount.VolumeOptions?.DriverConfig?.Name, !driver.isEmpty, driver != "local" {
                    reject("HostConfig.Mounts[].VolumeOptions.DriverConfig", "--mount volume-driver=\(driver)", "only the local volume driver exists")
                }
            }
        }

        if !problems.isEmpty {
            throw Rejection(message: problems.joined(separator: "; "))
        }
    }
}
