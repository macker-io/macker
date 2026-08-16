import Foundation

/// Guest `/proc` dumps and `ps` output for `stats` / `top`.
enum GuestProc {
    struct Snapshot: Sendable, Equatable {
        var busyJiffies: UInt64
        var totalJiffies: UInt64
        var onlineCPUs: Int
        var memoryUsage: UInt64
        var memoryTotal: UInt64
        var networks: [String: Network]
        var pids: Int

        struct Network: Sendable, Equatable {
            var rxBytes: UInt64
            var txBytes: UInt64
        }
    }

    enum TopSource: Equatable {
        case proc
        case guestPS([String])
    }

    static let dumpScript = """
        printf '__STAT__\\n'
        cat /proc/stat
        printf '__MEM__\\n'
        cat /proc/meminfo
        printf '__NET__\\n'
        cat /proc/net/dev
        printf '__PIDS__\\n'
        for dir in /proc/[0-9]*; do
          pid=${dir#/proc/}
          [ "$pid" = "$$" ] && continue
          printf '%s\\n' "$pid"
        done
        """

    /// One TSV row per process. Slim images often have no `ps`; this uses `/proc` only.
    static let topScript = """
        printf '__PASSWD__\\n'
        cat /etc/passwd 2>/dev/null || true
        printf '__STAT__\\n'
        cat /proc/stat
        printf '__PROCS__\\n'
        for dir in /proc/[0-9]*; do
          pid=${dir#/proc/}
          [ "$pid" = "$$" ] && continue
          [ -r "$dir/stat" ] || continue
          uid=0
          ppid=0
          comm='?'
          while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
              Uid:*) set -- $line; uid=$2 ;;
              PPid:*) set -- $line; ppid=$2 ;;
              Name:*) set -- $line; comm=$2 ;;
            esac
          done < "$dir/status"
          read -r stat < "$dir/stat" || continue
          cmd=$(tr '\\0\\t\\n' '   ' < "$dir/cmdline" 2>/dev/null)
          printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$pid" "$uid" "$ppid" "$stat" "$comm" "$cmd"
        done
        """

    static let defaultTopTitles = ["UID", "PID", "PPID", "C", "STIME", "TTY", "TIME", "CMD"]

    static func parseDump(_ text: String) -> Snapshot? {
        let sections = splitSections(text)
        guard let stat = sections["STAT"], let mem = sections["MEM"] else { return nil }
        let cpu = parseStat(stat)
        let memory = parseMeminfo(mem)
        return Snapshot(
            busyJiffies: cpu.busy,
            totalJiffies: cpu.total,
            onlineCPUs: max(cpu.online, 1),
            memoryUsage: memory.usage,
            memoryTotal: memory.total,
            networks: parseNetDev(sections["NET"] ?? ""),
            pids: parseProcPids(sections["PIDS"] ?? "")
        )
    }

    static func cpuNanoseconds(jiffies: UInt64, hz: UInt64 = 100) -> UInt64 {
        guard hz > 0 else { return 0 }
        return jiffies &* 1_000_000_000 / hz
    }

    static func topSource(_ args: String?) -> TopSource {
        let spec = args?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if spec.isEmpty || spec == "-ef" {
            return .proc
        }
        return .guestPS(psCommand(args: spec))
    }

    static func parsePS(_ text: String) -> EngineContainerTop {
        let lines = text.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard let header = lines.first else {
            return EngineContainerTop(titles: ["PID", "CMD"], processes: [])
        }
        let titles = header.split(whereSeparator: \.isWhitespace).map(String.init)
        let columns = max(titles.count, 1)
        let processes = lines.dropFirst().map { splitPSLine($0, columns: columns) }
        return EngineContainerTop(titles: titles, processes: processes)
    }

