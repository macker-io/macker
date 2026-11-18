import AppKit
import SwiftUI

@main
struct MackerApp: App {
    static let windowID = "manager"
    @NSApplicationDelegateAdaptor(DesktopAppDelegate.self) private var appDelegate
    @State private var model: DesktopModel

    init() {
        _model = State(initialValue: DesktopModel())
    }

    var body: some Scene {
        Window("Macker", id: Self.windowID) {
            ManagerWindow(model: model, appDelegate: appDelegate)
        }
        .defaultSize(width: 950, height: 590)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh Resources") { model.refresh() }
                    .keyboardShortcut("r")
                    .disabled(model.isRefreshing)
            }
        }
    }
}

private struct ManagerWindow: View {
    let model: DesktopModel
    let appDelegate: DesktopAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(model: model)
            .onAppear {
                let openWindow = self.openWindow
                appDelegate.configureStatusMenu(model: model) {
                    openWindow(id: MackerApp.windowID)
                }
                model.refresh()
            }
    }
}

private final class DesktopAppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: DesktopStatusMenu?

    func configureStatusMenu(model: DesktopModel, openManager: @escaping () -> Void) {
        if let statusMenu {
            statusMenu.openManager = openManager
        } else {
            statusMenu = DesktopStatusMenu(model: model, openManager: openManager)
        }
        model.startMonitoring()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
