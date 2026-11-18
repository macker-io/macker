import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImagesView: View {
    @Bindable var model: DesktopModel

    private enum Usage: String, CaseIterable {
        case all = "All"
        case inUse = "In Use"
        case unused = "Unused"

        func includes(_ image: ImageRow) -> Bool {
            self == .all || (self == .inUse) == image.inUse
        }
    }

    private enum SortOrder: String, CaseIterable {
        case newest = "Newest First"
        case oldest = "Oldest First"
        case name = "Name"
        case largest = "Largest First"

        func precedes(_ lhs: ImageRow, _ rhs: ImageRow) -> Bool {
            switch self {
            case .newest, .oldest:
                if lhs.createdAt != rhs.createdAt {
                    guard let left = lhs.createdAt else { return false }
                    guard let right = rhs.createdAt else { return true }
                    return self == .newest ? left > right : left < right
                }
            case .name:
                let comparison = lhs.name.localizedStandardCompare(rhs.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                let tagComparison = lhs.tag.localizedStandardCompare(rhs.tag)
                if tagComparison != .orderedSame { return tagComparison == .orderedAscending }
            case .largest:
                if lhs.size != rhs.size { return lhs.size > rhs.size }
            }
            return lhs.id < rhs.id
        }
    }

    private enum AddImage: String, Identifiable {
        case pull, rootfs
        var id: Self { self }
    }

    private struct Deletion {
        let reference: String
        let isTag: Bool
    }

    @State private var usage = Usage.all
    @State private var sort = SortOrder.newest
    @State private var addImage: AddImage?
    @State private var rootfsArchive: URL?
    @State private var deletion: Deletion?

    private var canModify: Bool { model.connection.isConnected && model.imageOperation == nil }
    private var selected: ImageRow? { rows.first { $0.id == model.selectedResourceID } }
    private var rows: [ImageRow] {
        model.images.filter { usage.includes($0) && $0.matches(model.search) }
            .sorted(by: sort.precedes)
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()

            if let operation = model.imageOperation {
                HStack(spacing: 10) {
                    if let fraction = model.imageProgress?.fraction {
                        ProgressView(value: fraction).frame(width: 90)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.imageProgress?.message ?? operation)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.callout)
                .padding(10)
                Divider()
            }

            imageList
        }
        .onChange(of: rows.map(\.id)) { _, ids in
            if let selected = model.selectedResourceID, !ids.contains(selected) {
                model.selectedResourceID = nil
            }
        }
        .sheet(item: $addImage) { kind in
            ImageSourceSheet(archive: kind == .rootfs ? rootfsArchive : nil) { operation in
                model.performImageOperation(operation)
            }
        }
        .alert(
            deletion?.isTag == true ? "Remove Image Tag?" : "Delete Image?",
            isPresented: deletionPresented,
            presenting: deletion
        ) { item in
            Button("Cancel", role: .cancel) {}
            Button(item.isTag ? "Remove Tag" : "Delete", role: .destructive) {
                model.performImageOperation(.delete(item.reference))
            }
        } message: { item in
            Text(item.reference)
        }
        .alert("Image Operation Failed", isPresented: errorPresented) {
            Button("OK") { model.imageError = nil }
        } message: {
            Text(model.imageError ?? "")
        }
    }

    private var deletionPresented: Binding<Bool> {
        Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { model.imageError != nil }, set: { if !$0 { model.imageError = nil } })
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                usagePicker
                imageCount
                Spacer(minLength: 0)
                controlMenus
            }
            HStack(spacing: 10) {
                usagePicker
                Spacer(minLength: 0)
                controlMenus
                    .labelStyle(.iconOnly)
            }
            VStack(alignment: .leading, spacing: 8) {
                usagePicker
                HStack {
                    imageCount
                    Spacer(minLength: 0)
                    controlMenus.labelStyle(.iconOnly)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var usagePicker: some View {
        Picker("Usage", selection: $usage) {
            ForEach(Usage.allCases, id: \.self) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var imageCount: some View {
        Text(rows.count == 1 ? "1 image" : "\(rows.count) images")
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize()
    }

    private var controlMenus: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(SortOrder.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                Divider()
                if let selected { imageActions(selected) }
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
            }
            .help("Sort images or manage the selected image")

            Menu {
                Button("Pull from Registry…", systemImage: "arrow.down.circle") { addImage = .pull }
                Button("Load Image Archive…", systemImage: "archivebox") {
                    if let file = chooseArchive() { model.performImageOperation(.load(file)) }
                }
                Button("Import Root Filesystem…", systemImage: "folder.badge.plus") {
                    if let file = chooseArchive() {
                        rootfsArchive = file
                        addImage = .rootfs
                    }
                }
            } label: {
                Label("Add Image", systemImage: "plus")
            }
            .disabled(!canModify)
            .help("Pull or import an image")
        }
        .fixedSize()
    }

    private var imageList: some View {
        let rows = self.rows
        let lastID = rows.last?.id
        return List(rows, selection: $model.selectedResourceID) { image in
            ImageListRow(image: image)
                .listRowSeparator(.hidden)
                .overlay(alignment: .bottom) {
                    if image.id != lastID {
                        Divider()
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                // Keep padding inside the row so the divider meets the native selection edge.
                .listRowInsets(.vertical, 0)
                .tag(image.id)
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { selection in
            if let id = selection.first, let image = rows.first(where: { $0.id == id }) {
                imageActions(image)
            }
        } primaryAction: { selection in
            if let id = selection.first {
                model.selectedResourceID = id
                model.showsInspector = true
            }
        }
        .overlay {
            if rows.isEmpty {
                if !model.search.isEmpty {
                    ContentUnavailableView.search
                } else {
                    ContentUnavailableView("No \(usage == .all ? "" : usage.rawValue + " ")Images", systemImage: "square.stack")
                }
            }
        }
    }

    @ViewBuilder private func imageActions(_ image: ImageRow) -> some View {
        if image.references.count == 1, let reference = image.references.first {
            Button("Copy Tag") { copy(reference.id) }
        } else if !image.references.isEmpty {
            Menu("Copy Tag") {
                ForEach(image.references) { reference in
                    Button(reference.id) { copy(reference.id) }
                }
            }
        }
        Button("Copy Image ID") { copy(image.id) }
        Divider()
        Button("Export…") { export(image) }
            .disabled(!canModify)
        if image.references.count > 1 {
            Menu("Remove Tag") {
                ForEach(image.references) { reference in
                    Button(reference.id, role: .destructive) {
                        deletion = Deletion(reference: reference.id, isTag: true)
                    }
                }
            }
            .disabled(!canModify || image.inUse)
        } else {
            Button("Delete…", role: .destructive) {
                deletion = Deletion(reference: image.references.first?.id ?? image.id, isTag: false)
            }
            .disabled(!canModify || image.inUse)
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func chooseArchive() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.tarArchive, .gzip]
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func export(_ image: ImageRow) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tarArchive]
        let leaf = image.references.first?.name.split(separator: "/").last.map(String.init) ?? image.shortID
        panel.nameFieldStringValue = "\(leaf).tar"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        model.performImageOperation(.export(references: image.exportReferences, platform: image.platform, destination: destination))
    }
}

struct ImageListRow: View {
    let image: ImageRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "square.stack")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(image.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(image.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    usageStatus
                }

                metadata
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(image.shortID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .help(image.id)
                    .accessibilityLabel("Image ID \(image.shortID)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var metadata: some View {
        if image.references.isEmpty && image.platform == nil {
            sizeAndAge
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    tagAndPlatform.fixedSize(horizontal: true, vertical: false)
                    separator
                    sizeAndAge.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 3) {
                    tagAndPlatform
                    sizeAndAge
                }
            }
        }
    }

    private var tagAndPlatform: some View {
        HStack(spacing: 6) {
            if !image.references.isEmpty {
                Text(image.tag)
                    .lineLimit(1)
                    .help(image.references.map(\.id).joined(separator: "\n"))
                    .accessibilityLabel("Tag \(image.tag)")
                if image.platform != nil { separator }
            }
            if let platform = image.platform {
                Text(platform)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }

    private var sizeAndAge: some View {
        HStack(spacing: 6) {
            Text(ByteCountFormatter.string(fromByteCount: image.size, countStyle: .file))
                .monospacedDigit()
            if let date = image.createdAt {
                separator
                Text(date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                    .help(date.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .lineLimit(1)
    }

    private var separator: some View {
        Text("·").accessibilityHidden(true)
    }

    private var usageStatus: some View {
        Label(image.inUse ? "In Use" : "Unused", systemImage: image.inUse ? "circle.fill" : "circle")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize()
            .help("\(image.containerCount) containers reference this image, including stopped containers.")
    }
}

private struct ImageSourceSheet: View {
    let archive: URL?
    let submit: (DesktopDaemonClient.ImageOperation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reference = ""
    @State private var platform = ""
    @State private var customPlatform = ""
    @State private var tag = ""

    private var name: String { reference.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var selectedPlatform: String? {
        let value = (platform == "custom" ? customPlatform : platform).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(archive == nil ? "Pull Image" : "Import Root Filesystem").font(.headline)
            Form {
                if let archive {
                    LabeledContent("Archive", value: archive.lastPathComponent)
                    TextField("Repository", text: $reference, prompt: Text("my-image"))
                    TextField("Tag", text: $tag, prompt: Text("latest"))
                    TextField("Platform", text: $platform, prompt: Text("Daemon default"))
                } else {
                    TextField("Image", text: $reference, prompt: Text("alpine:3.24"))
                    Picker("Platform", selection: $platform) {
                        Text("Daemon Default").tag("")
                        Text("linux/arm64").tag("linux/arm64")
                        Text("linux/amd64").tag("linux/amd64")
                        Text("Custom…").tag("custom")
                    }
                    if platform == "custom" {
                        TextField("Custom Platform", text: $customPlatform, prompt: Text("linux/arm/v7"))
                    }
                }
            }
            Text(archive == nil
                ? "A reference without a tag pulls latest. Pulling a platform does not guarantee it can run locally."
                : "Imports a filesystem tar as a new image. For an exported image, use Load Image Archive instead.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(archive == nil ? "Pull" : "Import") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || (platform == "custom" && selectedPlatform == nil))
            }
        }
        .padding(20)
        .frame(width: 410)
    }

    private func confirm() {
        if let archive {
            let trimmedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            submit(.importRootfs(archive, repository: name, tag: trimmedTag.isEmpty ? "latest" : trimmedTag, platform: selectedPlatform))
        } else {
            submit(.pull(reference: name, platform: selectedPlatform))
        }
        dismiss()
    }
}