    static func parseTop(
        _ text: String,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        hz: UInt64 = 100
    ) -> EngineContainerTop {
        let sections = splitSections(text)
        let context = TopContext(
            users: userNames(sections["PASSWD"] ?? ""),
            btime: parseBtime(sections["STAT"] ?? ""),
            now: now,
            hz: max(hz, 1),
            timeZone: timeZone
        )
        let processes = (sections["PROCS"] ?? "").split(whereSeparator: \.isNewline).compactMap {
            formatProcess(String($0), context: context)
        }.sorted { (Int($0[1]) ?? 0) < (Int($1[1]) ?? 0) }
        return EngineContainerTop(titles: defaultTopTitles, processes: processes)
    }

    static func psCommand(args: String?) -> [String] {
        let spec = (args ?? "-ef").trimmingCharacters(in: .whitespacesAndNewlines)
        if spec.isEmpty {
            return ["ps", "-ef"]
        }
        return ["ps"] + spec.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private struct TopContext {
        let users: [String: String]
        let btime: UInt64
        let now: Date
        let hz: UInt64
        let calendar: Calendar
        let clock: DateFormatter
        let monthDay: DateFormatter
        let year: DateFormatter

        init(users: [String: String], btime: UInt64, now: Date, hz: UInt64, timeZone: TimeZone) {
            self.users = users
            self.btime = btime
            self.now = now
            self.hz = hz
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            self.calendar = calendar
            self.clock = Self.formatter("HH:mm", timeZone: timeZone)
            self.monthDay = Self.formatter("MMM dd", timeZone: timeZone)
            self.year = Self.formatter("yyyy", timeZone: timeZone)
        }

        private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            return formatter
        }
    }

    private static func formatProcess(_ line: String, context: TopContext) -> [String]? {
        let cols = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
        guard cols.count >= 5, !cols[0].isEmpty else { return nil }
        let cmd = collapsedCommand(cols.count > 5 ? cols[5] : "", comm: cols[4])
        if isCollector(cmd) {
            return nil
        }
        let fields = parseStatFields(cols[3])
        return [
            context.users[cols[1]] ?? cols[1],
            cols[0],
            cols[2],
            cpuPercent(ticks: fields.utime &+ fields.stime, startJiffies: fields.starttime, context: context),
            formatStartTime(startJiffies: fields.starttime, context: context),
            ttyName(fields.ttyNr),
            formatCPUTime(ticks: fields.utime &+ fields.stime, hz: context.hz),
            cmd,
        ]
    }

    private static func isCollector(_ cmdline: String) -> Bool {
        cmdline.contains("__PASSWD__")
    }

    private static func collapsedCommand(_ cmdline: String, comm: String) -> String {
        let line = cmdline
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return line.isEmpty ? "[\(comm.isEmpty ? "?" : comm)]" : line
    }

    private static func parseStatFields(_ stat: String) -> (ttyNr: UInt64, utime: UInt64, stime: UInt64, starttime: UInt64) {
        guard let close = stat.lastIndex(of: ")") else {
            return (0, 0, 0, 0)
        }
        let rest = stat[stat.index(after: close)...].split(whereSeparator: \.isWhitespace)
        func field(_ index: Int) -> UInt64 {
            guard index < rest.count else { return 0 }
            return UInt64(rest[index]) ?? 0
        }
        return (field(4), field(11), field(12), field(19))
    }

