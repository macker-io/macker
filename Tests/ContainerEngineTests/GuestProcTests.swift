import Foundation
import Testing
@testable import ContainerEngine

struct GuestProcTests {
    @Test func parsePSSplitsCommandWithSpaces() {
        let text = """
            UID   PID  PPID  CMD
            root    1     0  /sbin/init
            root   12     1  nginx: master process
            """
        let top = GuestProc.parsePS(text)
        #expect(top.titles == ["UID", "PID", "PPID", "CMD"])
        #expect(top.processes[0] == ["root", "1", "0", "/sbin/init"])
        #expect(top.processes[1] == ["root", "12", "1", "nginx: master process"])
    }

    @Test func parseDumpReadsStatMemNetAndPids() {
        let dump = """
            __STAT__
            cpu  10 0 5 80 5 0 0 0
            cpu0 10 0 5 80 5 0 0 0
            cpu1 0 0 0 0 0 0 0 0
            __MEM__
            MemTotal:        1000 kB
            MemAvailable:     400 kB
            __NET__
            Inter-|   Receive                                                |  Transmit
             face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
                lo: 100 0 0 0 0 0 0 0 100 0 0 0 0 0 0 0
              eth0: 200 1 0 0 0 0 0 0 50 1 0 0 0 0 0 0
            __PIDS__
            1
            2
            self
            """
        let snap = GuestProc.parseDump(dump)
        #expect(snap != nil)
        #expect(snap?.onlineCPUs == 2)
        #expect(snap?.busyJiffies == 15)
        #expect(snap?.totalJiffies == 100)
        #expect(snap?.memoryTotal == 1000 * 1024)
        #expect(snap?.memoryUsage == 600 * 1024)
        #expect(snap?.networks["eth0"]?.rxBytes == 200)
        #expect(snap?.networks["eth0"]?.txBytes == 50)
        #expect(snap?.networks["lo"] == nil)
        #expect(snap?.pids == 2)
    }

    @Test func cpuNanosecondsUsesUserHz() {
        #expect(GuestProc.cpuNanoseconds(jiffies: 100) == 1_000_000_000)
    }

    @Test func topSourceUsesProcForDefaultPS() {
        #expect(GuestProc.topSource(nil) == .proc)
        #expect(GuestProc.topSource("") == .proc)
        #expect(GuestProc.topSource("-ef") == .proc)
        #expect(GuestProc.topSource("aux") == .guestPS(["ps", "aux"]))
        #expect(GuestProc.psCommand(args: "-eo pid,comm") == ["ps", "-eo", "pid,comm"])
    }

    @Test func parseTopReadsProcWithoutPS() {
        let dump = topDump(
            passwd: """
            root:x:0:0:root:/root:/bin/sh
            www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin
            """,
            rows: [
                "12\t33\t1\t12 (nginx) S 1 12 12 34816 12 0 0 0 0 0 100 200 0 0 20 0 1 0 200 0 0\tnginx\tnginx: master process",
                "1\t0\t0\t1 (init) S 0 1 1 0 -1 4194560 0 0 0 0 1 2 0 0 20 0 1 0 100 0 0\tinit\t",
            ]
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000 + 60)
        let utc = TimeZone(secondsFromGMT: 0)!
        let top = GuestProc.parseTop(dump, now: now, timeZone: utc)
        #expect(top.titles == GuestProc.defaultTopTitles)
        #expect(top.processes.count == 2)
        #expect(top.processes[0][0] == "root")
        #expect(top.processes[0][1] == "1")
        #expect(top.processes[0][2] == "0")
        #expect(top.processes[0][5] == "?")
        #expect(top.processes[0][6] == "00:00:00")
        #expect(top.processes[0][7] == "[init]")
        #expect(top.processes[1][0] == "www-data")
        #expect(top.processes[1][1] == "12")
        #expect(top.processes[1][2] == "1")
        #expect(top.processes[1][5] == "pts/0")
        #expect(top.processes[1][6] == "00:00:03")
        #expect(top.processes[1][7] == "nginx: master process")
        #expect(top.processes[0][4] == top.processes[1][4])
        #expect(top.processes[0][4] == "22:13")
    }

    @Test func parseTopDropsCollectorShell() {
        let dump = topDump(rows: [
            "1\t0\t0\t1 (nginx) S 0 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0\tnginx\tnginx: master process nginx -g daemon off;",
            "55\t0\t0\t55 (sh) S 0 55 55 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0\tsh\tsh -c printf '__PASSWD__\\n' cat /etc/passwd",
        ])
        let top = GuestProc.parseTop(dump, now: Date(timeIntervalSince1970: 1_700_000_060), timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(top.processes.count == 1)
        #expect(top.processes[0][1] == "1")
        #expect(top.processes[0][7] == "nginx: master process nginx -g daemon off;")
    }

    @Test func parseTopCollapsesMultilineCommand() {
        let dump = topDump(rows: [
            "1\t0\t0\t1 (sh) S 0 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0\tsh\tsh -c echo hello world",
        ])
        let top = GuestProc.parseTop(dump, now: Date(timeIntervalSince1970: 1_700_000_060), timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(top.processes.count == 1)
        #expect(top.processes[0][7] == "sh -c echo hello world")
        #expect(!top.processes[0][7].contains("\n"))
    }

    private func topDump(
        passwd: String = "root:x:0:0:root:/root:/bin/sh",
        btime: UInt64 = 1_700_000_000,
        rows: [String]
    ) -> String {
        """
        __PASSWD__
        \(passwd)
        __STAT__
        btime \(btime)
        __PROCS__
        \(rows.joined(separator: "\n"))
        """
    }
}
