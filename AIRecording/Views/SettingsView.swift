import SwiftUI

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        Form {
            Section("录音设置") {
                Picker("录音格式", selection: $viewModel.recordingFormat) {
                    Text("CAF").tag("caf")
                    Text("WAV").tag("wav")
                }
                .pickerStyle(.segmented)

                Picker("采样率", selection: $viewModel.sampleRate) {
                    Text("44.1 kHz").tag(44100.0)
                    Text("48 kHz").tag(48000.0)
                }
                .pickerStyle(.segmented)

                Picker("声道", selection: $viewModel.channels) {
                    Text("单声道").tag(1)
                    Text("立体声").tag(2)
                }
                .pickerStyle(.segmented)

                Picker("默认录音源", selection: $viewModel.defaultAudioSource) {
                    Text("麦克风").tag(AudioSource.microphone)
                    Text("系统音频").tag(AudioSource.systemAudio)
                    Text("混合").tag(AudioSource.mixed)
                }
            }

            Section("转录设置") {
                Picker("转录引擎", selection: $viewModel.transcriptionEngine) {
                    Text("Apple 本地识别（不支持说话人分离）").tag(TranscriptionEngine.appleSpeech)
                    Text("阿里云 Fun-ASR（支持说话人分离）").tag(TranscriptionEngine.funASR)
                }

                Picker("默认语言", selection: $viewModel.transcriptionLanguage) {
                    Text("自动检测").tag("auto")
                    Text("中文").tag("zh-CN")
                    Text("英文").tag("en-US")
                }

                Toggle("增强识别模式", isOn: $viewModel.enhancedMode)

                if viewModel.transcriptionEngine == .funASR {
                    HStack {
                        Text("API Key")
                        Spacer()
                        Text(viewModel.funASRAPIKeyMasked)
                            .foregroundStyle(.secondary)
                    }

                    Picker("预估说话人数", selection: $viewModel.speakerCount) {
                        Text("自动判断").tag(0)
                        Text("2 人").tag(2)
                        Text("3 人").tag(3)
                        Text("4 人").tag(4)
                        Text("5 人").tag(5)
                        Text("6 人").tag(6)
                        Text("7 人").tag(7)
                        Text("8 人").tag(8)
                    }

                    Button("配置 Fun-ASR") {
                        showFunASRConfig = true
                    }
                }
            }

            Section("存储设置") {
                HStack {
                    Text("存储路径")
                    Spacer()
                    Text(viewModel.storagePathDisplay)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button("更改存储路径") {
                    viewModel.chooseStoragePath()
                }
            }

            Section("AI 纪要设置 (LLM)") {
                HStack {
                    Text("API 地址")
                    Spacer()
                    Text(viewModel.llmBaseURL)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Text("API Key")
                    Spacer()
                    Text(viewModel.apiKeyMasked)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("模型")
                    Spacer()
                    Text(viewModel.llmModel)
                        .foregroundStyle(.secondary)
                }

                Button("配置 LLM") {
                    showLLMConfig = true
                }
            }

            Section("知识库") {
                HStack {
                    Text("Embedding 模型")
                    Spacer()
                    Text("\(providerLabel(viewModel.knowledgeEmbeddingProvider)) · \(viewModel.knowledgeEmbeddingModel)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Text("向量维度")
                    Spacer()
                    Text(viewModel.knowledgeEmbeddingDimension > 0 ? "\(viewModel.knowledgeEmbeddingDimension)" : "自动")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Rerank 模型")
                    Spacer()
                    Text("\(providerLabel(viewModel.knowledgeRerankProvider)) · \(viewModel.knowledgeRerankModel)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button("配置检索服务") {
                    showKnowledgeModelConfig = true
                }

                Text("更改向量模型或维度后，请点击「重建知识库」使已有内容用新模型重新入库。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("已索引 \(viewModel.knowledgeDocumentCount) 条录音，\(viewModel.knowledgeChunkCount) 个片段，失败 \(viewModel.knowledgeFailedCount) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if viewModel.isKnowledgeIndexDegraded {
                    Label("知识库索引正在补全，部分结果可能不完整。", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let error = viewModel.knowledgeStatusError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("重试失败同步") {
                        Task { await viewModel.retryFailedKnowledgeSync() }
                    }
                    .disabled(viewModel.isKnowledgeOperationInProgress)
                    Button("重建知识库", role: .destructive) {
                        showKnowledgeResetConfirmation = true
                    }
                    .disabled(viewModel.isKnowledgeOperationInProgress)
                }
                if viewModel.isKnowledgeOperationInProgress {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Section("关于") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text("1.0.0")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(maxWidth: 600)
        .onAppear {
            viewModel.loadSettings()
            Task { await viewModel.loadKnowledgeStatus() }
        }
        .sheet(isPresented: $showLLMConfig) {
            LLMConfigSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showFunASRConfig) {
            FunASRConfigSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showKnowledgeModelConfig) {
            KnowledgeModelConfigSheet(viewModel: viewModel)
        }
        .alert("重建知识库？", isPresented: $showKnowledgeResetConfirmation) {
            Button("取消", role: .cancel) {}
            Button("重建", role: .destructive) {
                Task { await viewModel.resetKnowledgeIndex() }
            }
        } message: {
            Text("这会删除本机知识库索引，并在后续同步时重新建立。")
        }
    }

    @State private var showLLMConfig = false
    @State private var showFunASRConfig = false
    @State private var showKnowledgeResetConfirmation = false
    @State private var showKnowledgeModelConfig = false

    private func providerLabel(_ provider: String) -> String {
        provider == "openai" ? "OpenAI 兼容" : "阿里云百炼"
    }
}

/// 密钥输入行(所有配置弹窗统一):SecureField 以圆点显示已保存密钥,
/// 旁边的眼睛按钮在圆点与明文之间切换。
struct SecretKeyField: View {
    @Binding var text: String
    @Binding var revealed: Bool
    var prompt: String = "API Key"

    var body: some View {
        HStack(spacing: 8) {
            if revealed {
                TextField(prompt, text: $text, prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            } else {
                SecureField(prompt, text: $text, prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
            }
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealed ? "隐藏 API Key" : "查看 API Key")
        }
    }
}

struct LLMConfigSheet: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var model: String = ""
    @State private var apiKeyRevealed = false

    var body: some View {
        VStack(spacing: 20) {
            Text("LLM 配置")
                .font(.title2)
                .fontWeight(.bold)

            Form {
                TextField("API 地址", text: $baseURL)
                    .textFieldStyle(.roundedBorder)

                SecretKeyField(text: $apiKey, revealed: $apiKeyRevealed)
                    .textFieldStyle(.roundedBorder)

                TextField("模型名称", text: $model)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: 400)

            HStack(spacing: 12) {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    viewModel.llmBaseURL = baseURL
                    viewModel.llmAPIKey = apiKey
                    viewModel.llmModel = model
                    viewModel.saveSettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 480, height: 280)
        .onAppear {
            baseURL = viewModel.llmBaseURL
            apiKey = viewModel.llmAPIKey
            model = viewModel.llmModel
        }
    }
}

struct FunASRConfigSheet: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey: String = ""
    @State private var ossAccessKeyId: String = ""
    @State private var ossAccessKeySecret: String = ""
    @State private var ossBucket: String = ""
    @State private var ossEndpoint: String = ""
    @State private var apiKeyRevealed = false
    @State private var ossSecretRevealed = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Fun-ASR 配置")
                .font(.title2)
                .fontWeight(.bold)

            Form {
                Section("DashScope") {
                    SecretKeyField(text: $apiKey, revealed: $apiKeyRevealed)
                        .textFieldStyle(.roundedBorder)
                }

                Section("阿里云 OSS") {
                    TextField("AccessKey ID", text: $ossAccessKeyId)
                        .textFieldStyle(.roundedBorder)

                    SecretKeyField(text: $ossAccessKeySecret, revealed: $ossSecretRevealed, prompt: "AccessKey Secret")
                        .textFieldStyle(.roundedBorder)

                    TextField("Bucket 名称", text: $ossBucket)
                        .textFieldStyle(.roundedBorder)

                    TextField("Endpoint", text: $ossEndpoint)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .frame(maxWidth: 420)

            HStack(spacing: 12) {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    viewModel.funASRAPIKey = apiKey
                    viewModel.ossAccessKeyId = ossAccessKeyId
                    viewModel.ossAccessKeySecret = ossAccessKeySecret
                    viewModel.ossBucket = ossBucket
                    viewModel.ossEndpoint = ossEndpoint
                    viewModel.saveSettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 520, height: 420)
        .onAppear {
            apiKey = viewModel.funASRAPIKey
            ossAccessKeyId = viewModel.ossAccessKeyId
            ossAccessKeySecret = viewModel.ossAccessKeySecret
            ossBucket = viewModel.ossBucket
            ossEndpoint = viewModel.ossEndpoint
        }
    }
}

struct KnowledgeModelConfigSheet: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    private static let openAIDimensionOptions = [512, 1024, 1536, 2048, 3072]
    private static let customDimensionTag = -1

    // Embedding 服务
    @State private var embeddingProvider = "dashscope"
    @State private var embeddingAPIKeyDraft = ""
    @State private var embeddingBaseURLDraft = ""
    @State private var embeddingSelection: String = KnowledgeModelCatalog.defaultEmbeddingModel
    @State private var customEmbeddingModel = ""
    @State private var embeddingDimension = 1024
    @State private var openAIDimensionSelection = 0
    @State private var customDimensionDraft = ""

    // Rerank 服务
    @State private var rerankProvider = "dashscope"
    @State private var rerankAPIKeyDraft = ""
    @State private var rerankBaseURLDraft = ""
    @State private var rerankSelection: String = KnowledgeModelCatalog.defaultRerankModel
    @State private var customRerankModel = ""

    @State private var appliedEmbeddingProvider: String?
    @State private var appliedRerankProvider: String?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var revealEmbeddingKey = false
    @State private var revealRerankKey = false

    private var isCustomEmbeddingModel: Bool {
        embeddingSelection == KnowledgeModelCatalog.customSentinel
    }

    private var isCustomRerankModel: Bool {
        rerankSelection == KnowledgeModelCatalog.customSentinel
    }

    private var effectiveEmbeddingModelName: String {
        if embeddingProvider == "openai" { return customEmbeddingModel }
        return isCustomEmbeddingModel ? customEmbeddingModel : embeddingSelection
    }

    private var effectiveRerankModelName: String {
        if rerankProvider == "openai" { return customRerankModel }
        return isCustomRerankModel ? customRerankModel : rerankSelection
    }

    private var canSave: Bool {
        !effectiveEmbeddingModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !effectiveRerankModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && customDimensionError == nil
    }

    /// 自定义维度草稿解析:trim 后的正整数,否则 nil。
    private var customDimensionValue: Int? {
        let trimmed = customDimensionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value > 0 else { return nil }
        return value
    }

    /// 「自定义…」维度输入是否参与校验:openai 看其 picker 选择,dashscope 预设模型看维度 picker,
    /// dashscope 自定义模型的维度草稿始终参与(可留空=不指定)。
    private var isCustomDimensionActive: Bool {
        if embeddingProvider == "openai" {
            return openAIDimensionSelection == Self.customDimensionTag
        }
        if isCustomEmbeddingModel { return true }
        return embeddingDimension == Self.customDimensionTag
    }

    /// 自定义维度校验错误;nil 表示合法(或未启用自定义输入)。
    private var customDimensionError: String? {
        guard isCustomDimensionActive else { return nil }
        let trimmed = customDimensionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // dashscope 自定义模型可不填维度(留空=不传,由服务端用模型默认)。
        if embeddingProvider != "openai", isCustomEmbeddingModel, trimmed.isEmpty { return nil }
        guard let value = customDimensionValue else { return "维度需为正整数" }
        if embeddingProvider != "openai", !isCustomEmbeddingModel,
           let options = KnowledgeModelCatalog.dimensions(for: embeddingSelection),
           !options.contains(value) {
            let supported = options.sorted().map(String.init).joined(separator: "/")
            return "该模型仅支持:\(supported)"
        }
        return nil
    }

    private var embeddingKeyHint: String {
        viewModel.savedEmbeddingKey(provider: embeddingProvider).isEmpty ? "未配置" : "API Key"
    }

    private var rerankKeyHint: String {
        viewModel.savedRerankKey(provider: rerankProvider).isEmpty ? "未配置" : "API Key"
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("知识库检索服务")
                .font(.title2)
                .fontWeight(.bold)

            Form {
                Section("Embedding 服务") {
                    Picker("供应商", selection: $embeddingProvider) {
                        Text("阿里云百炼").tag("dashscope")
                        Text("OpenAI 兼容接口").tag("openai")
                    }

                    SecretKeyField(text: $embeddingAPIKeyDraft, revealed: $revealEmbeddingKey, prompt: embeddingKeyHint)
                        .textFieldStyle(.roundedBorder)

                    if embeddingProvider == "openai" {
                        TextField("Base URL", text: $embeddingBaseURLDraft, prompt: Text("https://api.siliconflow.cn/v1"))
                            .textFieldStyle(.roundedBorder)

                        TextField("模型名称", text: $customEmbeddingModel)
                            .textFieldStyle(.roundedBorder)

                        Picker("向量维度", selection: $openAIDimensionSelection) {
                            Text("自动").tag(0)
                            ForEach(Self.openAIDimensionOptions, id: \.self) { dimension in
                                Text("\(dimension)").tag(dimension)
                            }
                            Text("自定义…").tag(Self.customDimensionTag)
                        }

                        if openAIDimensionSelection == Self.customDimensionTag {
                            TextField("向量维度", text: $customDimensionDraft, prompt: Text("如 1536"))
                                .textFieldStyle(.roundedBorder)
                        }
                    } else {
                        Picker("Embedding 模型", selection: $embeddingSelection) {
                            ForEach(KnowledgeModelCatalog.embeddingModelNames, id: \.self) { model in
                                Text(model).tag(model)
                            }
                            Text("自定义…").tag(KnowledgeModelCatalog.customSentinel)
                        }

                        if isCustomEmbeddingModel {
                            TextField("模型名称", text: $customEmbeddingModel)
                                .textFieldStyle(.roundedBorder)

                            TextField("向量维度", text: $customDimensionDraft, prompt: Text("如 1536（留空不指定）"))
                                .textFieldStyle(.roundedBorder)
                        } else if let options = KnowledgeModelCatalog.dimensions(for: embeddingSelection) {
                            Picker("向量维度", selection: $embeddingDimension) {
                                ForEach(options, id: \.self) { dimension in
                                    Text("\(dimension)").tag(dimension)
                                }
                                Text("自定义…").tag(Self.customDimensionTag)
                            }

                            if embeddingDimension == Self.customDimensionTag {
                                TextField("向量维度", text: $customDimensionDraft, prompt: Text("如 1536"))
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }

                    if let error = customDimensionError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Rerank 服务") {
                    Picker("供应商", selection: $rerankProvider) {
                        Text("阿里云百炼").tag("dashscope")
                        Text("OpenAI 兼容接口").tag("openai")
                    }

                    SecretKeyField(text: $rerankAPIKeyDraft, revealed: $revealRerankKey, prompt: rerankKeyHint)
                        .textFieldStyle(.roundedBorder)

                    if rerankProvider == "openai" {
                        TextField("Base URL", text: $rerankBaseURLDraft, prompt: Text("https://api.siliconflow.cn/v1"))
                            .textFieldStyle(.roundedBorder)

                        TextField("模型名称", text: $customRerankModel)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("Rerank 模型", selection: $rerankSelection) {
                            ForEach(KnowledgeModelCatalog.rerankModelNames, id: \.self) { model in
                                Text(model).tag(model)
                            }
                            Text("自定义…").tag(KnowledgeModelCatalog.customSentinel)
                        }

                        if isCustomRerankModel {
                            TextField("模型名称", text: $customRerankModel)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            .frame(maxWidth: 420)

            Text("更改向量模型或维度后，请点击「重建知识库」使已有内容用新模型重新入库。API Key 以圆点显示当前已保存的密钥，修改后保存即更新。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    save()
                }
                .disabled(!canSave || isSaving)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)

                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding()
        .frame(width: 480)
        .onChange(of: embeddingSelection) { newValue in
            // 自定义维度(哨兵 -1)不参与预设表回退:保留「自定义…」选择,由 canSave 校验草稿。
            guard newValue != KnowledgeModelCatalog.customSentinel,
                  embeddingDimension != Self.customDimensionTag,
                  let options = KnowledgeModelCatalog.dimensions(for: newValue),
                  !options.contains(embeddingDimension) else { return }
            embeddingDimension = options[0]
        }
        .onChange(of: embeddingProvider) { newValue in
            applyEmbeddingProviderChange(newValue)
        }
        .onChange(of: rerankProvider) { newValue in
            applyRerankProviderChange(newValue)
        }
        .onAppear {
            seedFromViewModel()
        }
    }

    private func save() {
        isSaving = true
        saveError = nil
        let dimension: Int?
        if embeddingProvider == "openai" {
            dimension = openAIDimensionSelection == Self.customDimensionTag
                ? customDimensionValue
                : (openAIDimensionSelection > 0 ? openAIDimensionSelection : nil)
        } else if isCustomEmbeddingModel {
            // 自定义模型:草稿留空→nil(不指定);正整数经管理器透传。
            dimension = customDimensionValue
        } else if embeddingDimension == Self.customDimensionTag {
            // 预设模型 + 自定义维度:已在 canSave 校验为该模型表内取值。
            dimension = customDimensionValue
        } else {
            dimension = embeddingDimension
        }
        let embeddingModel = effectiveEmbeddingModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rerankModel = effectiveRerankModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let embeddingBaseURL = embeddingBaseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let rerankBaseURL = rerankBaseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let success = await viewModel.saveKnowledgeServiceSettings(
                embeddingProvider: embeddingProvider,
                embeddingModel: embeddingModel,
                embeddingDimension: dimension,
                embeddingBaseURL: embeddingBaseURL,
                embeddingAPIKey: embeddingAPIKeyDraft,
                rerankProvider: rerankProvider,
                rerankModel: rerankModel,
                rerankBaseURL: rerankBaseURL,
                rerankAPIKey: rerankAPIKeyDraft
            )
            if success {
                dismiss()
            } else {
                saveError = "密钥保存失败，请检查系统钥匙串权限。"
                isSaving = false
            }
        }
    }

    private func seedFromViewModel() {
        embeddingBaseURLDraft = viewModel.knowledgeEmbeddingBaseURL
        rerankBaseURLDraft = viewModel.knowledgeRerankBaseURL

        embeddingProvider = viewModel.knowledgeEmbeddingProvider
        rerankProvider = viewModel.knowledgeRerankProvider
        // 密钥按已存供应商预填,SecureField 直接以圆点显示;
        // 未保存时为空,保存流程仍按"空 = 不改动 Keychain"处理。
        embeddingAPIKeyDraft = viewModel.savedEmbeddingKey(provider: embeddingProvider)
        rerankAPIKeyDraft = viewModel.savedRerankKey(provider: rerankProvider)

        // 按已存供应商播种:openai 的模型名即使恰好是 DashScope 预设名也要进文本框,
        // 否则 effective*ModelName 为空、canSave 恒 false。
        let savedEmbeddingDimension = viewModel.knowledgeEmbeddingDimension
        if embeddingProvider == "openai" {
            customEmbeddingModel = viewModel.knowledgeEmbeddingModel
            // 已存 0/缺省→「自动」;匹配预设选项→选中;不匹配但 >0→「自定义…」并预填草稿。
            if savedEmbeddingDimension > 0 {
                if Self.openAIDimensionOptions.contains(savedEmbeddingDimension) {
                    openAIDimensionSelection = savedEmbeddingDimension
                } else {
                    openAIDimensionSelection = Self.customDimensionTag
                    customDimensionDraft = String(savedEmbeddingDimension)
                }
            }
        } else {
            if KnowledgeModelCatalog.dimensions(for: viewModel.knowledgeEmbeddingModel) != nil {
                embeddingSelection = viewModel.knowledgeEmbeddingModel
            } else {
                embeddingSelection = KnowledgeModelCatalog.customSentinel
                customEmbeddingModel = viewModel.knowledgeEmbeddingModel
            }
            if isCustomEmbeddingModel {
                // 自定义模型:维度可选,已存 >0 预填草稿,否则留空(不指定)。
                customDimensionDraft = savedEmbeddingDimension > 0 ? String(savedEmbeddingDimension) : ""
            } else if let options = KnowledgeModelCatalog.dimensions(for: embeddingSelection) {
                if options.contains(savedEmbeddingDimension) {
                    embeddingDimension = savedEmbeddingDimension
                } else if savedEmbeddingDimension > 0 {
                    // 已存维度不在预设表内:选中「自定义…」并预填草稿。
                    embeddingDimension = Self.customDimensionTag
                    customDimensionDraft = String(savedEmbeddingDimension)
                } else {
                    embeddingDimension = options[0]
                }
            }
        }

        if rerankProvider == "openai" {
            customRerankModel = viewModel.knowledgeRerankModel
        } else if KnowledgeModelCatalog.rerankModelNames.contains(viewModel.knowledgeRerankModel) {
            rerankSelection = viewModel.knowledgeRerankModel
        } else {
            rerankSelection = KnowledgeModelCatalog.customSentinel
            customRerankModel = viewModel.knowledgeRerankModel
        }

        appliedEmbeddingProvider = embeddingProvider
        appliedRerankProvider = rerankProvider
    }

    private func applyEmbeddingProviderChange(_ provider: String) {
        guard provider != appliedEmbeddingProvider else { return }
        revealEmbeddingKey = false
        // 切换供应商后重新按该供应商的解析规则取已存密钥:
        // 避免把 A 供应商的 Key 原样写进 B 供应商的账户。
        embeddingAPIKeyDraft = viewModel.savedEmbeddingKey(provider: provider)
        if provider == "openai" {
            customEmbeddingModel = embeddingSelection == KnowledgeModelCatalog.customSentinel
                ? customEmbeddingModel
                : embeddingSelection
            openAIDimensionSelection = Self.openAIDimensionOptions.contains(embeddingDimension)
                ? embeddingDimension
                : 0
        } else {
            let modelName = customEmbeddingModel
            if KnowledgeModelCatalog.embeddingModelNames.contains(modelName) {
                embeddingSelection = modelName
            } else {
                embeddingSelection = KnowledgeModelCatalog.customSentinel
                customEmbeddingModel = modelName
            }
            if let options = KnowledgeModelCatalog.dimensions(for: embeddingSelection),
               !options.contains(embeddingDimension) {
                embeddingDimension = options[0]
            }
        }
        appliedEmbeddingProvider = provider
    }

    private func applyRerankProviderChange(_ provider: String) {
        guard provider != appliedRerankProvider else { return }
        revealRerankKey = false
        rerankAPIKeyDraft = viewModel.savedRerankKey(provider: provider)
        if provider == "openai" {
            customRerankModel = rerankSelection == KnowledgeModelCatalog.customSentinel
                ? customRerankModel
                : rerankSelection
        } else {
            let modelName = customRerankModel
            if KnowledgeModelCatalog.rerankModelNames.contains(modelName) {
                rerankSelection = modelName
            } else {
                rerankSelection = KnowledgeModelCatalog.customSentinel
                customRerankModel = modelName
            }
        }
        appliedRerankProvider = provider
    }
}
