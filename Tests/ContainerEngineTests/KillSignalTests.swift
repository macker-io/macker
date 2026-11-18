import Testing
@testable import ContainerEngine

struct KillSignalTests {
    @Test func parsesDockerNamesAndNumbers() {
        #expect(EngineManager.parsedKillSignal("SIGINT").rawValue == 2)
        #expect(EngineManager.parsedKillSignal("INT").rawValue == 2)
        #expect(EngineManager.parsedKillSignal("9").rawValue == 9)
        #expect(EngineManager.parsedKillSignal("SIGKILL").rawValue == 9)
    }

    @Test func onlyKillAndTheEffectiveStopSignalSuppressRestart() {
        #expect(EngineManager.killSuppressesRestart(.kill, stopSignal: "SIGINT"))
        #expect(EngineManager.killSuppressesRestart(.int, stopSignal: "SIGINT"))
        #expect(!EngineManager.killSuppressesRestart(.term, stopSignal: "SIGINT"))
        #expect(EngineManager.killSuppressesRestart(.term, stopSignal: ""))
        #expect(!EngineManager.killSuppressesRestart(.hup, stopSignal: ""))
    }

    @Test func invalidFallsBackToTerm() {
        #expect(EngineManager.parsedKillSignal("not-a-signal").rawValue == 15)
        #expect(EngineManager.parsedKillSignal("").rawValue == 15)
    }
}
