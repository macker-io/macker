import Foundation
import Testing
@testable import ContainerEngine

struct DockerfileTests {
    @Test func joinsContinuationsAndDropsComments() throws {
        let file = try Dockerfile.parse(
            """
            # leading comment
            FROM alpine:3.19

            RUN apk add --no-cache \\
                # a comment inside the continuation
                curl \\
                git
            """
        )
        #expect(file.stages.count == 1)
        #expect(file.stages[0].base == "alpine:3.19")
        #expect(file.stages[0].instructions.count == 1)
        #expect(file.stages[0].instructions[0].name == "RUN")
        #expect(file.stages[0].instructions[0].arguments == "apk add --no-cache curl git")
    }

    @Test func backtickEscapeDirective() throws {
        let file = try Dockerfile.parse(
            """
            # escape=`
            FROM alpine
            RUN echo one `
                two
            """
        )
        #expect(file.stages[0].instructions[0].arguments == "echo one two")
    }

    @Test func globalArgsAreOnlyAllowedBeforeFrom() throws {
        let file = try Dockerfile.parse(
            """
            ARG VERSION=3.19
            ARG REGISTRY
            FROM alpine:${VERSION}
            """
        )
        #expect(file.globalArgs == [
            DockerfileArg(name: "VERSION", defaultValue: "3.19"),
            DockerfileArg(name: "REGISTRY", defaultValue: nil),
        ])
        #expect(file.stages[0].base == "alpine:${VERSION}")

        #expect(throws: EngineError.self) {
            try Dockerfile.parse("RUN echo hi\nFROM alpine")
        }
        #expect(throws: EngineError.self) {
            try Dockerfile.parse("RUN echo hi")
        }
    }

    @Test func namedStagesAndFlags() throws {
        let file = try Dockerfile.parse(
            """
            FROM --platform=linux/arm64 golang:1.22 AS Builder
            COPY --from=builder --chown=0:0 /out/app /usr/local/bin/app
            FROM alpine
            """
        )
        #expect(file.stages[0].name == "builder")
        #expect(file.stages[0].platform == "linux/arm64")
        #expect(file.stage(named: "BUILDER")?.index == 0)
        #expect(file.stage(named: "1")?.base == "alpine")
        #expect(file.stage(named: "missing") == nil)

        let copy = file.stages[0].instructions[0]
        #expect(copy.flags["from"] == "builder")
        #expect(copy.flags["chown"] == "0:0")
        #expect(copy.arguments == "/out/app /usr/local/bin/app")
        #expect(copy.source == "COPY --chown=0:0 --from=builder /out/app /usr/local/bin/app")
    }

    @Test func instructionNamesAreCaseInsensitive() throws {
        let file = try Dockerfile.parse("from alpine\ncmd [\"echo\", \"hi\"]")
        #expect(file.stages[0].instructions[0].name == "CMD")
    }

    @Test func unsupportedInstructionsFailLoudly() {
        #expect(throws: EngineError.self) {
            try Dockerfile.parse("FROM alpine\nONBUILD RUN echo hi")
        }
    }

    @Test func jsonExecFormVersusShellForm() throws {
        #expect(try Shellwords.command("[\"echo\", \"hi\"]", shell: ["/bin/sh", "-c"]) == ["echo", "hi"])
        #expect(try Shellwords.command("echo hi", shell: ["/bin/sh", "-c"]) == ["/bin/sh", "-c", "echo hi"])
        #expect(try Shellwords.command("echo hi", shell: ["/bin/bash", "-lc"]) == ["/bin/bash", "-lc", "echo hi"])
        #expect(throws: EngineError.self) {
            try Shellwords.command("[\"echo\", ", shell: [])
        }
    }

    @Test func quoteAwareSplit() throws {
        #expect(try Shellwords.split("a  b\tc") == ["a", "b", "c"])
        #expect(try Shellwords.split("\"one two\" three") == ["one two", "three"])
        #expect(try Shellwords.split("'one two'") == ["one two"])
        #expect(try Shellwords.split("empty \"\"") == ["empty", ""])
        #expect(throws: EngineError.self) {
            try Shellwords.split("\"unclosed")
        }
    }

    @Test func variableExpansionForms() {
        let variables = ["NAME": "macker", "EMPTY": ""]
        #expect(Shellwords.expand("$NAME-1", variables: variables) == "macker-1")
        #expect(Shellwords.expand("${NAME}s", variables: variables) == "mackers")
        #expect(Shellwords.expand("${MISSING:-fallback}", variables: variables) == "fallback")
        #expect(Shellwords.expand("${EMPTY:-fallback}", variables: variables) == "fallback")
        #expect(Shellwords.expand("${NAME:+yes}", variables: variables) == "yes")
        #expect(Shellwords.expand("${MISSING:+yes}", variables: variables) == "")
        #expect(Shellwords.expand("${MISSING}", variables: variables) == "")
        #expect(Shellwords.expand("\\$NAME", variables: variables) == "$NAME")
        #expect(Shellwords.expand("100$", variables: variables) == "100$")
    }

    @Test func onlyBuildTimeInstructionsAreExpanded() {
        let variables = ["DIR": "/app"]
        let workdir = DockerfileInstruction(name: "WORKDIR", arguments: "$DIR/src")
        #expect(EngineManager.expand(workdir, variables: variables).arguments == "/app/src")

        let run = DockerfileInstruction(name: "RUN", arguments: "echo $DIR")
        #expect(EngineManager.expand(run, variables: variables).arguments == "echo $DIR")

        let copy = DockerfileInstruction(
            name: "COPY",
            arguments: "app $DIR",
            flags: DockerfileFlags(["from": "$DIR"])
        )
        let expanded = EngineManager.expand(copy, variables: variables)
        #expect(expanded.arguments == "app /app")
        #expect(expanded.flags["from"] == "/app")
    }

    @Test func buildArgsFallBackToDeclaredDefaults() {
        let declared = [
            DockerfileArg(name: "VERSION", defaultValue: "3.19"),
            DockerfileArg(name: "REGISTRY", defaultValue: nil),
        ]
        let values = EngineManager.declaredArgs(declared, provided: ["VERSION": "3.20"])
        #expect(values == ["VERSION": "3.20", "REGISTRY": ""])
    }

    @Test func workdirIsResolvedAgainstTheCurrentDirectory() {
        #expect(EngineManager.absolutePath("src", workingDir: "/app") == "/app/src")
        #expect(EngineManager.absolutePath("/opt/app", workingDir: "/app") == "/opt/app")
        #expect(EngineManager.absolutePath("src", workingDir: "/") == "/src")
        #expect(EngineManager.absolutePath("./src/", workingDir: "/app") == "/app/src")
    }

    @Test func buildKitSyntaxIsDetectedBeforeParse() throws {
        #expect(Dockerfile.buildKitSyntax(in: "# syntax=docker/dockerfile:1\nFROM alpine") == "# syntax=")
        #expect(Dockerfile.buildKitSyntax(in: "# syntax = docker/dockerfile:1\nFROM alpine") == "# syntax=")
        #expect(Dockerfile.buildKitSyntax(in: "FROM alpine\nRUN <<EOF\necho hi\nEOF") == "heredoc")
        #expect(Dockerfile.buildKitSyntax(in: "FROM alpine\nRUN echo hi") == nil)
        #expect(throws: EngineError.self) {
            try BuildBackend.select(dockerfile: "# syntax=docker/dockerfile:1\nFROM alpine")
        }
        let backend = try BuildBackend.select(dockerfile: "FROM alpine\nCMD echo hi")
        #expect(backend == .classic)
    }

    @Test func buildKitInstructionFlagsAreRejected() throws {
        let file = try Dockerfile.parse("FROM alpine\nRUN --mount=type=cache echo hi")
        #expect(file.buildKitInstruction == "RUN --mount")
        let copy = try Dockerfile.parse("FROM alpine\nCOPY --link a /b")
        #expect(copy.buildKitInstruction == "COPY --link")
        #expect(try Dockerfile.parse("FROM alpine\nCOPY --from=builder a /b").buildKitInstruction == nil)
    }
}
