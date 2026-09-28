import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PersonalDictionarySettingsView: View {
    private enum Layout {
        static let workspaceWidth: CGFloat = 440
        static let listHeight: CGFloat = 280
        static let accessoryHeight: CGFloat = 30
        static let searchWidth: CGFloat = 180
        // Space between the fading viewport edge and the surrounding controls.
        static let listSpacing: CGFloat = 16
        static let edgeFadeHeight: CGFloat = 12
        static let stackSpacing: CGFloat = 7
    }

    @State private var viewModel: PersonalDictionaryViewModel
    @State private var searchText = ""
    @State private var selectedEntryID: String?
    @FocusState private var isListFocused: Bool
    @State private var editorMode: DictionaryEditorMode?
    @State private var pendingScrollTargetID: String?
    @State private var entryFrames: [String: CGRect] = [:]
    @State private var statusMessage: String?
    @State private var alertMessage: String?
    @State private var statusTask: Task<Void, Never>?

    init(dictionaryStore: PersonalDictionaryStore) {
        _viewModel = State(wrappedValue: PersonalDictionaryViewModel(store: dictionaryStore))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.listSpacing) {
            header
            listContainer
            VStack(alignment: .leading, spacing: Layout.stackSpacing) {
                toolbar
                footer
            }
        }
        .frame(width: Layout.workspaceWidth)
        .frame(width: SettingsFormLayout.contentWidth, alignment: .center)
        .sheet(item: $editorMode, onDismiss: { viewModel.errorMessage = nil }) { mode in
            DictionaryEntryEditorSheet(
                mode: mode,
                errorMessage: viewModel.errorMessage,
                onSubmit: { submitEditor(mode: mode, term: $0) },
                onDismiss: { editorMode = nil }
            )
        }
        .alert("词典操作失败", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("好", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .onChange(of: viewModel.entries) {
            reconcileSelection()
        }
        .onChange(of: viewModel.selectedFilter) { reconcileSelection() }
        .onChange(of: searchText) { reconcileSelection() }
        .onDisappear {
            statusTask?.cancel()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Picker("词条分类", selection: $viewModel.selectedFilter) {
                ForEach(DictionaryFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.regular)
            .labelsHidden()
            .fixedSize()

            Spacer(minLength: 8)

            SettingsTextInputField(
                text: $searchText,
                width: Layout.searchWidth,
                placeholder: "搜索词条…"
            )
            .help("搜索词条")
            .accessibilityLabel("搜索词条")
        }
        .frame(width: Layout.workspaceWidth, alignment: .leading)
    }

    private var listContainer: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                DictionaryTagLayout(spacing: 8) {
                    ForEach(displayedEntries) { entry in
                        DictionaryTagView(
                            term: entry.term,
                            isAutoLearned: entry.source == .autoLearned,
                            isSelected: selectedEntryID == entry.id,
                            onSelect: { selectedEntryID = entry.id; isListFocused = true },
                            onEdit: { editorMode = .edit(entry) },
                            onDelete: { delete(entry) }
                        )
                        .id(entry.id)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: DictionaryEntryFramesKey.self,
                                    value: [entry.id: geometry.frame(in: .named("dictionaryViewport"))]
                                )
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // Keep the first and last rows clear when scrolled to either end.
                .padding(.vertical, Layout.edgeFadeHeight)
                .mask(alignment: .topLeading) { listContentMask }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isListFocused)
            .onChange(of: selectedEntryID) {
                if selectedEntryID != nil {
                    isListFocused = true
                }
            }
            .frame(width: Layout.workspaceWidth, height: Layout.listHeight)
            .coordinateSpace(name: "dictionaryViewport")
            .onPreferenceChange(DictionaryEntryFramesKey.self) { entryFrames = $0 }
            .onDeleteCommand(perform: deleteSelection)
            .onKeyPress(.return) { handleReturnKey() }
            .onKeyPress(.leftArrow) { moveSelection(by: -1, proxy: proxy) }
            .onKeyPress(.rightArrow) { moveSelection(by: 1, proxy: proxy) }
            .overlay {
                if viewModel.entries.isEmpty {
                    dictionaryEmptyState
                        .allowsHitTesting(false)
                } else if displayedEntries.isEmpty {
                    searchEmptyState
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: pendingScrollTargetID) {
                guard let targetID = pendingScrollTargetID else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(targetID, anchor: .center)
                    pendingScrollTargetID = nil
                }
            }
            .accessibilityLabel("词条列表")
        }
    }

    // Keep the fade fixed to the viewport while masking only the scrolling tags.
    // The native scroll indicator is a sibling of this content and stays unmasked.
    private var listContentMask: some View {
        GeometryReader { geometry in
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: Layout.edgeFadeHeight / Layout.listHeight),
                    .init(color: .black, location: 1 - Layout.edgeFadeHeight / Layout.listHeight),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Layout.listHeight)
            .offset(y: -geometry.frame(in: .named("dictionaryViewport")).minY)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            DictionaryAccessoryControl(
                canRemove: selectedEntryID != nil,
                onAdd: {
                    viewModel.errorMessage = nil
                    editorMode = .add
                },
                onRemove: deleteSelection,
                onImport: importDictionary,
                onExport: exportDictionary
            )

            ZStack {
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)

            Text("\(displayedEntries.count) 个词条")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(displayedEntries.count) 个词条")
        }
        .frame(height: Layout.accessoryHeight)
    }

    private var footer: some View {
        Text("双击标签可编辑，点击 × 删除。蓝点表示自动学习的词。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: Layout.workspaceWidth, alignment: .leading)
    }

    private var dictionaryEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("还没有词条")
            Text("点击添加常用人名、产品名或专业术语，也可以从文件导入。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Layout.workspaceWidth - 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var searchEmptyState: some View {
        Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无\(viewModel.selectedFilter.title)的词条" : "未找到词条")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var displayedEntries: [DictionaryEntry] {
        viewModel.filteredEntries(matching: searchText)
    }

    private var selectedEntry: DictionaryEntry? {
        guard let selectedEntryID else { return nil }
        return displayedEntries.first(where: { $0.id == selectedEntryID })
    }

    private func handleReturnKey() -> KeyPress.Result {
        guard editorMode == nil, let selectedEntry else { return .ignored }
        editorMode = .edit(selectedEntry)
        return .handled
    }

    private func moveSelection(by offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard editorMode == nil, !displayedEntries.isEmpty else { return .ignored }
        let entries = displayedEntries
        let nextIndex: Int
        if let current = entries.firstIndex(where: { $0.id == selectedEntryID }) {
            nextIndex = min(max(current + offset, 0), entries.count - 1)
        } else {
            nextIndex = offset > 0 ? 0 : entries.count - 1
        }
        let targetID = entries[nextIndex].id
        selectedEntryID = targetID
        if let frame = entryFrames[targetID] {
            // Scroll only far enough to clear the fade, keeping visible rows still.
            let anchorInset = Layout.edgeFadeHeight / max(1, Layout.listHeight - frame.height)
            if frame.minY < Layout.edgeFadeHeight - 0.5 {
                proxy.scrollTo(targetID, anchor: UnitPoint(x: 0.5, y: anchorInset))
            } else if frame.maxY > Layout.listHeight - Layout.edgeFadeHeight + 0.5 {
                proxy.scrollTo(targetID, anchor: UnitPoint(x: 0.5, y: 1 - anchorInset))
            }
        }
        return .handled
    }

    @discardableResult
    private func submitEditor(mode: DictionaryEditorMode, term: String) -> Bool {
        switch mode {
        case .add:
            guard viewModel.addTerm(term) else { return false }
            revealEntry(matching: term)
            return true
        case .edit(let entry):
            guard viewModel.commitTermUpdate(id: entry.id, term: term) else { return false }
            revealEntry(id: entry.id, matching: term)
            return true
        }
    }

    private func revealEntry(id: String? = nil, matching term: String) {
        let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty, !normalized.localizedCaseInsensitiveContains(query) {
            searchText = ""
        }

        let targetID = id ?? viewModel.entries.first(where: { $0.term == normalized })?.id
        if let entry = viewModel.entries.first(where: { $0.id == targetID }), !viewModel.selectedFilter.includes(entry) {
            viewModel.selectedFilter = entry.source == .manual ? .manualAdded : .autoAdded
        }
        selectedEntryID = targetID
        pendingScrollTargetID = targetID
    }

    private func deleteSelection() {
        guard let selectedEntryID,
              let entry = displayedEntries.first(where: { $0.id == selectedEntryID }) else { return }
        delete(entry)
    }

    private func delete(_ entry: DictionaryEntry) {
        let nextSelection = viewModel.neighboringEntryID(afterDeleting: entry.id, matching: searchText)
        guard viewModel.deleteEntry(entry) else {
            presentAlert(viewModel.errorMessage ?? PersonalDictionaryViewModel.ValidationError.saveFailed.rawValue)
            return
        }
        selectedEntryID = nextSelection
    }

    private func reconcileSelection() {
        if let selectedEntryID, displayedEntries.contains(where: { $0.id == selectedEntryID }) == false {
            self.selectedEntryID = nil
        }
    }

    private func importDictionary() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.prompt = "导入"
        panel.message = "选择 UTF-8 CSV 文件，每行一个词，无表头。导入词归为手动添加。"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.importEntries(from: url)
        if viewModel.errorMessage == nil {
            viewModel.selectedFilter = .manualAdded
            searchText = ""
        }
        presentOperationResult()
    }

    private func exportDictionary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "memoecho-dictionary.csv"
        panel.prompt = "导出"
        panel.message = "导出全部词条为 CSV，每行一个词，无表头。"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.exportEntries(to: url)
        presentOperationResult()
    }

    private func presentOperationResult() {
        if let errorMessage = viewModel.errorMessage {
            presentAlert(errorMessage)
            return
        }
        showStatus(viewModel.statusMessage)
    }

    private func presentAlert(_ message: String) {
        alertMessage = message
        statusMessage = nil
    }

    private func showStatus(_ message: String?) {
        statusTask?.cancel()
        withAnimation(.easeInOut(duration: 0.16)) {
            statusMessage = message
        }
        guard message != nil else { return }
        statusTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                statusMessage = nil
            }
        }
    }
}

private struct DictionaryEntryFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
