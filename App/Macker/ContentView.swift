import SwiftUI

struct ContentView: View {
    @Bindable var model: DesktopModel

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(ResourceKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.symbol)
                        .tag(kind)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Macker")
            .navigationSplitViewColumnWidth(min: 150, ideal: 175)
            .safeAreaInset(edge: .bottom) {
                Label(model.connection.title, systemImage: model.connection.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        } detail: {
            if let kind = model.selection {
                resourceDetail(kind)
                    .id(kind)
                    .navigationTitle(kind.title)
            } else {
                ContentUnavailableView("Choose a Resource", systemImage: "sidebar.left")
            }
        }
        .frame(minWidth: 660, minHeight: 400)
    }

    private var sidebarSelection: Binding<ResourceKind?> {
        Binding(get: { model.selection }, set: { kind in
            guard kind != model.selection else { return }
            model.selection = kind
            model.selectedResourceID = nil
            model.search = ""
        })
    }

    private func resourceDetail(_ kind: ResourceKind) -> some View {
        let rows = model.resources[kind] ?? []
        let filtered = rows.filter { $0.matches(model.search) }
        return VStack(spacing: 0) {
            if case .disconnected = model.connection, model.hasSnapshot {
                Label("Offline — showing the last loaded resources.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                Divider()
            }
            Group {
                if case .disconnected(let reason) = model.connection, !model.hasSnapshot {
                    offlineView(reason)
                } else if !model.hasSnapshot {
                    ProgressView("Connecting to Macker…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    if kind == .images {
                        ImagesView(model: model)
                    } else {
                        ResourceTable(
                            kind: kind, rows: filtered, searching: !model.search.isEmpty,
                            selection: $model.selectedResourceID
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $model.search, prompt: "Search \(kind.title)")
        .toolbar {
            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh resources")
            .disabled(model.isRefreshing)

            Button {
                model.showsInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Toggle inspector")
        }
        .inspector(isPresented: $model.showsInspector) {
            ResourceInspector(row: kind == .images
                ? model.images.first { $0.id == model.selectedResourceID }?.inspectorRow
                : filtered.first { $0.id == model.selectedResourceID })
                .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
        }
    }

    private func offlineView(_ reason: String) -> some View {
        ContentUnavailableView {
            Label("Macker is Offline", systemImage: "shippingbox")
        } description: {
            VStack(spacing: 8) {
                Text("Start mackerd to manage local resources, then try again.")
                Text(reason)
                Text(model.socketPath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        } actions: {
            Button("Try Again") { model.refresh() }
                .disabled(model.isRefreshing)
        }
    }
}

private struct ResourceTable: View {
    let kind: ResourceKind
    let rows: [ResourceRow]
    let searching: Bool
    @Binding var selection: String?
    @State private var order = [KeyPathComparator(\ResourceRow.name)]

    var body: some View {
        Table(rows.sorted(using: order), selection: $selection, sortOrder: $order) {
            TableColumn(kind.columnTitle, value: \.name)
                .width(min: 130, ideal: 215)
            TableColumn(kind.secondColumn, value: \.secondary)
                .width(min: 70, ideal: 140)
            TableColumn(kind.thirdColumn, value: \.tertiary)
                .width(min: 90, ideal: 190)
        }
        .overlay {
            if rows.isEmpty {
                if searching {
                    ContentUnavailableView.search
                } else {
                    ContentUnavailableView("No \(kind.title)", systemImage: kind.symbol)
                }
            }
        }
    }
}

private struct ResourceInspector: View {
    let row: ResourceRow?

    var body: some View {
        if let row {
            Form {
                Section(row.name) {
                    ForEach(row.details) { detail in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(detail.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(detail.value)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.right")
        }
    }
}
