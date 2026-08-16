import Foundation

/// Per-container TTY sanitizer.
///
/// Alpine ash (busybox `FEATURE_EDITING_ASK_TERMINAL`) writes `CSI 6 n` after
/// every prompt. The host terminal answers `CSI row ; col R` on stdin. Storing
/// those queries in logs makes `logs -f` replay them, and the user's terminal
/// prints `^[[65;5R`. Ash also emits `^C CR LF CR LF` on interrupt.
///
/// Attach keeps live control sequences (so the prompt can redraw) but drops DSR
/// queries and the extra blank line after `^C`. Logs are cooked into plain text.
struct TTYSession: Sendable {
    private var pending = Data()
    private var collapse = IntrCollapse()
    private var cooker = Cooker()

    mutating func ingest(_ data: Data) -> (attach: Data, log: String) {
        let stripped = DeviceStatus.strip(data, pending: &pending)
        let attach = collapse.ingest(stripped)
        return (attach, cooker.ingest(attach))
    }

    /// Trailing prompt with no newline. Used when loading a saved log file.
    mutating func finish() -> String {
        cooker.flush()
    }

    static func cook(_ text: String) -> String {
        cook(Data(text.utf8))
    }

    static func cook(_ data: Data) -> String {
        var session = TTYSession()
        let log = session.ingest(data).log
        return log + session.finish()
    }
}

/// Drops DSR queries (`CSI 6 n`) and cursor reports (`CSI n ; m R`). Incomplete
/// sequences stay in `pending` until a later chunk.
private enum DeviceStatus {
    static func strip(_ data: Data, pending: inout Data) -> Data {
        pending.append(data)
        let bytes = [UInt8](pending)
        var out = Data()
        var i = 0
        while i < bytes.count {
            guard bytes[i] == 0x1b else {
                out.append(bytes[i])
                i += 1
                continue
            }
            guard i + 1 < bytes.count else { break }
            guard bytes[i + 1] == 0x5b else {
                out.append(0x1b)
                i += 1
                continue
            }
            var j = i + 2
            var digitsAndSemi = true
            var complete = false
            while j < bytes.count {
                let byte = bytes[j]
                if (0x30...0x3f).contains(byte) {
                    if byte != 0x3b && !(0x30...0x39).contains(byte) {
                        digitsAndSemi = false
                    }
                    j += 1
                    continue
                }
                if (0x40...0x7e).contains(byte) {
                    complete = true
                    if digitsAndSemi && (byte == 0x52 || byte == 0x6e) {
                        i = j + 1
                    } else {
                        out.append(contentsOf: bytes[i...j])
                        i = j + 1
                    }
                    break
                }
                out.append(0x1b)
                i += 1
                complete = true
                break
            }
            if !complete { break }
        }
        pending = Data(bytes[i...])
        return out
    }
}

/// Keeps one CR/LF after echoed `^C`, drops the extra blank line ash adds.
private struct IntrCollapse: Sendable {
    private var sawCaret = false
    private var passNewline = false
    private var eatNewline = false

    mutating func ingest(_ data: Data) -> Data {
        var out = Data()
        for byte in data {
            if eatNewline {
                if byte == 0x0d { continue }
                if byte == 0x0a {
                    eatNewline = false
                    continue
                }
                eatNewline = false
            }
            if passNewline {
                out.append(byte)
                if byte == 0x0a {
                    passNewline = false
                    eatNewline = true
                } else if byte != 0x0d {
                    passNewline = false
                }
                continue
            }
            out.append(byte)
            if sawCaret {
                sawCaret = false
                if byte == 0x43 {
                    passNewline = true
                }
                continue
            }
            sawCaret = byte == 0x5e
        }
        return out
    }
}

/// Turns a TTY byte stream into newline-delimited text: CR overwrites the line,
/// backspace deletes, CSI/OSC/BEL are dropped (`CSI J` / `CSI K` clear the rest
/// of the line).
private struct Cooker: Sendable {
    private var line: [UInt8] = []
    private var col = 0
    private enum Mode { case text, esc, csi, osc }
    private var mode = Mode.text
    private var oscEsc = false

    mutating func ingest(_ data: Data) -> String {
        var out = Data()
        for byte in data {
            switch mode {
            case .text:
                switch byte {
                case 0x1b:
                    mode = .esc
                case 0x07:
                    break
                case 0x08, 0x7f:
                    if col > 0 {
                        col -= 1
                        if col < line.count {
                            line.remove(at: col)
                        }
                    }
                case 0x0d:
                    col = 0
                case 0x0a:
                    out.append(contentsOf: line)
                    out.append(0x0a)
                    line = []
                    col = 0
                default:
                    guard byte >= 0x20 else { break }
                    if col < line.count {
                        line[col] = byte
                    } else {
                        line.append(byte)
                    }
                    col += 1
                }
            case .esc:
                if byte == 0x5b {
                    mode = .csi
                } else if byte == 0x5d {
                    mode = .osc
                    oscEsc = false
                } else {
                    mode = .text
                }
            case .csi:
                guard (0x40...0x7e).contains(byte) else { break }
                if byte == 0x4b || byte == 0x4a, col < line.count {
                    line.removeSubrange(col...)
                }
                mode = .text
            case .osc:
                if byte == 0x07 || (oscEsc && byte == 0x5c) {
                    mode = .text
                    oscEsc = false
                } else {
                    oscEsc = byte == 0x1b
                }
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    mutating func flush() -> String {
        let text = String(decoding: Data(line), as: UTF8.self)
        line = []
        col = 0
        mode = .text
        oscEsc = false
        return text
    }
}
