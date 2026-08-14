import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var draftAutoSyncIntervalHours = 2
    @State private var toolAvailability: [AIProvider: Bool] = [:]
    @State private var draggingProvider: AIProvider?
    @State private var editingCustomProvider: CustomAIProviderConfig?
    @State private var showingNewCustomProvider = false

    private var hasUnsavedAutoSyncInterval: Bool {
        draftAutoSyncIntervalHours != appState.clampedAutoSyncIntervalHours
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("设置")
                        .font(.system(size: 25, weight: .bold))
                    Text("配置知识库、AI 工具和主题")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                settingsSection("外观") {
                    LabeledContent("主题") {
                        Picker("主题", selection: $appState.themePreference) {
                            ForEach(ThemePreference.allCases) { theme in Text(theme.rawValue).tag(theme) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 300)
                    }
                }

                settingsSection("知识库") {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("工单查询地址")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("https://kb.example.com/issues?...", text: $appState.knowledgeBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { appState.persistState() }
                        HStack {
                            syncDescription
                            Spacer()
                            Button("登录或检查会话") { appState.showingKnowledgeBaseSession = true }
                                .buttonStyle(SecondaryButtonStyle())
                            Button("立即同步") {
                                Task { await appState.knowledgeBaseSession.sync(using: appState, background: true) }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        }
                    }

                    Divider()

                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自动同步间隔")
                                .font(.system(size: 13, weight: .medium))
                            Text("应用会先显示缓存工单，再按此间隔在后台更新。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 16)

                        Picker("自动同步间隔", selection: $draftAutoSyncIntervalHours) {
                            ForEach(1...8, id: \.self) { hours in
                                Text("每 \(hours) 小时").tag(hours)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 116)

                        Button("保存") {
                            appState.autoSyncIntervalHours = draftAutoSyncIntervalHours
                            appState.persistState()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!hasUnsavedAutoSyncInterval)
                    }
                }

                settingsSection("AI 工具") {
                    HStack {
                        Text("已安装的工具可拖动排序，工单详情中的 AI 工具会使用同一顺序。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            showingNewCustomProvider = true
                        } label: {
                            Label("新增自定义", systemImage: "plus")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }

                    ForEach(Array(appState.orderedAIProviders.enumerated()), id: \.element) { index, provider in
                        if index > 0 {
                            Divider()
                        }
                        toolRow(provider)
                    }

                    ForEach(appState.customAIProviders) { provider in
                        Divider()
                        customProviderRow(provider)
                    }
                }

                settingsSection("测试模式") {
                    Toggle(isOn: Binding(
                        get: { appState.isTestModeEnabled },
                        set: {
                            appState.isTestModeEnabled = $0
                            appState.persistState()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("启用测试模式")
                                .font(.system(size: 13, weight: .medium))
                            Text("可新建本地测试工单并选择类型（Bug / 需求等）；跳过知识库更新，同步时保留假工单。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DevFlowTheme.canvas(colorScheme))
        .onAppear {
            draftAutoSyncIntervalHours = appState.clampedAutoSyncIntervalHours
        }
        .onDisappear {
            appState.persistState()
        }
        .task {
            var availability: [AIProvider: Bool] = [:]
            for provider in AIProvider.allCases {
                availability[provider] = await ProcessRunner.commandExists(provider.command)
            }
            toolAvailability = availability
        }
        .sheet(isPresented: $showingNewCustomProvider) {
            CustomAIProviderEditor(provider: nil) { config, key in
                appState.customAIProviders.append(config)
                AgentCredentialStore.saveAPIKey(key, for: config.id)
                appState.persistState()
            }
            .frame(width: 580, height: 500)
        }
        .sheet(item: $editingCustomProvider) { provider in
            CustomAIProviderEditor(provider: provider) { config, key in
                if let index = appState.customAIProviders.firstIndex(where: { $0.id == config.id }) {
                    appState.customAIProviders[index] = config
                }
                AgentCredentialStore.saveAPIKey(key, for: config.id)
                appState.persistState()
            }
            .frame(width: 580, height: 500)
        }
    }

    private var syncDescription: some View {
        Group {
            switch appState.syncStatus {
            case .idle: StatusDot(color: .secondary, text: "尚未同步")
            case .syncing: StatusDot(color: DevFlowTheme.accent, text: "正在同步")
            case let .synced(date): StatusDot(color: DevFlowTheme.success, text: "已同步 · \(date.devFlowRelativeText)")
            case .loginRequired: StatusDot(color: DevFlowTheme.warning, text: "需要重新登录")
            case let .failed(message): StatusDot(color: DevFlowTheme.danger, text: message)
            }
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            SectionLabel(title: title)
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DevFlowTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(DevFlowTheme.border(colorScheme)))
        }
    }

    @ViewBuilder
    private func toolRow(_ provider: AIProvider) -> some View {
        let available = toolAvailability[provider]
        let row = ToolStatusRow(provider: provider, available: available)
            .opacity(draggingProvider == provider ? 0.45 : 1)
            .contentShape(Rectangle())
            .onDrop(
                of: [.plainText],
                delegate: AIProviderDropDelegate(
                    target: provider,
                    dragging: { draggingProvider },
                    isDraggable: { toolAvailability[$0] == true },
                    move: { source, target in
                        appState.moveAIProvider(source, to: target)
                    },
                    commit: {
                        appState.persistState()
                    },
                    clearDragging: {
                        draggingProvider = nil
                    }
                )
            )

        if available == true {
            row
                .onDrag {
                    draggingProvider = provider
                    return NSItemProvider(object: provider.rawValue as NSString)
                }
        } else {
            row
        }
    }

    private func customProviderRow(_ provider: CustomAIProviderConfig) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(DevFlowTheme.accent.opacity(0.1))
                Image(systemName: "link").foregroundStyle(DevFlowTheme.accent)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.name).font(.system(size: 14, weight: .semibold))
                Text(provider.displayModelID)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("编辑") { editingCustomProvider = provider }
                .buttonStyle(SecondaryButtonStyle())
            Button {
                appState.customAIProviders.removeAll { $0.id == provider.id }
                AgentCredentialStore.saveAPIKey("", for: provider.id)
                appState.persistState()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(DevFlowTheme.danger)
            .help("删除自定义配置")
        }
    }
}

private struct CustomAIProviderEditor: View {
    @Environment(\.dismiss) private var dismiss
    let provider: CustomAIProviderConfig?
    let onSave: (CustomAIProviderConfig, String) -> Void
    @State private var name = ""
    @State private var apiURL = ""
    @State private var apiKey = ""
    @State private var modelID = ""
    @State private var modelIDs: [String] = []
    @State private var systemPrompt = "你是一个可以调用本地工具的开发助手。需要读取或修改项目时，先说明原因。"
    @State private var isLoadingModels = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(provider == nil ? "新增自定义 AI 工具" : "编辑自定义 AI 工具")
                .font(.system(size: 20, weight: .bold))
            TextField("名称，例如公司模型", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("API URL，例如 https://api.example.com/v1", text: $apiURL)
                .textFieldStyle(.roundedBorder)
            SecureField("API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Picker("模型", selection: $modelID) {
                    if modelIDs.isEmpty { Text("请先获取模型或手动输入").tag("") }
                    ForEach(modelIDs, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                TextField("手动输入模型 ID", text: $modelID)
                    .textFieldStyle(.roundedBorder)
                Button {
                    fetchModels()
                } label: {
                    if isLoadingModels { ProgressView().controlSize(.small) } else { Label("从 URL 获取", systemImage: "arrow.down.circle") }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isLoadingModels || apiURL.isEmpty || apiKey.isEmpty)
            }
            TextField("系统提示词（可选）", text: $systemPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            if !errorMessage.isEmpty {
                Text(errorMessage).font(.system(size: 12)).foregroundStyle(DevFlowTheme.danger)
            }
            Spacer()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("保存") { save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiURL.isEmpty || modelID.isEmpty)
            }
        }
        .padding(28)
        .onAppear {
            guard let provider else { return }
            name = provider.name
            apiURL = provider.apiURL
            modelIDs = provider.modelIDs
            modelID = provider.selectedModelID
            systemPrompt = provider.systemPrompt
            apiKey = AgentCredentialStore.loadAPIKey(for: provider.id)
        }
    }

    private func fetchModels() {
        isLoadingModels = true
        errorMessage = ""
        Task {
            do {
                let fetched = try await CustomAIProviderService.fetchModels(apiURL: apiURL, apiKey: apiKey)
                await MainActor.run {
                    modelIDs = fetched
                    if !fetched.contains(modelID) { modelID = fetched.first ?? "" }
                    isLoadingModels = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription + "；也可以手动输入模型 ID。"
                    isLoadingModels = false
                }
            }
        }
    }

    private func save() {
        var config = provider ?? CustomAIProviderConfig(name: name, apiURL: apiURL)
        config.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        config.apiURL = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        config.modelIDs = modelIDs.contains(modelID) ? modelIDs : modelIDs + [modelID]
        config.selectedModelID = modelID
        config.systemPrompt = systemPrompt
        onSave(config, apiKey)
        dismiss()
    }
}

private struct ToolStatusRow: View {
    let provider: AIProvider
    let available: Bool?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(available == true ? Color.secondary.opacity(0.75) : .clear)
                .frame(width: 14)
                .help(available == true ? "拖动调整顺序" : "未检测到，无法调整顺序")
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(DevFlowTheme.accent.opacity(0.1))
                Image(systemName: "terminal.fill").foregroundStyle(DevFlowTheme.accent)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.rawValue).font(.system(size: 14, weight: .semibold))
                Text(provider.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            if let available {
                StatusDot(color: available ? DevFlowTheme.success : DevFlowTheme.warning, text: available ? "可用" : "未检测到")
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

private struct AIProviderDropDelegate: DropDelegate {
    let target: AIProvider
    let dragging: () -> AIProvider?
    let isDraggable: (AIProvider) -> Bool
    let move: (AIProvider, AIProvider) -> Void
    let commit: () -> Void
    let clearDragging: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        if let dragging = dragging() {
            return isDraggable(dragging)
        }
        return info.hasItemsConforming(to: [.plainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let dragging = dragging(), isDraggable(dragging), dragging != target else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            move(dragging, target)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        commit()
        clearDragging()
        return true
    }
}
