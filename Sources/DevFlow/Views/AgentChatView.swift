import SwiftUI

struct AgentChatView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var messages: [AgentChatMessage] = []
    @State private var draft = ""
    @State private var isRunning = false
    @State private var status = ""
    @State private var pendingTool: PendingTool?
    @State private var toolContinuation: CheckedContinuation<Bool, Never>?
    @State private var autoApproveTools = false
    @State private var selectedProviderID: UUID?
    @FocusState private var inputFocused: Bool

    private struct PendingTool: Identifiable {
        let id = UUID()
        let request: AgentToolRequest
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            composer
        }
        .background(DevFlowTheme.canvas(colorScheme))
        .alert("允许 Agent 调用本地工具？", isPresented: Binding(
            get: { pendingTool != nil },
            set: { if !$0, pendingTool != nil { resolveTool(false) } }
        )) {
            Button("拒绝", role: .cancel) { resolveTool(false) }
            Button("允许") { resolveTool(true) }
        } message: {
            Text(pendingTool.map { toolDescription($0.request) } ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").foregroundStyle(DevFlowTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Agent").font(.system(size: 19, weight: .bold))
                Text(activeModelID.isEmpty ? "未配置模型" : activeModelID)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !appState.customAIProviders.isEmpty {
                Picker("配置", selection: $selectedProviderID) {
                    ForEach(appState.customAIProviders) { provider in
                        Text(provider.name).tag(Optional(provider.id))
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                .help("选择 AI 服务配置")
            }
            Toggle("自动批准本地工具", isOn: $autoApproveTools)
                .toggleStyle(.switch)
                .font(.system(size: 12))
            Button("清空") {
                messages.removeAll()
                status = ""
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .onAppear { prepareInitialState() }
        .onChange(of: appState.customAIProviders) { _ in selectDefaultProviderIfNeeded() }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if messages.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 30))
                                .foregroundStyle(.secondary)
                            Text("开始一段 Agent 对话").font(.system(size: 16, weight: .semibold))
                            Text("在设置中配置 API URL、Key 和模型后即可开始。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                            .padding(.top, 100)
                    }
                    ForEach(messages) { message in
                        messageRow(message).id(message.id)
                    }
                    if !status.isEmpty {
                        Text(status).font(.system(size: 12)).foregroundStyle(.secondary).id("status")
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: messages.count) { _ in
                if let id = messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("输入消息，Agent 可按需调用本地工具…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit { if !isRunning { send() } }
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRunning || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
        .background(DevFlowTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DevFlowTheme.border(colorScheme)))
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
    }

    private func messageRow(_ message: AgentChatMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.role == "user" ? "person.fill" : "sparkles")
                .foregroundStyle(message.role == "user" ? .secondary : DevFlowTheme.accent)
                .frame(width: 22)
            Text(message.content.isEmpty ? "…" : message.content)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(message.role == "user" ? DevFlowTheme.surface(colorScheme) : DevFlowTheme.elevatedSurface(colorScheme), in: RoundedRectangle(cornerRadius: 10))
    }

    private func send() {
        if isRunning { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        let userMessage = AgentChatMessage(role: "user", content: text)
        messages.append(userMessage)
        let assistantID = UUID()
        messages.append(AgentChatMessage(id: assistantID, role: "assistant", content: ""))
        isRunning = true
        status = "正在连接模型…"

        Task {
            do {
                try await AgentService().run(
                    messages: messages.filter { $0.id != assistantID },
                    apiURL: activeAPIURL,
                    apiKey: activeAPIKey,
                    model: activeModelID,
                    systemPrompt: activeSystemPrompt,
                    confirmTool: { request in await confirmTool(request) },
                    onDelta: { delta in
                        await MainActor.run {
                            if let index = messages.firstIndex(where: { $0.id == assistantID }) { messages[index].content += delta }
                            status = ""
                        }
                    },
                    onTool: { message in await MainActor.run { status = message } }
                )
            } catch {
                await MainActor.run {
                    if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[index].content = error.localizedDescription
                    }
                    status = ""
                }
            }
            await MainActor.run { isRunning = false }
        }
    }

    private func confirmTool(_ request: AgentToolRequest) async -> Bool {
        if autoApproveTools { return true }
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                toolContinuation = continuation
                pendingTool = PendingTool(request: request)
            }
        }
    }

    private func resolveTool(_ allowed: Bool) {
        pendingTool = nil
        let continuation = toolContinuation
        toolContinuation = nil
        continuation?.resume(returning: allowed)
    }

    private func toolDescription(_ request: AgentToolRequest) -> String {
        let arguments = request.arguments.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
        return "工具：\(request.name)\n\(arguments)"
    }

    private var activeProvider: CustomAIProviderConfig? {
        guard let selectedProviderID else { return appState.customAIProviders.first }
        return appState.customAIProviders.first { $0.id == selectedProviderID }
    }

    private var activeAPIURL: String { activeProvider?.apiURL ?? appState.agentAPIURL }
    private var activeModelID: String {
        guard let provider = activeProvider else { return appState.agentModelID }
        return provider.selectedModelID.isEmpty ? (provider.modelIDs.first ?? "") : provider.selectedModelID
    }
    private var activeSystemPrompt: String { activeProvider?.systemPrompt ?? appState.agentSystemPrompt }
    private var activeAPIKey: String {
        if let provider = activeProvider { return AgentCredentialStore.loadAPIKey(for: provider.id) }
        return appState.agentAPIKey
    }

    private func selectDefaultProviderIfNeeded() {
        guard !appState.customAIProviders.isEmpty else {
            selectedProviderID = nil
            return
        }
        if let requested = appState.agentSelectedProviderID,
           appState.customAIProviders.contains(where: { $0.id == requested }) {
            selectedProviderID = requested
            appState.agentSelectedProviderID = nil
            return
        }
        if let selectedProviderID,
           appState.customAIProviders.contains(where: { $0.id == selectedProviderID }) { return }
        selectedProviderID = appState.customAIProviders.first?.id
    }

    private func prepareInitialState() {
        selectDefaultProviderIfNeeded()
        if let prompt = appState.agentInitialPrompt {
            draft = prompt
            appState.agentInitialPrompt = nil
            inputFocused = true
        }
    }
}
