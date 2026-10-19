import AppKit
import SwiftUI

struct LLMStatusPresentation: Equatable {
    let status: LLMModelStatus
    var isTransientFailure = false

    var text: String {
        switch status {
        case .ready: return "已就绪"
        case .checking: return "检查中…"
        case .incomplete: return "未就绪"
        case .failed: return isTransientFailure ? "暂不可用" : "未就绪"
        }
    }

    var systemImage: String {
        switch status {
        case .ready: return "checkmark.circle.fill"
        case .checking: return "ellipsis.circle"
        case .incomplete: return "exclamationmark.triangle.fill"
        case .failed: return isTransientFailure ? "exclamationmark.triangle.fill" : "xmark.circle.fill"
        }
    }

    var color: Color {
        switch status {
        case .ready: return .green
        case .checking: return .secondary
        case .incomplete: return .orange
        case .failed: return isTransientFailure ? .orange : .red
        }
    }

    var showsRetry: Bool { status == .incomplete || status == .failed }
}

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
            Text("请求失败后将使用内置样例检查连接。")
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

    @discardableResult
    private func trySaveAndValidate(validateAfterSave: Bool = true) -> Bool {
        let config = LLMConfig(baseURL: baseURL, model: model)

        do {
            try configStore.saveLLMConfig(config, apiKey: apiKey)
            draftTracker.loaded(draftFingerprint)
            saveError = nil
            if validateAfterSave { validationService.validate(currentValidationInput()) }
        } catch {
            saveError = "配置未保存，请检查输入及配置目录权限。"
            return false
        }

        loadModelList()
        return true
    }

    private func retryValidation() {
        guard isLoaded, saveError == nil, validationService.canRetry(currentValidationInput()) else { return }
        saveTask?.cancel()
        saveTask = nil
        // A retry saves immediately and starts one independent validation episode.
        guard trySaveAndValidate(validateAfterSave: false) else { return }
        validationService.retry(currentValidationInput())
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
        let input = currentValidationInput()
        let presentation = LLMStatusPresentation(
            status: saveError == nil ? validationService.status(for: input) : .incomplete,
            isTransientFailure: validationService.isTransientRuntimeFailure
        )
        HStack(spacing: 6) {
            statusIndicator(
                text: presentation.text,
                systemImage: presentation.systemImage,
                color: presentation.color
            )

            if presentation.showsRetry {
                Button(action: retryValidation) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(saveError != nil || !validationService.canRetry(input))
                .accessibilityLabel("重新检查模型服务")
                .help(validationService.health.isCoolingDown ? "稍后重试" : "重试")
            }
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
