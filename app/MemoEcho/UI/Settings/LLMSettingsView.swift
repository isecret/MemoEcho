import AppKit
import SwiftUI

struct LLMSettingsView: View {
    let configStore: ConfigStore
    let modelListService: LLMModelListService
    let validationService: LLMValidationService

    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var model: String = ""
    @State private var isLoaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var draftTracker = SettingsDraftTracker()
    @State private var saveError: String?

    var body: some View {
        SettingsPaneSection {
            SettingsFormRow(title: "Base URL") {
                SettingsTextInputField(text: $baseURL)
            }
            SettingsFormRow(title: "API Key") {
                SettingsSecureInputField(text: $apiKey)
            }
            SettingsFormRow(title: "Model") {
                HStack(spacing: 8) {
                    SettingsTextInputField(text: $model, width: 334)
                    modelListAccessory
                        .frame(width: 18, height: 18)
                }
            }
            SettingsFormRow(title: "模型状态") {
                VStack(alignment: .leading, spacing: 4) {
                    validationStatusView

                    if let saveError {
                        Text(saveError).font(.caption).foregroundStyle(.red)
                    }

                    if let errorMessage = validationService.lastErrorMessage,
                       validationService.status(for: currentValidationInput()) == .failed {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .frame(width: SettingsFormLayout.controlWidth, alignment: .leading)
                    }
                }
            }
        } footer: {
            Text("支持 OpenAI 兼容接口，用于整理和翻译语音识别结果。")
        }
        .onAppear {
            loadDraft()
            isLoaded = true
            loadModelList()
            validationService.validate(currentValidationInput())
        }
        .onDisappear { flushPendingSave() }
        .onChange(of: baseURL) { debouncedSave() }
        .onChange(of: apiKey) { debouncedSave() }
        .onChange(of: model) { debouncedSave() }
    }

    private func loadDraft() {
        baseURL = configStore.llmConfig.baseURL
        apiKey = configStore.openAIAPIKey
        model = configStore.llmConfig.model
        draftTracker.loaded(draftFingerprint)
    }

    private func debouncedSave() {
        guard isLoaded else { return }
        saveTask?.cancel()
        guard draftTracker.changed(to: draftFingerprint) else { return }
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            trySaveAndValidate()
        }
    }

    private func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        if isLoaded, draftTracker.hasPendingChanges { trySaveAndValidate() }
    }

    private func trySaveAndValidate() {
        let config = LLMConfig(baseURL: baseURL, model: model)

        do {
            try configStore.saveLLMConfig(config, apiKey: apiKey)
            draftTracker.loaded(draftFingerprint)
            saveError = nil
            validationService.validate(currentValidationInput())
        } catch {
            saveError = "配置未保存，请检查输入及配置目录权限。"
        }

        loadModelList()
    }

    private var draftFingerprint: String {
        var input = currentValidationInput()
        input.omitThinkingParameter = false
        return input.fingerprint
    }

    private func currentValidationInput() -> LLMValidationInput {
        LLMValidationInput(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            omitThinkingParameter: configStore.omitThinkingParameter
        )
    }

    private func currentModelListInput() -> LLMModelListInput {
        LLMModelListInput(
            baseURL: baseURL,
            apiKey: apiKey
        )
    }

    private func loadModelList(force: Bool = false) {
        modelListService.load(currentModelListInput(), force: force)
    }

    @ViewBuilder
    private var modelListAccessory: some View {
        switch modelListService.status {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("正在获取模型列表")
                .help("正在获取模型列表")
        case .incomplete, .loaded, .unavailable:
            ModelListPickerButton(
                models: modelListService.models,
                help: "选择模型",
                onSelect: { model = $0 }
            )
        }
    }

    @ViewBuilder
    private var validationStatusView: some View {
        switch validationService.status(for: currentValidationInput()) {
        case .incomplete:
            statusIndicator(
                text: "未就绪",
                systemImage: "exclamationmark.triangle.fill",
                color: .orange
            )
        case .checking:
            statusIndicator(text: "验证中…", systemImage: "ellipsis.circle", color: .secondary)
        case .ready:
            statusIndicator(
                text: "已就绪",
                systemImage: "checkmark.circle.fill",
                color: .green
            )
        case .failed:
            statusIndicator(
                text: "未就绪",
                systemImage: "xmark.circle.fill",
                color: .red
            )
        }
    }

    @ViewBuilder
    private func statusIndicator(text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .foregroundStyle(color)
    }
}

private struct ModelListPickerButton: NSViewRepresentable {
    let models: [String]
    let help: String
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(models: models, onSelect: onSelect)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = Self.chevronImage()
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.setButtonType(.momentaryChange)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.models = models
        context.coordinator.onSelect = onSelect
        nsView.isEnabled = true
        nsView.toolTip = help
        nsView.contentTintColor = .secondaryLabelColor
    }

    private static func chevronImage() -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        return NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "选择模型")?
            .withSymbolConfiguration(configuration)
    }

    final class Coordinator: NSObject {
        var models: [String]
        var onSelect: (String) -> Void

        init(models: [String], onSelect: @escaping (String) -> Void) {
            self.models = models
            self.onSelect = onSelect
        }

        @MainActor
        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()

            if models.isEmpty {
                let item = NSMenuItem(title: "未获取到模型列表，可手动输入模型名称", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            } else {
                for model in models {
                    let item = NSMenuItem(title: model, action: #selector(selectModel(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = model
                    menu.addItem(item)
                }
            }

            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
        }

        @MainActor
        @objc private func selectModel(_ sender: NSMenuItem) {
            guard let model = sender.representedObject as? String else { return }
            onSelect(model)
        }
    }
}
