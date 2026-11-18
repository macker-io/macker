import Foundation
import NIOCore
import NIOEmbedded
import Testing
@testable import ContainerEngine
@testable import DockerAPIAdapter

/// Wire shapes the official `docker` CLI (29.x, API 1.44 negotiated) sends and expects.
struct RouterDockerCLIAPITests {
    /// `POST /containers/create` body captured from `docker run --rm -i alpine true`.
    static func officialCreateBody(image: String = "alpine:latest") -> [String: Any] {
        [
            "Hostname": "", "Domainname": "", "User": "",
            "AttachStdin": true, "AttachStdout": true, "AttachStderr": true,
            "Tty": false, "OpenStdin": true, "StdinOnce": true,
            "Env": NSNull(), "Cmd": ["true"], "Image": image, "Volumes": [String: Any](),
            "WorkingDir": "", "Entrypoint": NSNull(), "Labels": [String: Any](),
            "HostConfig": [
                "Binds": NSNull(), "ContainerIDFile": "", "LogConfig": ["Type": "", "Config": [String: Any]()],
                "NetworkMode": "default", "PortBindings": [String: Any](),
                "RestartPolicy": ["Name": "no", "MaximumRetryCount": 0], "AutoRemove": true,
                "VolumeDriver": "", "VolumesFrom": NSNull(), "ConsoleSize": [0, 0],
                "CapAdd": NSNull(), "CapDrop": NSNull(), "CgroupnsMode": "", "Dns": NSNull(),
                "DnsOptions": [String](), "DnsSearch": [String](), "ExtraHosts": NSNull(),
                "GroupAdd": NSNull(), "IpcMode": "", "Cgroup": "", "Links": NSNull(), "OomScoreAdj": 0,
                "PidMode": "", "Privileged": false, "PublishAllPorts": false, "ReadonlyRootfs": false,
                "SecurityOpt": NSNull(), "UTSMode": "", "UsernsMode": "", "ShmSize": 0, "Isolation": "",
                "CpuShares": 0, "Memory": 0, "NanoCpus": 0, "CgroupParent": "", "BlkioWeight": 0,
                "BlkioWeightDevice": [Any](), "BlkioDeviceReadBps": [Any](), "BlkioDeviceWriteBps": [Any](),
                "BlkioDeviceReadIOps": [Any](), "BlkioDeviceWriteIOps": [Any](), "CpuPeriod": 0,
                "CpuQuota": 0, "CpuRealtimePeriod": 0, "CpuRealtimeRuntime": 0, "CpusetCpus": "",
                "CpusetMems": "", "Devices": [Any](), "DeviceCgroupRules": NSNull(),
                "DeviceRequests": NSNull(), "MemoryReservation": 0, "MemorySwap": 0,
                "MemorySwappiness": -1, "OomKillDisable": false, "PidsLimit": 0, "Ulimits": NSNull(),
                "CpuCount": 0, "CpuPercent": 0, "IOMaximumIOps": 0, "IOMaximumBandwidth": 0,
                "MaskedPaths": NSNull(), "ReadonlyPaths": NSNull(),
            ] as [String: Any],
            "NetworkingConfig": [
                "EndpointsConfig": [
                    "default": [
                        "IPAMConfig": NSNull(), "Links": NSNull(), "Aliases": NSNull(), "DriverOpts": NSNull(),
                        "GwPriority": 0, "NetworkID": "", "EndpointID": "", "Gateway": "", "IPAddress": "",
                        "MacAddress": "", "IPPrefixLen": 0, "IPv6Gateway": "", "GlobalIPv6Address": "",
                        "GlobalIPv6PrefixLen": 0, "DNSNames": NSNull(),
                    ] as [String: Any],
                ],
            ],
        ]
    }

    @Test func versionPolicyAcceptsOlderAndUnversionedRejectsOutOfRange() async throws {
        try await withRouter { router, _ in
            for path in ["/_ping", "/v1.24/_ping", "/v1.41/_ping", "/v\(DockerAPI.version)/_ping"] {
                let ok = await router.handle(try RouterTestSupport.request("GET", path))
                #expect(ok.status == 200, "\(path)")
            }
            let newer = await router.handle(try RouterTestSupport.request("GET", "/v9.99/containers/json"))
            #expect(newer.status == 400)
            #expect(try RouterTestSupport.message(newer) == "client version 9.99 is too new. Maximum supported API version is \(DockerAPI.version)")
            let older = await router.handle(try RouterTestSupport.request("GET", "/v1.23/_ping"))
            #expect(older.status == 400)
            #expect(try RouterTestSupport.message(older)?.contains("too old. Minimum supported API version is 1.24") == true)
            // Numeric, not lexicographic: 1.100 > 1.44.
            let numeric = await router.handle(try RouterTestSupport.request("GET", "/v1.100/_ping"))
            #expect(try RouterTestSupport.message(numeric)?.contains("too new") == true)

            let ping = await router.handle(try RouterTestSupport.request("HEAD", "/_ping"))
            #expect(RouterTestSupport.header(ping, "Builder-Version") == "2")
            #expect(RouterTestSupport.header(ping, "Ostype") == "linux")
        }
    }

