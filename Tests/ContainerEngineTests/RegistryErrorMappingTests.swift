import ContainerizationOCI
import Foundation
import NIOHTTP1
import Testing
@testable import ContainerEngine

struct RegistryErrorMappingTests {
    @Test func pullUnauthorizedMatchesDocker() {
        let error = RegistryClient.Error.invalidStatus(
            url: "/v2/snel/pq_exam_sys/manifests/sha-ac8c5c9",
            .unauthorized,
            reason: "access denied or wrong credentials"
        )
        let mapped = RegistryErrorMapper.map(
            error,
            reference: "ccr.ccs.tencentyun.com/snel/pq_exam_sys:sha-ac8c5c9",
            operation: .pull
        )
        #expect(
            mapped.localizedDescription
                == "pull access denied for ccr.ccs.tencentyun.com/snel/pq_exam_sys, repository does not exist or may require 'docker login'"
        )
        #expect(!mapped.localizedDescription.contains("The operation"))
        #expect(!mapped.localizedDescription.contains("error 0"))
    }

    @Test func pullForbiddenMatchesDocker() {
        let error = RegistryClient.Error.invalidStatus(url: "/v2/org/app/manifests/latest", .forbidden)
        let mapped = RegistryErrorMapper.map(error, reference: "ghcr.io/org/app:latest", operation: .pull)
        #expect(
            mapped.localizedDescription
                == "pull access denied for ghcr.io/org/app, repository does not exist or may require 'docker login'"
        )
    }

    @Test func pushUnauthorizedMatchesDocker() {
        let error = RegistryClient.Error.invalidStatus(url: "/v2/org/app/blobs/uploads/", .unauthorized)
        let mapped = RegistryErrorMapper.map(error, reference: "ghcr.io/org/app:latest", operation: .push)
        #expect(mapped.localizedDescription == "denied: requested access to the resource is denied")
    }

    @Test func otherRegistryErrorsKeepReadableDescription() {
        let error = RegistryClient.Error.invalidStatus(
            url: "/v2/library/alpine/manifests/latest",
            .notFound,
            reason: "manifest unknown"
        )
        let mapped = RegistryErrorMapper.map(error, reference: "alpine:latest", operation: .pull)
        #expect(mapped.localizedDescription.contains("404"))
        #expect(mapped.localizedDescription.contains("manifest unknown"))
        #expect(!mapped.localizedDescription.contains("The operation"))
    }

    @Test func loginUnauthorizedMatchesDocker() {
        let error = RegistryClient.Error.invalidStatus(url: "/v2/", .unauthorized, reason: "access denied or wrong credentials")
        let mapped = RegistryErrorMapper.login(error, host: "ccr.ccs.tencentyun.com", port: nil)
        #expect(
            mapped.localizedDescription
                == "Get \"https://ccr.ccs.tencentyun.com/v2/\": unauthorized: incorrect username or password"
        )
    }

    @Test func existingEngineErrorsPassThrough() {
        let original = EngineError.imageNotFound("No such image: alpine:latest")
        let mapped = RegistryErrorMapper.map(original, reference: "alpine:latest", operation: .push)
        #expect(mapped.localizedDescription == "No such image: alpine:latest")
    }
}
