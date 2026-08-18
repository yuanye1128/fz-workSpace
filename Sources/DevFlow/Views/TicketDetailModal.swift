import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TicketDetailModal: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedRepositoryID: UUID?
    @State private var branch = ""
    @State private var isLoadingBranch = false
    @State private var provider: AIProvider = .cursor
    @State private var selectedCustomProviderID: UUID?
    @State private var availableModels: [AIModelOption] = []
    @State private var selectedModelID = ""
    @State private var customModelID = ""
    @State private var selectedReasoningEffort = ""
    @State private var isLoadingModels = false
    @State private var helperContext = ""
    @State private var planningIntensity: RequirementPlanningIntensity = .medium
    @State private var planningAnswer = ""
    @State private var showingCloseConfirmation = false
    @State private var isDroppingHelperFiles = false
    @State private var externalLaunchError: String?
    @FocusState private var focusedField: Field?

    let ticket: Ticket

    /// 仓库/模型 左列固定宽度，保证「当前分支」与「思考强度」竖向对齐
    private static let solveConfigPrimaryColumnWidth: CGFloat = 220
    private static let solveConfigColumnSpacing: CGFloat = 30

    private enum Field { case helper, planningAnswer }

    private var repositories: [RepositoryConfig] {
        appState.repositories(for: ticket)
    }

    private var selectedRepository: RepositoryConfig? {
        repositories.first { $0.id == selectedRepositoryID }
    }

    private var selectedModel: AIModelOption? {
        availableModels.first { $0.slug == selectedModelID }
    }

    private var effectiveModelID: String? {
        guard provider != .cursor else { return nil }
        if !availableModels.isEmpty {
            return selectedModelID.isEmpty ? nil : selectedModelID
        }
        let custom = customModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? nil : custom
    }

    private var effectiveReasoningEffort: String? {
        guard provider != .cursor else { return nil }
        guard !selectedReasoningEffort.isEmpty else { return nil }
        if let selectedModel {
            return selectedModel.reasoningLevels.contains(selectedReasoningEffort) ? selectedReasoningEffort : nil
        }
        return availableModels.isEmpty ? selectedReasoningEffort : nil
    }

    private var selectedCustomProvider: CustomAIProviderConfig? {
        guard let selectedCustomProviderID else { return nil }
        return appState.customAIProviders.first { $0.id == selectedCustomProviderID }
    }

    private var isCustomProviderSelected: Bool { selectedCustomProvider != nil }

    private var providerSelectionKey: String {
        if let selectedCustomProviderID { return "custom:\(selectedCustomProviderID.uuidString)" }
        return "builtin:\(provider.rawValue)"
    }

    private var prefersExternalAgent: Bool {
        ticket.kind.prefersExternalAgentClient
    }

    private var usesRequirementPlanning: Bool {
        ticket.kind.usesRequirementPlanning
    }

    private var planningSession: RequirementPlanSession? {
        appState.planningSession(for: ticket.id)
    }

    private var workItem: WorkItem? {
        appState.activeWorkItem(for: ticket.id) ?? appState.workItems.last { $0.ticketID == ticket.id }
    }

    private var isTestingTicket: Bool {
        ticket.status == .testing
    }

    private var hasUnsavedInput: Bool {
        !helperContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !planningAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedRepositoryID != repositories.first(where: \.isDefault)?.id
    }

    private var isShowingConfiguration: Bool {
        if usesRequirementPlanning {
            return !isTestingTicket && planningSession == nil
        }
        return !isTestingTicket && (workItem == nil || workItem?.stage == .cancelled)
    }

    private var requiresCloseConfirmation: Bool {
        isShowingConfiguration && hasUnsavedInput
    }

    private var closeConfirmationMessage: String {
        if isShowingConfiguration {
            return "当前填写的辅助信息不会被保存。"
        }
        return "任务或交付流程仍在进行。关闭弹窗不会取消任务，你可以稍后从对应工单重新打开进度。"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if usesRequirementPlanning, let session = planningSession {
                HStack(spacing: 0) {
                    ScrollView {
                        ticketInformation
                            .padding(25)
                    }
                    .frame(maxWidth: .infinity)
                    Divider()
                    RequirementPlanningSessionView(
                        ticket: ticket,
                        session: session,
                        answer: $planningAnswer,
                        externalLaunchError: $externalLaunchError,
                        onHandoffSuccess: { appState.closeTicketModal() }
                    )
                    .frame(maxWidth: .infinity)
                }
            } else if let workItem, workItem.stage != .cancelled {
                WorkItemContent(ticket: ticket, item: workItem)
            } else if isTestingTicket {
                testingDetailContent
            } else {
                configurationContent
            }
        }
        .background(DevFlowTheme.elevatedSurface(colorScheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DevFlowTheme.border(colorScheme)))
        .task {
            configureDefaults()
            await reloadModels(for: provider)
        }
        .onChange(of: provider) { newProvider in
            Task { await reloadModels(for: newProvider) }
        }
        .onChange(of: selectedModelID) { _ in
            applyDefaultEffort(for: selectedModel)
        }
        .onChange(of: appState.ticketModalCloseRequestID) { _ in
            requestClose()
        }
        .alert("关闭工单详情？", isPresented: $showingCloseConfirmation) {
            Button("继续编辑", role: .cancel) {}
            Button("关闭", role: .destructive) { appState.closeTicketModal() }
        } message: {
            Text(closeConfirmationMessage)
        }
        .alert("打开客户端失败", isPresented: Binding(
            get: { externalLaunchError != nil },
            set: { if !$0 { externalLaunchError = nil } }
        )) {
            Button("知道了", role: .cancel) { externalLaunchError = nil }
        } message: {
            Text(externalLaunchError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                HStack(spacing: 5) {
                    Text(ticket.kind.rawValue)
                    Text(ticket.issueNumber)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DevFlowTheme.accent)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(DevFlowTheme.accent.opacity(0.12), in: Capsule())
                .padding(.top, 3)

                if ticket.isLocalTest {
                    Text("测试")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DevFlowTheme.warning)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(DevFlowTheme.warning.opacity(0.14), in: Capsule())
                        .padding(.top, 3)
                }

                Text(ticket.title)
                    .font(.system(size: 23, weight: .bold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                requestClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 25)
        .padding(.vertical, 20)
    }

    private var configurationContent: some View {
        HStack(spacing: 0) {
            ScrollView {
                ticketInformation
                .padding(25)
            }
            .frame(maxWidth: .infinity)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 17) {
//                        SectionLabel(title: "解决配置")
//                            .id("solve-config")

                        repositoryAndBranchRow
                        providerPicker
                        if usesRequirementPlanning {
                            intensityPicker
                        }
                        helperField
                        actionButtons
                        workflowStrip
                    }
                    .padding(25)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
                .onChange(of: appState.focusSolveConfiguration) { shouldFocus in
                    if shouldFocus {
                        withAnimation { proxy.scrollTo("solve-config", anchor: .top) }
                        focusedField = .helper
                    }
                }
            }
        }
    }

    private var testingDetailContent: some View {
        ScrollView {
            ticketInformation
                .padding(25)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var ticketInformation: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionLabel(title: "工单描述")
            Text(ticket.displayDescription)
                .font(.system(size: 14))
                .foregroundStyle(Color.primary.opacity(0.86))
                .lineSpacing(6)
                .textSelection(.enabled)

            Divider()

            detailGrid

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detailGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 12) {
            detailRow("所属项目", ticket.projectName)
            detailRow("类型", ticket.kind.rawValue, color: ticket.kind.color)
            detailRow("优先级", ticket.priority.rawValue, color: ticket.priority.color)
            detailRow("状态", ticket.status.rawValue, color: ticket.status.color)
            detailRow("目标版本", ticket.targetVersion)
            detailRow("当前负责人", ticket.assignee)
            detailRow("创建人", ticket.normalizedAuthor.isEmpty ? "未获取" : ticket.normalizedAuthor)
            detailRow("最后更新", ticket.updatedAt.devFlowTicketUpdatedText)
        }
    }

    private func detailRow(_ label: String, _ value: String, color: Color? = nil) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color ?? .primary)
        }
    }

    private var repositoryAndBranchRow: some View {
        HStack(alignment: .top, spacing: Self.solveConfigColumnSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("选择代码仓库")
                    .font(.system(size: 12, weight: .semibold))
                if repositories.isEmpty {
                    Button {
                        appState.closeTicketModal()
                        appState.select(destination: .repositories)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.badge.plus")
                            Text("尚未配置仓库，前往添加")
                            Image(systemName: "chevron.right")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DevFlowTheme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(DevFlowTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                } else {
                    Picker("", selection: $selectedRepositoryID) {
                        ForEach(repositories) { repository in
                            Text(repository.displayName).tag(Optional(repository.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: selectedRepositoryID) { _ in
                        Task { await loadCurrentBranch() }
                    }
                }
            }
            .frame(width: Self.solveConfigPrimaryColumnWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text("当前分支")
                    .font(.system(size: 12, weight: .semibold))
                currentBranchDisplay
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentBranchDisplay: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if isLoadingBranch {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Text(branch.isEmpty ? "—" : branch)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(branch.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Color.primary.opacity(0.055), in: Capsule())
        .help(branch.isEmpty ? "选择仓库后显示当前分支" : branch)
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(usesRequirementPlanning ? "AI 工具" : (prefersExternalAgent ? "打开到客户端" : "AI 工具"))
                .font(.system(size: 12, weight: .semibold))
            if usesRequirementPlanning {
                Text("先在工作台拆解需求并生成开发计划，再打开所选客户端实施。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if prefersExternalAgent {
                Text("任务适合多轮沟通，将携带工单上下文打开所选客户端。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Picker(usesRequirementPlanning ? "AI 工具" : (prefersExternalAgent ? "打开到客户端" : "AI 工具"), selection: Binding(
                get: { providerSelectionKey },
                set: { selectProvider($0) }
            )) {
                ForEach(appState.orderedAIProviders) { provider in
                    Text(provider.rawValue).tag("builtin:\(provider.rawValue)")
                }
                ForEach(appState.customAIProviders) { custom in
                    Text(custom.name).tag("custom:\(custom.id.uuidString)")
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if !prefersExternalAgent, provider != .cursor, !isCustomProviderSelected {
                if isLoadingModels {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取可用模型…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    modelAndEffortRow
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var showsReasoningPicker: Bool {
        if let levels = selectedModel?.reasoningLevels, !levels.isEmpty {
            return true
        }
        return availableModels.isEmpty
            && !customModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var reasoningLevelsForPicker: [String] {
        selectedModel?.reasoningLevels ?? ["low", "medium", "high", "xhigh", "max"]
    }

    private var modelAndEffortRow: some View {
        HStack(alignment: .top, spacing: Self.solveConfigColumnSpacing) {
            VStack(alignment: .leading, spacing: 6) {
                Text("模型")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if !availableModels.isEmpty {
                    Picker("模型", selection: $selectedModelID) {
                        ForEach(availableModels) { model in
                            Text(model.displayName).tag(model.slug)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                } else {
                    TextField("例如 gpt-5.6-sol", text: $customModelID)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: Self.solveConfigPrimaryColumnWidth, alignment: .leading)

            if showsReasoningPicker {
                VStack(alignment: .leading, spacing: 6) {
                    Text("思考强度")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker("思考强度", selection: $selectedReasoningEffort) {
                        ForEach(reasoningLevelsForPicker, id: \.self) { effort in
                            Text(AIReasoningEffort.displayName(for: effort)).tag(effort)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var helperField: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(usesRequirementPlanning ? "需求描述" : (prefersExternalAgent ? "补充上下文" : "辅助 AI 定位"))
                        .font(.system(size: 14, weight: .semibold))
                    if !usesRequirementPlanning {
                        Text(prefersExternalAgent
                             ? "可补充模块、文件路径或约束，会一并带入外部客户端"
                             : "补充模块、文件路径或技术约束，帮助 AI 更快找准代码位置")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !usesRequirementPlanning {
                    Button {
                        selectHelperFolder()
                    } label: {
                        Label("选择文件夹", systemImage: "folder")
                    }
                    .buttonStyle(CardActionButtonStyle())
                }
            }
            PathDropTextEditor(
                text: $helperContext,
                isFocused: Binding(
                    get: { focusedField == .helper },
                    set: { focusedField = $0 ? .helper : nil }
                ),
                isDropTargeted: $isDroppingHelperFiles,
                placeholder: usesRequirementPlanning ? "" : "例如：该功能位于用户管理模块，重点检查 lib/user/profile 目录"
            )
            .onChange(of: helperContext) { value in
                if value.count > 500 { helperContext = String(value.prefix(500)) }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $isDroppingHelperFiles) { providers in
                receiveDroppedHelperPaths(from: providers)
            }
            .frame(minHeight: 168)
            .background(DevFlowTheme.accent.opacity(colorScheme == .dark ? 0.10 : 0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isDroppingHelperFiles || focusedField == .helper ? DevFlowTheme.accent : DevFlowTheme.accent.opacity(0.35),
                        lineWidth: isDroppingHelperFiles || focusedField == .helper ? 2 : 1
                    )
                    .allowsHitTesting(false)
            )
            HStack {
                Spacer()
                Text("\(helperContext.count)/500")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(DevFlowTheme.accent.opacity(colorScheme == .dark ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DevFlowTheme.accent.opacity(0.22)))
    }

    private func receiveDroppedHelperPaths(from providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async {
                    appendHelperPath(url.standardizedFileURL.path)
                }
            }
        }
        return true
    }

    private func selectHelperFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择本地文件夹"
        panel.message = "选择需要提供给 AI 定位的文件夹"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            appendHelperPath(url.standardizedFileURL.path)
        }
    }

    private func appendHelperPath(_ path: String) {
        helperContext = helperContext.isEmpty ? path : "\(helperContext)\n\(path)"
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                guard let selectedRepository else { return }
                if isCustomProviderSelected {
                    openCustomAgent()
                } else if usesRequirementPlanning {
                    startRequirementPlanning(repository: selectedRepository)
                } else if prefersExternalAgent {
                    openInExternalAgent(repository: selectedRepository)
                } else {
                    Task {
                        let taskHelperContext = helperContextWithWorkGraphContext(for: selectedRepository)
                        await appState.jobCoordinator.start(
                            ticket: ticket,
                            repository: selectedRepository,
                            branch: branch,
                            provider: provider,
                            modelID: effectiveModelID,
                            reasoningEffort: effectiveReasoningEffort,
                            helperContext: taskHelperContext,
                            navigationMaterialPath: nil
                        )
                    }
                }
            } label: {
                    Label(
                        isCustomProviderSelected
                        ? "在 AI Agent 中打开"
                        : (usesRequirementPlanning ? "开始拆解需求" : (prefersExternalAgent ? "在 \(provider.rawValue) 中打开" : "开始解决")),
                        systemImage: isCustomProviderSelected
                        ? "sparkles"
                        : (usesRequirementPlanning ? "text.badge.checkmark" : (prefersExternalAgent ? "arrow.up.forward.app.fill" : "play.circle.fill"))
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(selectedRepository == nil || branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                if let url = ticket.sourceURL { NSWorkspace.shared.open(url) }
            } label: {
                Label("在知识库中查看原工单", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(ticket.sourceURL == nil)
        }
    }

    private var workflowStrip: some View {
        VStack(alignment: .leading, spacing: 11) {
            if usesRequirementPlanning {
                SectionLabel(title: "需求拆解流程")
                Text("按选定强度澄清关键决策，题数随理解浮动；仍不清楚就继续问。提问结束后整理验收清单与开发计划，再打开外部 Agent 实施。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if prefersExternalAgent {
                SectionLabel(title: "外部客户端处理")
                Text("任务工单会写入 `.devflow/current-task.md` 并打开所选客户端，便于多轮沟通。启动提示已复制到剪贴板。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                SectionLabel(title: "AI 解决流程")
                JobStageStrip(current: .preparing)
            }
        }
        .padding(.top, 5)
    }

    private var intensityPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("拆解强度")
                .font(.system(size: 12, weight: .semibold))
            Picker("拆解强度", selection: $planningIntensity) {
                ForEach(RequirementPlanningIntensity.allCases) { intensity in
                    Text(intensity.rawValue).tag(intensity)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Text("\(planningIntensity.caption)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func startRequirementPlanning(repository: RepositoryConfig) {
        let taskHelperContext = helperContextWithWorkGraphContext(for: repository)
        appState.requirementPlanner.start(
            ticket: ticket,
            repository: repository,
            branch: branch,
            provider: provider,
            modelID: effectiveModelID,
            reasoningEffort: effectiveReasoningEffort,
            helperContext: taskHelperContext,
            navigationMaterialPath: nil,
            intensity: planningIntensity
        )
    }

    private func openInExternalAgent(repository: RepositoryConfig) {
        Task {
            do {
                if !branch.isEmpty {
                    try await GitService().checkoutBranch(branch, at: repository.path)
                }
                _ = try ExternalAgentLauncher.launch(
                    .init(
                        ticket: ticket,
                        repositoryPath: repository.path,
                        branch: branch,
                        helperContext: helperContextWithWorkGraphContext(for: repository),
                        navigationMaterialPath: nil,
                        provider: provider,
                        enableWorkGraphMCP: provider == .cursor
                    )
                )
                await MainActor.run {
                    appState.closeTicketModal()
                }
            } catch {
                await MainActor.run {
                    externalLaunchError = error.localizedDescription
                }
            }
        }
    }

    private func helperContextWithWorkGraphContext(for repository: RepositoryConfig) -> String {
        let base = helperContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = [ticket.title, ticket.displayDescription, base]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard let graphContext = ProjectNavigationService().graphAgentContext(
            for: repository.path,
            query: query
        ) else {
            return base
        }
        return base.isEmpty ? graphContext.promptSection : base + "\n" + graphContext.promptSection
    }

    private func configureDefaults() {
        guard !isTestingTicket else { return }
        if let preferredProvider = appState.orderedAIProviders.first {
            provider = preferredProvider
        }
        if let defaultRepository = repositories.first(where: \.isDefault) ?? repositories.first {
            selectedRepositoryID = defaultRepository.id
            branch = defaultRepository.defaultBranch
            Task { await loadCurrentBranch() }
        }
        focusedField = .helper
    }

    private func selectProvider(_ key: String) {
        if key.hasPrefix("custom:"),
           let id = UUID(uuidString: String(key.dropFirst("custom:".count))),
           appState.customAIProviders.contains(where: { $0.id == id }) {
            selectedCustomProviderID = id
            availableModels = []
            selectedModelID = ""
            customModelID = ""
            selectedReasoningEffort = ""
        } else if key.hasPrefix("builtin:"),
                  let selected = AIProvider(rawValue: String(key.dropFirst("builtin:".count))) {
            selectedCustomProviderID = nil
            provider = selected
        }
    }

    private func openCustomAgent() {
        guard let custom = selectedCustomProvider else { return }
        let additionalContext = selectedRepository.map(helperContextWithWorkGraphContext(for:))
            ?? helperContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextText = additionalContext.isEmpty ? "无" : additionalContext
        let context = "请处理以下工单：\n\n标题：\(ticket.title)\n类型：\(ticket.kind.rawValue)\n优先级：\(ticket.priority.rawValue)\n描述：\n\(ticket.displayDescription)\n\n补充信息：\n\(contextText)"
        appState.agentInitialPrompt = context
        appState.agentSelectedProviderID = custom.id
        appState.closeTicketModal()
        appState.select(destination: .agent)
    }

    private func loadCurrentBranch() async {
        guard let selectedRepository else {
            branch = ""
            return
        }
        isLoadingBranch = true
        defer { isLoadingBranch = false }
        let validation = await GitService().validateRepository(path: selectedRepository.path)
        if !validation.currentBranch.isEmpty {
            branch = validation.currentBranch
        } else if branch.isEmpty {
            branch = selectedRepository.defaultBranch
        }
    }

    private func reloadModels(for provider: AIProvider) async {
        if provider == .cursor {
            availableModels = []
            selectedModelID = ""
            customModelID = ""
            selectedReasoningEffort = ""
            isLoadingModels = false
            return
        }

        isLoadingModels = true
        defer { isLoadingModels = false }
        let models = await AIModelCatalog.loadModels(for: provider)
        availableModels = models
        if let preferred = AIModelCatalog.preferredModel(from: models, provider: provider) {
            selectedModelID = preferred.slug
            customModelID = preferred.slug
            applyDefaultEffort(for: preferred)
        } else {
            selectedModelID = ""
            if customModelID.isEmpty {
                selectedReasoningEffort = provider == .claude ? "high" : "medium"
            }
        }
    }

    private func applyDefaultEffort(for model: AIModelOption?) {
        selectedReasoningEffort = AIModelCatalog.preferredEffort(for: model, provider: provider) ?? ""
    }

    private func requestClose() {
        if requiresCloseConfirmation {
            showingCloseConfirmation = true
        } else {
            appState.closeTicketModal()
        }
    }
}

private struct WorkItemContent: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let ticket: Ticket
    let item: WorkItem

    /// 用户点击步骤条回看时的步骤；nil 表示跟随当前真实阶段
    @State private var reviewedStepIndex: Int?
    @State private var renderedLiveOutput = ""
    @State private var hasInitializedLiveOutput = false

    private var visibleLogs: [JobLogEntry] {
        item.logs.filter { entry in
            !entry.message.contains("正在调用工具")
                && !entry.message.contains("工具执行完成")
                && !entry.message.hasPrefix("Codex 正在执行：")
        }
    }

    private var liveStepIndex: Int {
        JobStageStrip.stepIndex(for: item.stage) ?? 0
    }

    private var activeStepIndex: Int {
        min(reviewedStepIndex ?? liveStepIndex, liveStepIndex)
    }

    private var hasValidAnalysisPlan: Bool {
        PromptBuilder.hasRequiredProtocolMarkers(item.analysisPlan ?? "", phase: .analysis)
    }

    var body: some View {
        VStack(spacing: 0) {
            workflowHeader

            Group {
                switch activeStepIndex {
                case 0:
                    analysisStepContent
                case 1:
                    planStepContent
                case 2:
                    codingStepContent
                case 3:
                    reportStepContent
                case 4:
                    deliveryStepContent
                default:
                    progressBody(includeWorkflowStrip: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: item.stage) { _ in
            reviewedStepIndex = nil
        }
        .task(id: liveOutputText ?? "") {
            await animateLiveOutput(to: liveOutputText ?? "")
        }
    }

    @ViewBuilder
    private var reportStepContent: some View {
        if let report = item.report,
           [.awaitingApproval, .reviewing].contains(item.stage) || reviewedStepIndex == 3 {
            AIReportView(ticket: ticket, item: item, report: report, showsWorkflowStrip: false)
        } else {
            progressBody(includeWorkflowStrip: false)
        }
    }

    @ViewBuilder
    private var codingStepContent: some View {
        let codingFinished = (JobStageStrip.stepIndex(for: item.stage) ?? 0) > 2
            || [.completed, .partial, .cancelled].contains(item.stage)
        if item.stage == .runningAI {
            progressBody(includeWorkflowStrip: false)
        } else if codingFinished {
            progressBody(
                includeWorkflowStrip: false,
                title: "AI 编码已完成",
                subtitle: "该阶段已结束，可回看下方执行日志"
            )
        } else {
            progressBody(includeWorkflowStrip: false)
        }
    }

    private var deliveryStepContent: some View {
        DeliveryStatusView(ticket: ticket, item: item)
    }

    private var workflowHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "AI 解决流程")
            JobStageStrip(
                current: item.stage,
                selectedIndex: activeStepIndex,
                onSelect: { index in
                    guard index <= liveStepIndex else { return }
                    reviewedStepIndex = index
                }
            )
        }
        .padding(.horizontal, 25)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var analysisStepContent: some View {
        if item.stage == .analyzing || item.stage == .preparing {
            progressBody(includeWorkflowStrip: false)
        } else if hasValidAnalysisPlan, let plan = item.analysisPlan {
            analysisPlanScroll(plan: plan, title: "分析结果", subtitle: "只读回看分析阶段产出的方案")
        } else {
            progressBody(includeWorkflowStrip: false)
        }
    }

    @ViewBuilder
    private var planStepContent: some View {
        if item.stage == .awaitingPlanApproval {
            if hasValidAnalysisPlan, let plan = item.analysisPlan {
                AIAnalysisPlanView(ticket: ticket, item: item, plan: plan, showsWorkflowStrip: false)
            } else {
                invalidPlanContent
            }
        } else if hasValidAnalysisPlan, let plan = item.analysisPlan {
            analysisPlanScroll(plan: plan, title: "已确认的修改方案", subtitle: "当前流程已越过确认方案，以下为当时确认的内容")
        } else {
            progressBody(includeWorkflowStrip: false)
        }
    }

    private var invalidPlanContent: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(DevFlowTheme.danger)
                VStack(alignment: .leading, spacing: 4) {
                    Text("分析未产出有效方案")
                        .font(.system(size: 17, weight: .semibold))
                    Text("模型未按协议输出完整 DEVFLOW 方案（或把提示模板误当成结果）。请返回配置后重试分析。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title: "执行日志")
                logsScroll(maxHeight: 280)
            }

            HStack {
                Button("放弃本轮并重新分析") {
                    appState.jobCoordinator.abandonPlanAndRestart(itemID: item.id)
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
            }
        }
        .padding(25)
    }

    private func analysisPlanScroll(plan: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 25)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(title: "AI 分析与建议修改方案")
                    Text(plan)
                        .font(.system(size: 13))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(25)
            }
            .background(colorScheme == .dark ? Color.black.opacity(0.12) : Color.clear)
        }
    }

    private func progressBody(
        includeWorkflowStrip: Bool,
        title: String? = nil,
        subtitle: String? = nil
    ) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                progressStatusIcon
                VStack(alignment: .leading, spacing: 5) {
                    Text(title ?? item.stage.rawValue)
                        .font(.system(size: 18, weight: .semibold))
                    Text(subtitle ?? progressMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if includeWorkflowStrip {
                JobStageStrip(current: item.stage)
            }

            if isLiveOutputActive || (liveOutputText?.isEmpty == false) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        Image(systemName: "waveform")
                            .foregroundStyle(DevFlowTheme.accent)
                        SectionLabel(title: "AI 实时处理")
                        Spacer()
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(renderedLiveOutput)
                                    .font(.system(size: 12))
                                    .lineSpacing(4)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if isLiveOutputActive {
                                    TimelineView(.periodic(from: .now, by: 0.45)) { context in
                                        let dotCount = Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 3 + 1
                                        Text("正在生成实时内容" + String(repeating: ".", count: dotCount))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Color.clear
                                    .frame(height: 1)
                                    .id("latest-live-output")
                            }
                        }
                        .frame(maxHeight: 230)
                        .padding(13)
                        .background(DevFlowTheme.accent.opacity(colorScheme == .dark ? 0.08 : 0.045), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DevFlowTheme.accent.opacity(0.25)))
                        .onAppear { proxy.scrollTo("latest-live-output", anchor: .bottom) }
                        .onChange(of: renderedLiveOutput) { _ in
                            withAnimation(.easeOut(duration: 0.16)) {
                                proxy.scrollTo("latest-live-output", anchor: .bottom)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title: "执行日志")
                logsScroll(maxHeight: 340)
            }

            HStack {
                if item.stage == .interrupted {
                    Button("返回配置") {
                        appState.jobCoordinator.dismiss(itemID: item.id)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("重新检查进程") {
                        appState.jobCoordinator.recover(itemID: item.id)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else if item.stage == .failed {
                    Button("返回配置") {
                        appState.jobCoordinator.dismiss(itemID: item.id)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                if ![.failed, .interrupted, .completed].contains(item.stage) {
                    Button("取消任务", role: .destructive) {
                        appState.jobCoordinator.cancel(itemID: item.id)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(.horizontal, 25)
        .padding(.top, 12)
        .padding(.bottom, 25)
    }

    @ViewBuilder
    private var progressStatusIcon: some View {
        switch item.stage {
        case .failed, .interrupted:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 27))
                .foregroundStyle(item.stage == .interrupted ? DevFlowTheme.warning : DevFlowTheme.danger)
        case .completed, .cancelled, .partial:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 27))
                .foregroundStyle(DevFlowTheme.success)
        case .preparing, .analyzing, .runningAI, .reviewing,
             .committing, .pulling, .merging, .pushing, .updatingTicket:
            ProgressView().controlSize(.large)
        default:
            // awaitingApproval / awaitingPlanApproval 等回看时不应再转圈
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 27))
                .foregroundStyle(DevFlowTheme.success)
        }
    }

    private func logsScroll(maxHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(visibleLogs) { entry in
                        HStack(alignment: .top, spacing: 9) {
                            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .foregroundStyle(entry.level == "error" ? DevFlowTheme.danger : .primary)
                            Spacer()
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("latest-log")
                }
                .padding(13)
            }
            .onAppear {
                proxy.scrollTo("latest-log", anchor: .bottom)
            }
            .onChange(of: visibleLogs.count) { _ in
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo("latest-log", anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: maxHeight)
        .background(Color.black.opacity(colorScheme == .dark ? 0.25 : 0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DevFlowTheme.border(colorScheme)))
    }

    private var progressMessage: String {
        if item.stage == .interrupted {
            return item.errorMessage ?? "AI 后台任务已中断，你可以重新检查进程或返回配置。"
        }
        switch item.execution?.state {
        case .reconnecting:
            return "正在重新连接 AI 任务…"
        case .recovered:
            return "已恢复后台任务，正在继续接收日志"
        default:
            return item.errorMessage ?? "\(item.provider.rawValue) 正在处理 \(ticket.issueNumber)，你可以在此查看实时进度。"
        }
    }

    private var liveOutputText: String? {
        switch item.stage {
        case .preparing, .analyzing, .awaitingPlanApproval:
            return item.analysisOutput
        default:
            return item.codingOutput ?? item.analysisOutput
        }
    }

    private var isLiveOutputActive: Bool {
        item.stage == .analyzing || item.stage == .runningAI
    }

    @MainActor
    private func animateLiveOutput(to target: String) async {
        if !hasInitializedLiveOutput {
            renderedLiveOutput = target
            hasInitializedLiveOutput = true
            return
        }
        guard target != renderedLiveOutput else { return }
        guard target.hasPrefix(renderedLiveOutput) else {
            renderedLiveOutput = target
            return
        }
        let suffix = target.dropFirst(renderedLiveOutput.count)
        for character in suffix {
            if Task.isCancelled { return }
            renderedLiveOutput.append(character)
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
    }
}

private struct AIAnalysisPlanView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let ticket: Ticket
    let item: WorkItem
    let plan: String
    var showsWorkflowStrip: Bool = true

    @State private var supplementNote = ""
    @FocusState private var isSupplementFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("分析结果与修改方案")
                        .font(.system(size: 17, weight: .semibold))
                    Text("可补充说明后继续沟通，或确认后开始修改代码")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusDot(color: DevFlowTheme.warning, text: "等待方案确认")
            }
            .padding(.horizontal, 25)
            .padding(.vertical, 16)

            Divider()

            if showsWorkflowStrip {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(title: "AI 解决流程")
                    JobStageStrip(current: item.stage)
                }
                .padding(.horizontal, 25)
                .padding(.vertical, 13)

                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(title: "AI 分析与建议修改方案")
                    Text(plan)
                        .font(.system(size: 13))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(25)
            }
            .background(colorScheme == .dark ? Color.black.opacity(0.12) : Color.clear)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("继续沟通")
                    .font(.system(size: 12, weight: .semibold))
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("补充约束、遗漏点或希望调整的方案方向…", text: $supplementNote, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .focused($isSupplementFocused)

                    Button {
                        let note = supplementNote
                        supplementNote = ""
                        isSupplementFocused = false
                        appState.jobCoordinator.reviseAnalysisPlan(itemID: item.id, userNote: note)
                    } label: {
                        Label("发送并更新方案", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(supplementNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 25)
            .padding(.vertical, 12)

            Divider()

            HStack {
                Button("放弃方案并重新分析") {
                    appState.jobCoordinator.abandonPlanAndRestart(itemID: item.id)
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button {
                    appState.jobCoordinator.approveAnalysisPlan(itemID: item.id)
                } label: {
                    Label("确认方案并开始修改", systemImage: "checkmark.shield.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, 25)
            .padding(.vertical, 16)
        }
    }
}

struct JobStageStrip: View {
    let current: JobStage
    var selectedIndex: Int? = nil
    var onSelect: ((Int) -> Void)? = nil

    private let steps = [
        WorkflowStep(title: "分析", symbol: "magnifyingglass"),
        WorkflowStep(title: "确认方案", symbol: "person.badge.shield.checkmark"),
        WorkflowStep(title: "AI 编码", symbol: "wand.and.stars"),
        WorkflowStep(title: "报告确认", symbol: "doc.text.magnifyingglass"),
        WorkflowStep(title: "已完成", symbol: "checkmark.seal.fill")
    ]

    static func stepIndex(for stage: JobStage) -> Int? {
        switch stage {
        case .analyzing: 0
        case .awaitingPlanApproval: 1
        case .runningAI: 2
        case .reviewing, .awaitingApproval: 3
        case .committing, .pulling, .merging, .pushing, .updatingTicket, .partial, .completed: 4
        case .preparing, .interrupted, .failed, .cancelled: nil
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                let reachable = (reachedStepIndex.map { index <= $0 } ?? false)
                let isSelected = (selectedIndex ?? reachedStepIndex) == index
                let chip = VStack(spacing: 5) {
                    Image(systemName: step.symbol)
                        .font(.system(size: 17, weight: .semibold))
                    Text(step.title)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(stepColor(index, selected: isSelected, reachable: reachable))
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(
                    isSelected && onSelect != nil
                        ? DevFlowTheme.accent.opacity(0.10)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
                .opacity(onSelect == nil || reachable ? 1 : 0.45)

                if let onSelect, reachable {
                    Button {
                        onSelect(index)
                    } label: {
                        chip
                    }
                    .buttonStyle(.plain)
                } else {
                    chip
                }

                if index < steps.count - 1 {
                    Rectangle()
                        .fill(stepColor(index, selected: false, reachable: reachable).opacity(0.35))
                        .frame(width: 12, height: 1)
                }
            }
        }
    }

    private func stepColor(_ index: Int, selected: Bool, reachable: Bool) -> Color {
        if selected { return DevFlowTheme.accent }
        guard let reachedIndex = reachedStepIndex else { return .secondary }
        if index <= reachedIndex { return DevFlowTheme.accent.opacity(reachable ? 0.85 : 0.55) }
        return .secondary
    }

    private var reachedStepIndex: Int? {
        Self.stepIndex(for: current)
    }

    private struct WorkflowStep: Identifiable {
        let title: String
        let symbol: String

        var id: String { title }
    }
}

/// 收尾交付页：展示代码提交与工单状态。
private struct DeliveryStatusView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let ticket: Ticket
    let item: WorkItem

    @State private var assignee = ""
    @State private var transferToAuthor = true

    private var isMissingRequiredAuthor: Bool {
        transferToAuthor
            && ticket.requiresAuthorReassignment
            && ticket.sourceURL != nil
            && ticket.normalizedAuthor.isEmpty
    }

    private var commitDone: Bool {
        item.commitHash != nil
            || item.logs.contains { $0.message.contains("本地 commit 完成") }
            || [.pulling, .merging, .pushing, .updatingTicket, .partial, .completed].contains(item.stage)
    }

    private var pushDone: Bool {
        item.logs.contains { $0.message.contains("代码 push 成功") }
            || [.updatingTicket, .partial, .completed].contains(item.stage)
    }

    private var ticketDone: Bool {
        item.stage == .completed
            || item.logs.contains { $0.message.contains("工单已转为待测试") || $0.message.contains("交付流程已完成") }
    }

    private var headline: (title: String, subtitle: String, color: Color, symbol: String) {
        switch item.stage {
        case .completed:
            ("交付已完成", "代码已提交，工单已进入待测试", DevFlowTheme.success, "checkmark.seal.fill")
        case .partial:
            ("代码已提交，工单待更新", item.errorMessage ?? "工单状态更新失败，可重试", DevFlowTheme.warning, "exclamationmark.triangle.fill")
        case .committing:
            ("正在提交代码", "创建本地 commit…", DevFlowTheme.accent, "arrow.up.circle")
        case .pulling:
            ("正在同步目标分支", "拉取远程最新代码…", DevFlowTheme.accent, "arrow.down.circle")
        case .merging:
            ("正在合回目标分支", "squash 合回 \(item.branch)…", DevFlowTheme.accent, "arrow.triangle.merge")
        case .pushing:
            ("正在提交代码", "Push 到远程仓库…", DevFlowTheme.accent, "icloud.and.arrow.up")
        case .updatingTicket:
            ("正在更新工单", "转为待测试并处理负责人…", DevFlowTheme.accent, "ticket")
        default:
            ("收尾交付", item.stage.rawValue, .secondary, "flag.checkered")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                headlineBanner

                statusCard(
                    title: "代码提交",
                    rows: [
                        .init(
                            title: "本地 Commit",
                            detail: item.commitHash.map { String($0.prefix(8)) } ?? (commitDone ? "已完成" : "等待中"),
                            state: commitDone ? .done : (item.stage == .committing ? .running : .pending)
                        ),
                        .init(
                            title: "Push / 合回",
                            detail: pushDone
                                ? "已合回并推送 \(item.branch)"
                                : (item.stage == .pushing
                                   ? "推送中…"
                                   : (item.stage == .merging
                                      ? "合并中…"
                                      : (item.stage == .pulling ? "同步目标分支…" : "等待中"))),
                            state: pushDone
                                ? .done
                                : ([.pulling, .merging, .pushing].contains(item.stage) ? .running : .pending)
                        )
                    ]
                )

                statusCard(
                    title: "工单状态",
                    rows: [
                        .init(
                            title: "知识库工单",
                            detail: ticketStatusDetail,
                            state: ticketStatusState
                        )
                    ]
                )

                if item.stage == .partial {
                    retryBar
                }

                if item.stage == .failed, let mergePath = item.mergeWorktreePath {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("需手工处理 Git")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DevFlowTheme.warning)
                        Text("合并工作区仍保留，请自行解决后推送：\n\(mergePath)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DevFlowTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if item.stage == .completed || item.stage == .partial {
                    recentLogs
                }
            }
            .padding(25)
        }
        .onAppear {
            assignee = appState.defaultTestAssignee
        }
    }

    private var headlineBanner: some View {
        let info = headline
        return HStack(spacing: 16) {
            Image(systemName: info.symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(info.color)
                .frame(width: 56, height: 56)
                .background(info.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(info.title)
                    .font(.system(size: item.stage == .completed ? 26 : 20, weight: .bold))
                    .foregroundStyle(item.stage == .completed ? DevFlowTheme.success : .primary)
                Text(info.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if [.committing, .pulling, .merging, .pushing, .updatingTicket].contains(item.stage) {
                ProgressView().controlSize(.regular)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (item.stage == .completed ? DevFlowTheme.success.opacity(0.10) : DevFlowTheme.accent.opacity(0.06)),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(item.stage == .completed ? DevFlowTheme.success.opacity(0.35) : DevFlowTheme.border(colorScheme))
        )
    }

    private var ticketStatusDetail: String {
        if ticketDone {
            if let log = item.logs.last(where: { $0.message.contains("工单已转为待测试") || $0.message.contains("交付流程已完成") }) {
                return log.message
            }
            return "已转为待测试"
        }
        if item.stage == .partial {
            return item.errorMessage ?? "更新失败"
        }
        if item.stage == .updatingTicket {
            return "正在更新…"
        }
        if pushDone {
            return "等待更新"
        }
        return "等待代码提交完成"
    }

    private var ticketStatusState: DeliveryRowState {
        if ticketDone { return .done }
        if item.stage == .partial { return .failed }
        if item.stage == .updatingTicket { return .running }
        return .pending
    }

    private func statusCard(title: String, rows: [DeliveryStatusRow]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: title)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 12) {
                        statusIcon(row.state)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title)
                                .font(.system(size: 13, weight: .semibold))
                            Text(row.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    if index < rows.count - 1 {
                        Divider().padding(.leading, 44)
                    }
                }
            }
            .background(DevFlowTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DevFlowTheme.border(colorScheme)))
        }
    }

    private func statusIcon(_ state: DeliveryRowState) -> some View {
        Group {
            switch state {
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(DevFlowTheme.success)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(DevFlowTheme.danger)
            case .running:
                ProgressView().controlSize(.small)
            case .pending:
                Image(systemName: "circle").foregroundStyle(.tertiary)
            }
        }
        .frame(width: 18, height: 18)
    }

    private var retryBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if ticket.requiresAuthorReassignment {
                Toggle(isOn: $transferToAuthor) {
                    Text(transferToAuthor
                         ? (ticket.normalizedAuthor.isEmpty
                            ? "重试时转交创建人"
                            : "重试时转交创建人：\(ticket.normalizedAuthor)")
                         : "重试时不转交创建人")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.checkbox)
            } else if ticket.kind != .feature {
                TextField("测试负责人", text: $assignee)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }

            HStack {
                Spacer()
                Button {
                    Task {
                        await appState.jobCoordinator.retryTicketUpdate(
                            itemID: item.id,
                            manualAssignee: assignee,
                            reassignToAuthor: transferToAuthor
                        )
                    }
                } label: {
                    Label("仅重试工单更新", systemImage: "arrow.clockwise.circle.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isMissingRequiredAuthor)
            }
        }
        .padding(14)
        .background(DevFlowTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DevFlowTheme.warning.opacity(0.25)))
    }

    private var recentLogs: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "交付日志")
            VStack(alignment: .leading, spacing: 7) {
                ForEach(item.logs.suffix(8)) { entry in
                    HStack(alignment: .top, spacing: 9) {
                        Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .foregroundStyle(entry.level == "error" ? DevFlowTheme.danger : .primary)
                        Spacer()
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                }
            }
            .padding(13)
            .background(Color.black.opacity(colorScheme == .dark ? 0.25 : 0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(DevFlowTheme.border(colorScheme)))
        }
    }
}

private enum DeliveryRowState {
    case pending, running, done, failed
}

private struct DeliveryStatusRow {
    var title: String
    var detail: String
    var state: DeliveryRowState
}