    @Test func officialCreateBodyUsesDefaultNetworkAndTopLevelStopFields() async throws {
        try await withRouter { router, engine in
            try await RouterTestSupport.importTagged(engine, repo: "alpine")
            var body = Self.officialCreateBody()
            body["StopSignal"] = "SIGQUIT"
            body["StopTimeout"] = 7
            var host = body["HostConfig"] as! [String: Any]
            host["Init"] = true
            host["AutoRemove"] = false
            body["HostConfig"] = host
            let created = await router.handle(try RouterTestSupport.request("POST", "/v1.44/containers/create", body: body))
            #expect(created.status == 201, "\(RouterTestSupport.text(created))")
            let id = try #require(try RouterTestSupport.jsonObject(created)["Id"] as? String)

            let inspected = try RouterTestSupport.jsonObject(
                await router.handle(try RouterTestSupport.request("GET", "/containers/\(id)/json"))
            )
            let config = try #require(inspected["Config"] as? [String: Any])
            #expect(config["StopSignal"] as? String == "SIGQUIT")
            #expect((config["StopTimeout"] as? NSNumber)?.intValue == 7)
            #expect(config["StdinOnce"] as? Bool == true)
            #expect(config["Cmd"] as? [String] == ["true"])
            let hostConfig = try #require(inspected["HostConfig"] as? [String: Any])
            #expect(hostConfig["StopSignal"] == nil)
            #expect(hostConfig["Init"] as? Bool == true)
            let networks = (inspected["NetworkSettings"] as? [String: Any])?["Networks"] as? [String: Any]
            #expect(networks?.keys.sorted() == ["bridge"])
        }
    }

    @Test func createRejectsOptionsAMicroVMCannotHonor() async throws {
        try await withRouter { router, engine in
            try await RouterTestSupport.importTagged(engine, repo: "alpine")
            let cases: [(String, Any, String)] = [
                ("PidMode", "host", "HostConfig.PidMode (--pid)"),
                ("Devices", [["PathOnHost": "/dev/null", "PathInContainer": "/dev/null", "CgroupPermissions": "rwm"]], "HostConfig.Devices (--device)"),
                ("SecurityOpt", ["seccomp=unconfined"], "HostConfig.SecurityOpt (--security-opt)"),
                ("Sysctls", ["net.ipv4.ip_forward": "1"], "HostConfig.Sysctls (--sysctl)"),
                ("LogConfig", ["Type": "syslog", "Config": [String: String]()], "HostConfig.LogConfig.Type (--log-driver)"),
            ]
            for (field, value, expected) in cases {
                var body = Self.officialCreateBody()
                var host = body["HostConfig"] as! [String: Any]
                host[field] = value
                body["HostConfig"] = host
                let response = await router.handle(try RouterTestSupport.request("POST", "/containers/create", body: body))
                #expect(response.status == 400, "\(field)")
                #expect(try RouterTestSupport.message(response)?.contains(expected) == true, "\(field)")
            }
            let listed = await router.handle(try RouterTestSupport.request("GET", "/containers/json", query: ["all": "1"]))
            #expect(try RouterTestSupport.jsonArray(listed).isEmpty)
        }
    }

