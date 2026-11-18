import AppKit
import Foundation
import Observation

@Observable
final class DesktopModel {
    enum Connection: Equatable {
        case connecting
        case connected(version: String)
        case disconnected(reason: String)

        var title: String {
            switch self {
            case .connecting: "Connecting to Macker"
            case .connected: "Macker is Running"
            case .disconnected: "Macker is Offline"
            }
        }

        var symbol: String {
            switch self {
            case .connecting: "shippingbox"
            case .connected: "shippingbox.fill"
            case .disconnected: "exclamationmark.triangle"
            }
        }

        var isConnected: Bool {
            if case .connected = self { true } else { false }
        }
    }

    private(set) var connection: Connection = .connecting
    private(set) var isRefreshing = false
    private(set) var resources: [ResourceKind: [ResourceRow]] = [:]
    private(set) var images: [ImageRow] = []
    private(set) var imageOperation: String?
    private(set) var imageProgress: DesktopDaemonClient.ImageProgress?
    var imageError: String?
    private(set) var hasSnapshot = false
    private(set) var activity: DesktopDaemonClient.Activity?
    private(set) var activityUnavailable = false
    private(set) var fishEyeClosed = false
    // Both scenes share this selection so a menu bar shortcut opens the right row.
    var selection: ResourceKind? = .containers
    var selectedResourceID: String?
    var showsInspector = false
    var search = ""

    @ObservationIgnored private let client: DesktopDaemonClient
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var activityMonitor: Task<Void, Never>?
    @ObservationIgnored private var eyeBlink: Task<Void, Never>?

    init(client: DesktopDaemonClient = .local()) {
        self.client = client
    }

    var socketPath: String { client.socketPath }
    var runningContainers: [ResourceRow] {
        (resources[.containers] ?? []).filter(\.isRunning)
    }

    var menuRunningCount: Int {
        if activityUnavailable { return 0 }
        return activity?.runningContainers ?? (connection.isConnected ? runningContainers.count : 0)
    }

    var isBuilding: Bool { (activity?.activeBuilds ?? 0) > 0 }

    var fishAssetName: String {
        switch (menuRunningCount > 0, fishEyeClosed) {
        case (true, true): "MenuFishRunningBlink"
        case (true, false): "MenuFishRunning"
        case (false, true): "MenuFishIdleBlink"
        case (false, false): "MenuFishIdle"
        }
    }

    func startMonitoring() {
        guard monitor == nil else { return }
        let client = self.client
        activityMonitor = Task { [weak self] in
            while !Task.isCancelled {
                let delay: Duration
                do {
                    let state = try await client.activity()
                    guard !Task.isCancelled, let self else { return }
                    setActivity(state, unavailable: false)
                    delay = state == nil ? .seconds(15) : .seconds(1)
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    setActivity(nil, unavailable: true)
                    delay = .seconds(4)
                }
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                // One refresh loop for the window and menu bar; background checks are less frequent.
                let interval: Duration = NSApp?.isActive == true ? .seconds(4) : .seconds(15)
                do {
                    try await Task.sleep(for: interval)
                } catch { return }
                guard self != nil else { return }
            }
        }
    }

    private func setActivity(_ state: DesktopDaemonClient.Activity?, unavailable: Bool) {
        if activity != state { activity = state }
        if activityUnavailable != unavailable { activityUnavailable = unavailable }
        guard isBuilding else {
            eyeBlink?.cancel()
            eyeBlink = nil
            if fishEyeClosed { fishEyeClosed = false }
            return
        }
        guard eyeBlink == nil else { return }
        eyeBlink = Task { [weak self] in
            while !Task.isCancelled {
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    self?.fishEyeClosed = true
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    self?.fishEyeClosed = false
                }
                do { try await Task.sleep(for: .milliseconds(850)) } catch { return }
            }
        }
    }

    func refresh(afterCurrent: Bool = false) {
        guard !isRefreshing else {
            if afterCurrent { refreshPending = true }
            return
        }
        isRefreshing = true
        let client = self.client
        request = Task { [weak self] in
            do {
                let snapshot = try await client.snapshot()
                guard !Task.isCancelled, let self else { return }
                resources = Dictionary(uniqueKeysWithValues: ResourceKind.allCases.map { ($0, snapshot.rows(for: $0)) })
                images = snapshot.imageRows()
                hasSnapshot = true
                finishRefresh()
            } catch {
                guard !Task.isCancelled, let self else { return }
                connection = .disconnected(reason: error.localizedDescription)
                finishRefresh()
            }
        }
    }

    private func finishRefresh() {
        isRefreshing = false
        if refreshPending {
            refreshPending = false
            refresh()
        }
    }

    func performImageOperation(_ operation: DesktopDaemonClient.ImageOperation) {
        guard connection.isConnected, imageOperation == nil else { return }
        imageError = nil
        imageProgress = nil
        imageOperation = operation.title
        let client = self.client
        let updateProgress: @Sendable (DesktopDaemonClient.ImageProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.imageOperation == operation.title else { return }
                self.imageProgress = progress
            }
        }
        Task { [weak self] in
            do {
                try await client.perform(operation, onProgress: updateProgress)
            } catch {
                self?.imageError = error.localizedDescription
            }
            self?.imageProgress = nil
            self?.imageOperation = nil
            self?.refresh(afterCurrent: true)
        }
    }

    func showContainer(_ id: String) {
        selection = .containers
        search = ""
        selectedResourceID = id
        showsInspector = true
    }

    deinit {
        monitor?.cancel()
        request?.cancel()
        activityMonitor?.cancel()
        eyeBlink?.cancel()
    }
}
