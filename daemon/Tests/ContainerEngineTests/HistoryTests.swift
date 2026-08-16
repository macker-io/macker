import ContainerizationOCI
import Foundation
import Testing
@testable import ContainerEngine

struct HistoryTests {
    @Test func newestFirstWithImageIDOnTopRow() {
        let items = EngineImageHistoryItem.from(
            history: [
                History(created: "2020-01-01T00:00:00Z", createdBy: "FROM alpine", emptyLayer: false),
                History(created: "2020-01-01T00:00:01Z", createdBy: "ENV FOO=bar", emptyLayer: true),
                History(created: "2020-01-01T00:00:02Z", createdBy: "COPY file /", emptyLayer: false),
                History(created: "2020-01-01T00:00:03Z", createdBy: "CMD [\"/file\"]", emptyLayer: true),
            ],
            layerSizes: [1_234_567, 42],
            imageDigest: "sha256:image",
            tags: ["alpine:latest"]
        )

        #expect(items.map(\.id) == ["sha256:image", "<missing>", "<missing>", "<missing>"])
        #expect(items.map(\.size) == [0, 42, 0, 1_234_567])
        #expect(items.map(\.createdBy) == ["CMD [\"/file\"]", "COPY file /", "ENV FOO=bar", "FROM alpine"])
        #expect(items[0].tags == ["alpine:latest"])
        #expect(items[1].tags.isEmpty)
        #expect(items[3].created == 1_577_836_800)
    }

    @Test func omittedEmptyLayerCountsAsAFilesystemDiff() {
        let items = EngineImageHistoryItem.from(
            history: [
                History(createdBy: "ADD file", emptyLayer: nil),
                History(createdBy: "ENV X=1", emptyLayer: true),
            ],
            layerSizes: [99],
            imageDigest: "sha256:image",
            tags: []
        )

        #expect(items.map(\.id) == ["sha256:image", "<missing>"])
        #expect(items.map(\.createdBy) == ["ENV X=1", "ADD file"])
        #expect(items.map(\.size) == [0, 99])
    }

    @Test func extraNonEmptyHistoryGetsZeroSize() {
        let items = EngineImageHistoryItem.from(
            history: [
                History(createdBy: "FROM scratch", emptyLayer: false),
                History(createdBy: "COPY extra", emptyLayer: false),
            ],
            layerSizes: [10],
            imageDigest: "sha256:image",
            tags: ["img:tag"]
        )

        #expect(items.map(\.id) == ["sha256:image", "<missing>"])
        #expect(items.map(\.size) == [0, 10])
        #expect(items[0].tags == ["img:tag"])
    }

    @Test func gzipISIZEReadsLittleEndianUncompressedSize() {
        #expect(ImageLayerSize.gzipISIZE(Data([5, 0, 0, 0])) == 5)
        #expect(ImageLayerSize.gzipISIZE(Data([0x78, 0x56, 0x34, 0x12])) == 0x1234_5678)
        #expect(ImageLayerSize.gzipISIZE(Data([1, 2, 3])) == nil)
    }

    @Test func uncompressedPrefersAnnotationThenCompressedSize() {
        let gzip = Descriptor(mediaType: MediaTypes.imageLayerGzip, digest: "sha256:a", size: 100)
        #expect(ImageLayerSize.uncompressed(gzip) == 100)
        #expect(ImageLayerSize.isGzip(gzip.mediaType))

        let annotated = Descriptor(
            mediaType: MediaTypes.imageLayerGzip,
            digest: "sha256:a",
            size: 100,
            annotations: [ImageLayerSize.uncompressedAnnotation: "999"]
        )
        #expect(ImageLayerSize.uncompressed(annotated) == 999)

        #expect(ImageLayerSize.isGzip(MediaTypes.dockerImageLayerGzip))
        #expect(!ImageLayerSize.isGzip(MediaTypes.imageLayer))
        #expect(!ImageLayerSize.isGzip(MediaTypes.imageLayerZstd))
    }
}