    @Test func filtersAcceptTheMapFormTheCLISends() async throws {
        #expect(Router.parseFilters(#"{"label":{"a=b":true,"c":true}}"#) == ["label": ["a=b", "c"]])
        #expect(Router.parseFilters(#"{"label":["a=b"]}"#) == ["label": ["a=b"]])
        try await withRouter { router, engine in
            try await RouterTestSupport.importTagged(engine, repo: "alpine")
            _ = try await RouterTestSupport.createContainer(router, name: "web", labels: ["a": "b"])
            _ = try await RouterTestSupport.createContainer(router, name: "other")
            let listed = await router.handle(
                try RouterTestSupport.request(
                    "GET", "/containers/json",
                    query: ["all": "1", "filters": #"{"label":{"a=b":true}}"#]
                )
            )
            #expect(try RouterTestSupport.jsonArray(listed).map { $0["Names"] as? [String] } == [["/web"]])
        }
    }

    @Test func containerEventsCarryLabelsAndMatchLabelFilters() async throws {
        try await withRouter { router, engine in
            try await RouterTestSupport.importTagged(engine, repo: "alpine")
            let events = await engine.events(since: Date(timeIntervalSince1970: 0), until: Date().addingTimeInterval(60))
            _ = try await RouterTestSupport.createContainer(router, name: "w", labels: ["ev": "1"])
            _ = try await RouterTestSupport.createContainer(router, name: "o")
            var creates: [EngineEvent] = []
            for await event in events where event.action == "create" && event.type == "container" {
                creates.append(event)
                if creates.count == 2 { break }
            }
            #expect(creates.first?.attributes["ev"] == "1")
            #expect(creates.filter { Router.matches($0, filters: ["label": ["ev=1"]]) }.map { $0.attributes["name"] } == ["w"])
        }
    }

    @Test func waitHonorsConditionsAndStreamsTheBodyLater() async throws {
        try await withRouter { router, engine in
            try await RouterTestSupport.importTagged(engine, repo: "alpine")
            let id = try await RouterTestSupport.createContainer(router, name: "w")

            let bad = await router.handle(try RouterTestSupport.request("POST", "/containers/\(id)/wait", query: ["condition": "bogus"]))
            #expect(bad.status == 400)

            // not-running on a created container returns at once.
            let now = await router.handle(try RouterTestSupport.request("POST", "/containers/\(id)/wait"))
            #expect(try await Self.firstChunk(now) == #"{"StatusCode":0}"#)

            // next-exit / removed must not resolve from the stale state; removal resolves both.
            let next = await router.handle(try RouterTestSupport.request("POST", "/containers/\(id)/wait", query: ["condition": "next-exit"]))
            let removed = await router.handle(try RouterTestSupport.request("POST", "/containers/\(id)/wait", query: ["condition": "removed"]))
            #expect(next.status == 200)
            guard case .stream(let nextStream) = next.body, case .stream(let removedStream) = removed.body else {
                Issue.record("wait must stream its body")
                return
            }
            let deleted = await router.handle(try RouterTestSupport.request("DELETE", "/containers/\(id)"))
            #expect(deleted.status == 204)
            for stream in [nextStream, removedStream] {
                var text = ""
                for await var chunk in stream.chunks {
                    text += chunk.readString(length: chunk.readableBytes) ?? ""
                }
                #expect(text.trimmingCharacters(in: .newlines) == #"{"StatusCode":0}"#)
            }
        }
    }

    @Test func volumePruneBefore142RemovesNamedVolumes() async throws {
        try await withRouter { router, _ in
            for name in ["keep", "drop"] {
                _ = await router.handle(try RouterTestSupport.request("POST", "/volumes/create", body: ["Name": name]))
            }
            let current = await router.handle(try RouterTestSupport.request("POST", "/v1.44/volumes/prune"))
            #expect((try RouterTestSupport.jsonObject(current)["VolumesDeleted"] as? [String] ?? []).isEmpty)
            let legacy = await router.handle(try RouterTestSupport.request("POST", "/v1.41/volumes/prune"))
            #expect((try RouterTestSupport.jsonObject(legacy)["VolumesDeleted"] as? [String])?.sorted() == ["drop", "keep"])
        }
    }

    @Test func streamContentTypeFollowsAPIVersion() {
        let v141 = DockerAPIVersion("1.41")!
        let v144 = DockerAPIVersion("1.44")!
        #expect(Router.streamContentType(tty: false, version: v141) == "application/vnd.docker.raw-stream")
        #expect(Router.streamContentType(tty: false, version: v144) == "application/vnd.docker.multiplexed-stream")
        #expect(Router.streamContentType(tty: true, version: v144) == "application/vnd.docker.raw-stream")
    }

    /// Docker clients send raw stdin bytes, then shut down their write side for EOF.
    @Test func hijackStdinIsRawAndHalfCloseIsEOF() async throws {
        let log = EventLog()
        let (output, outputContinuation) = AsyncStream<ByteBuffer>.makeStream()
        let session = DockerHijack(
            kind: .tcp,
            output: output,
            onStdin: { data in await log.append("data:" + String(decoding: data, as: UTF8.self)) },
            onStdinClosed: { await log.append("eof") },
            onClose: {}
        )
        let channel = EmbeddedChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        try await channel.pipeline.addHandler(TCPHijackHandler(session: session))
        try await channel.writeInbound(ByteBuffer(string: "abc"))
        try await channel.writeInbound(ByteBuffer(string: "def"))
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        for _ in 0..<200 where await log.items.count < 3 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await log.items == ["data:abc", "data:def", "eof"])
        // Half-close is not a disconnect: output must still be deliverable.
        #expect(channel.isActive)
        outputContinuation.finish()
        _ = try? await channel.finish()
    }

    private static func firstChunk(_ response: HTTPResponse) async throws -> String {
        guard case .stream(let stream) = response.body else { return "" }
        for await var chunk in stream.chunks {
            return (chunk.readString(length: chunk.readableBytes) ?? "").trimmingCharacters(in: .newlines)
        }
        return ""
    }
}

private actor EventLog {
    var items: [String] = []
    func append(_ item: String) { items.append(item) }
}
