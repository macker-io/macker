import Foundation
import Testing
@testable import ContainerEngine

struct BuildContextTests {
    @Test func ignorePatternBasics() {
        let ignore = DockerIgnore(
            """
            # comment

            *.log
            build/
            /root.txt
            **/node_modules
            temp?
            """
        )
        #expect(ignore.excludes("app.log"))
        #expect(!ignore.excludes("app.logger"))
        #expect(ignore.excludes("build"))
        #expect(ignore.excludes("build/main.o"))
        #expect(ignore.excludes("root.txt"))
        #expect(ignore.excludes("node_modules"))
        #expect(ignore.excludes("web/node_modules/react/index.js"))
        #expect(ignore.excludes("temp1"))
        #expect(!ignore.excludes("temp12"))
        #expect(!ignore.excludes("src/main.swift"))
    }

    @Test func negationReincludes() {
        let ignore = DockerIgnore(
            """
            *
            !src
            !src/**
            """
        )
        #expect(ignore.hasNegations)
        #expect(ignore.excludes("secrets.env"))
        #expect(!ignore.excludes("src"))
        #expect(!ignore.excludes("src/main.swift"))
    }

    @Test func entriesSkipIgnoredFilesButKeepTheDockerfile() throws {
        try TemporaryDirectory.with("macker-context") { root in
            let fm = FileManager.default
            try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
            try fm.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
            try "FROM alpine\n".write(to: root.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
            try "Dockerfile\nbuild\n*.log\n".write(
                to: root.appendingPathComponent(".dockerignore"),
                atomically: true,
                encoding: .utf8
            )
            try "int main(){}\n".write(to: root.appendingPathComponent("src/main.c"), atomically: true, encoding: .utf8)
            try "noise\n".write(to: root.appendingPathComponent("debug.log"), atomically: true, encoding: .utf8)
            try "obj\n".write(to: root.appendingPathComponent("build/a.o"), atomically: true, encoding: .utf8)

            let entries = try BuildContext.entries(
                root: root,
                ignore: BuildContext.loadIgnore(root: root),
                alwaysInclude: ["Dockerfile"]
            )
            #expect(entries.contains("Dockerfile"))
            #expect(entries.contains("src/main.c"))
            #expect(entries.contains("src"))
            #expect(!entries.contains("debug.log"))
            #expect(!entries.contains("build"))
            #expect(!entries.contains("build/a.o"))
        }
    }

    @Test func packRoundTripsThroughTar() throws {
        try TemporaryDirectory.with("macker-context-tar") { work in
            let root = work.appendingPathComponent("ctx", isDirectory: true)
            let fm = FileManager.default
            try fm.createDirectory(at: root.appendingPathComponent("app"), withIntermediateDirectories: true)
            try "FROM alpine\nCOPY app /app\n".write(
                to: root.appendingPathComponent("Dockerfile"),
                atomically: true,
                encoding: .utf8
            )
            try "hello\n".write(to: root.appendingPathComponent("app/main.txt"), atomically: true, encoding: .utf8)
            try "ignored\n".write(to: root.appendingPathComponent("skip.me"), atomically: true, encoding: .utf8)
            try "skip.me\n".write(to: root.appendingPathComponent(".dockerignore"), atomically: true, encoding: .utf8)

            let archive = work.appendingPathComponent("context.tar")
            try BuildContext.pack(root: root, into: archive)

            let extracted = work.appendingPathComponent("out", isDirectory: true)
            try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
            try TarArchive.extract(archive, to: extracted)
            #expect(try BuildContext.dockerfile(in: extracted, named: "Dockerfile").contains("COPY app /app"))
            #expect(fm.fileExists(atPath: extracted.appendingPathComponent("app/main.txt").path))
            #expect(!fm.fileExists(atPath: extracted.appendingPathComponent("skip.me").path))
        }
    }

    @Test func packRejectsAMissingDockerfile() throws {
        try TemporaryDirectory.with("macker-context-missing") { root in
            #expect(throws: EngineError.self) {
                try BuildContext.pack(root: root, into: root.appendingPathComponent("out.tar"))
            }
        }
    }

    @Test func dockerfileLookupRejectsEscapes() throws {
        try TemporaryDirectory.with("macker-context-escape") { root in
            #expect(throws: EngineError.self) {
                try BuildContext.dockerfile(in: root, named: "../Dockerfile")
            }
        }
    }
}
