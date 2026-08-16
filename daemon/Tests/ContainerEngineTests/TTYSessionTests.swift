import Foundation
import Testing
@testable import ContainerEngine

struct TTYSessionTests {
    /// Captured from a running `alpine sh` attach session.
    private let ashLog = Data(
        "/ # \u{1b}[6n\r/ # \u{1b}[J\r\n/ # \u{1b}[6n\r\n/ # \u{1b}[6n\r\n/ # \u{1b}[6n\r\n/ # \u{1b}[6n\r\n/ # \u{1b}[6n\r\n/ # \u{1b}[6n^C\r\n\r\n/ # \u{1b}[6n^C\r\n\r\n/ # \u{1b}[6n^C\r\n\r\n/ # \u{1b}[6n\r\n/ # \u{1b}[6n^C\r\n\r\n/ # \u{1b}[6n\u{07}q\u{08}\u{1b}[J"
            .utf8
    )

    @Test func cookDropsDeviceStatusAndExtraIntrNewline() {
        let cooked = TTYSession.cook(ashLog)
        #expect(!cooked.contains("\u{1b}"))
        #expect(!cooked.contains("[6n"))
        #expect(!cooked.contains("65;5R"))
        #expect(!cooked.contains("\r"))
        #expect(!cooked.contains("^C\n\n"))
        #expect(cooked.contains("^C\n"))
    }

    @Test func ingestDropsDSRFromAttach() {
        var session = TTYSession()
        let output = session.ingest(Data("/ # \u{1b}[6n".utf8))
        #expect(String(decoding: output.attach, as: UTF8.self) == "/ # ")
        #expect(output.log.isEmpty)
        #expect(String(decoding: session.currentLine, as: UTF8.self) == "/ # ")
        #expect(session.finish() == "/ # ")
        #expect(session.currentLine.isEmpty)
    }

    @Test func currentLineTracksPromptAcrossRedraw() {
        var session = TTYSession()
        _ = session.ingest(Data("/ # \u{1b}[6n".utf8))
        #expect(String(decoding: session.currentLine, as: UTF8.self) == "/ # ")

        _ = session.ingest(Data("ls\r\n".utf8))
        #expect(session.currentLine.isEmpty)

        _ = session.ingest(Data("\r/ # \u{1b}[J\u{1b}[6n".utf8))
        #expect(String(decoding: session.currentLine, as: UTF8.self) == "/ # ")
    }

    @Test func currentLineIncludesTypedTextAndDropsColor() {
        var session = TTYSession()
        _ = session.ingest(Data("\u{1b}[32m/ #\u{1b}[0m ".utf8))
        #expect(String(decoding: session.currentLine, as: UTF8.self) == "/ # ")

        _ = session.ingest(Data("ls".utf8))
        #expect(String(decoding: session.currentLine, as: UTF8.self) == "/ # ls")
    }

    @Test func ingestCollapsesDoubleNewlineAfterCtrlC() {
        var session = TTYSession()
        let output = session.ingest(Data("^C\r\n\r\n/ # ".utf8))
        #expect(String(decoding: output.attach, as: UTF8.self) == "^C\r\n/ # ")
        #expect(output.log == "^C\n")
    }

    @Test func ingestSplitsCSIAcrossChunks() {
        var session = TTYSession()
        let first = session.ingest(Data([0x1b, 0x5b, 0x36]))
        #expect(first.attach.isEmpty)
        let second = session.ingest(Data([0x6e, 0x41])) // n then 'A'
        #expect(String(decoding: second.attach, as: UTF8.self) == "A")
    }

    @Test func cookIsIdempotentOnPlainText() {
        let text = "/ # pwd\n/\n/ # \n"
        #expect(TTYSession.cook(text) == text)
    }
}
