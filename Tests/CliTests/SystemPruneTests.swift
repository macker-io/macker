import Testing
@testable import CliCore

struct SystemPruneTests {
    @Test func plansOnlyStagesThatCanHonorEveryFilter() throws {
        #expect(try SystemPrune.includesBuildCache(filters: [], volumes: true))
        #expect(try SystemPrune.includesBuildCache(filters: ["until=24h"], volumes: false))
        #expect(try !SystemPrune.includesBuildCache(filters: ["label!=keep"], volumes: true))
        #expect(throws: CLIError.self) {
            try SystemPrune.includesBuildCache(filters: ["until=24h"], volumes: true)
        }
        #expect(throws: CLIError.self) {
            try SystemPrune.includesBuildCache(filters: ["typo=keep"], volumes: false)
        }
    }

    @Test func malformedFilterIsNotReinterpretedAsAnotherPredicate() {
        for raw in ["=label=keep", "label="] {
            #expect(throws: CLIError.self) { try DaemonAPI.filtersJSON([raw]) }
        }
    }
}