    private static func parseBtime(_ stat: String) -> UInt64 {
        for line in stat.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.first == "btime", parts.count >= 2, let value = UInt64(parts[1]) {
                return value
            }
        }
        return 0
    }

    private static func userNames(_ passwd: String) -> [String: String] {
        var names: [String: String] = [:]
        for line in passwd.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count >= 3 {
                names[String(parts[2])] = String(parts[0])
            }
        }
        return names
    }

    /// `tty_nr`: major in bits 15-8; minor in bits 31-20 and 7-0 (see proc(5)).
    private static func ttyName(_ ttyNr: UInt64) -> String {
        guard ttyNr > 0 else { return "?" }
        let major = (ttyNr >> 8) & 0xff
        let minor = (ttyNr & 0xff) | ((ttyNr >> 12) & 0xfff00)
        if major == 136 {
            return "pts/\(minor)"
        }
        if major == 4 {
            return minor >= 64 ? "ttyS\(minor - 64)" : "tty\(minor)"
        }
        return "?"
    }

    private static func formatStartTime(startJiffies: UInt64, context: TopContext) -> String {
        guard context.btime > 0 else { return "?" }
        let start = Date(
            timeIntervalSince1970: TimeInterval(context.btime) + TimeInterval(startJiffies) / TimeInterval(context.hz)
        )
        if context.calendar.isDate(start, inSameDayAs: context.now) {
            return context.clock.string(from: start)
        }
        if context.calendar.component(.year, from: start) == context.calendar.component(.year, from: context.now) {
            return context.monthDay.string(from: start)
        }
        return context.year.string(from: start)
    }

    private static func formatCPUTime(ticks: UInt64, hz: UInt64) -> String {
        let seconds = ticks / hz
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    private static func cpuPercent(ticks: UInt64, startJiffies: UInt64, context: TopContext) -> String {
        guard context.btime > 0 else { return "0" }
        let nowJiffies = UInt64(max(0, context.now.timeIntervalSince1970 - TimeInterval(context.btime)) * TimeInterval(context.hz))
        let elapsed = nowJiffies > startJiffies ? nowJiffies - startJiffies : 0
        guard elapsed > 0 else { return "0" }
        return String(min(ticks &* 100 / elapsed, 99))
    }

    private static func splitPSLine(_ line: String, columns: Int) -> [String] {
        let parts = line.split(maxSplits: max(columns - 1, 0), omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func splitSections(_ text: String) -> [String: String] {
        var sections: [String: String] = [:]
        var current = ""
        var lines: [String] = []
        func flush() {
            guard !current.isEmpty else { return }
            sections[current] = lines.joined(separator: "\n")
        }
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let raw = String(line)
            if raw.hasPrefix("__"), raw.hasSuffix("__"), raw.count > 4 {
                flush()
                current = String(raw.dropFirst(2).dropLast(2))
                lines = []
            } else {
                lines.append(raw)
            }
        }
        flush()
        return sections
    }

    private static func parseStat(_ text: String) -> (busy: UInt64, total: UInt64, online: Int) {
        var busy: UInt64 = 0
        var total: UInt64 = 0
        var online = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard let name = parts.first else { continue }
            if name == "cpu" {
                let fields = parts.dropFirst().compactMap { UInt64($0) }
                total = fields.reduce(0, +)
                let idle = fields.count > 3 ? fields[3] : 0
                let iowait = fields.count > 4 ? fields[4] : 0
                busy = total &- min(total, idle &+ iowait)
            } else if name.hasPrefix("cpu"), name.count > 3, name.dropFirst(3).allSatisfy(\.isNumber) {
                online += 1
            }
        }
        return (busy, total, online)
    }

    private static func parseMeminfo(_ text: String) -> (usage: UInt64, total: UInt64) {
        var values: [String: UInt64] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            if let kb = UInt64(parts[1]) {
                values[String(key)] = kb &* 1024
            }
        }
        let total = values["MemTotal"] ?? 0
        let available = values["MemAvailable"]
            ?? (values["MemFree"] ?? 0) &+ (values["Buffers"] ?? 0) &+ (values["Cached"] ?? 0)
        let usage = total > available ? total - available : 0
        return (usage, total)
    }

    private static func parseNetDev(_ text: String) -> [String: Snapshot.Network] {
        var networks: [String: Snapshot.Network] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "lo" else { continue }
            let fields = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace).compactMap { UInt64($0) }
            guard fields.count >= 16 else { continue }
            networks[name] = Snapshot.Network(rxBytes: fields[0], txBytes: fields[8])
        }
        return networks
    }

    private static func parseProcPids(_ text: String) -> Int {
        text.split(whereSeparator: \.isNewline).filter { line in
            let name = line.trimmingCharacters(in: .whitespaces)
            return !name.isEmpty && name.allSatisfy(\.isNumber)
        }.count
    }
}
