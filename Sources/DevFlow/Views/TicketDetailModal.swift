import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TicketDetailModal: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedRepositoryID: UUID?
    @State private var branch = ""
    @State private var isLoadingBranch = false
    @State private var provider: AIProvider = .codex
    @State private var availableModels: [AIModelOption] = []
    @State private var selectedModelID = ""
    @State private var customModelID = ""
    @State private var selectedReasoningEffort = ""
    @State private var isLoadingModels = false
    @State private var helperContext = ""
    @State private var showingCloseConfirmation = false
    @State private var isDroppingHelperFiles = false
    @FocusState private var focusedField: Field?

    let ticket: Ticket

    private enum Field { case helper }

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

    private var workItem: WorkItem? {
        appState.activeWorkItem(for: ticket.id) ?? appState.workItems.last { $0.ticketID == ticket.id }
    }

    private var isTestingTicket: Bool {
        ticket.status == .testing
    }

    private var hasUnsavedInput: Bool {
        !helperContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedRepositoryID != repositories.first(where: \.isDefault)?.id
    }

    private var isShowingConfiguration: Bool {
        !isTestingTicket && (workItem == nil || workItem?.stage == .cancelled)
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

            if let workItem, workItem.stage != .cancelled {
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
                        helperField
                        actionButtons
                        workflowStrip
                    }
                    .padding(25)
                }
                .frame(width: 420)
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
        HStack(alignment: .top, spacing: 12) {
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
                            Spacer(minLength: 0)
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
                    .onChange(of: selectedRepositoryID) { _ in
                        Task { await loadCurrentBranch() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
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
        .help(branch.isEmpty ? "选择仓库后显示当前分支" : branch)
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI 工具")
                .font(.system(size: 12, weight: .semibold))
            Picker("AI 工具", selection: $provider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if provider != .cursor {
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
        HStack(alignment: .top, spacing: 12) {
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
                } else {
                    TextField("例如 gpt-5.6-sol", text: $customModelID)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsReasoningPicker {
                VStack(alignment: .trailing, spacing: 6) {
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
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var helperField: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("辅助 AI 定位")
                        .font(.system(size: 14, weight: .semibold))
                    Text("补充模块、文件路径或技术约束，帮助 AI 更快找准代码位置")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        selectHelperFolder()
                    } label: {
                        Label("选择文件夹", systemImage: "folder")
                    }
                    .buttonStyle(CardActionButtonStyle())

//                    Text("可选")
//                        .font(.system(size: 11, weight: .medium))
//                        .foregroundStyle(DevFlowTheme.accent)
//                        .padding(.horizontal, 8)
//                        .frame(height: 22)
//                        .background(DevFlowTheme.accent.opacity(0.12), in: Capsule())
                }
            }
            PathDropTextEditor(
                text: $helperContext,
                isFocused: Binding(
                    get: { focusedField == .helper },
                    set: { focusedField = $0 ? .helper : nil }
                ),
                isDropTargeted: $isDroppingHelperFiles,
                placeholder: "例如：该功能位于用户管理模块，重点检查 lib/user/profile 目录"
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
                Task {
                    await appState.jobCoordinator.start(
                        ticket: ticket,
                        repository: selectedRepository,
                        branch: branch,
                        provider: provider,
                        modelID: effectiveModelID,
                        reasoningEffort: effectiveReasoningEffort,
                        helperContext: helperContext
                    )
                }
            } label: {
                Label("开始解决", systemImage: "play.circle.fill")
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
            SectionLabel(title: "AI 解决流程")
            JobStageStrip(current: .preparing)
        }
        .padding(.top, 5)
    }

    private func configureDefaults() {
        guard !isTestingTicket else { return }
        if let defaultRepository = repositories.first(where: \.isDefault) ?? repositories.first {
            selectedRepositoryID = defaultRepository.id
            branch = defaultRepository.defaultBranch
            Task { await loadCurrentBranch() }
        }
        focusedField = .helper
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

    private var visibleLogs: [JobLogEntry] {
        item.logs.filter { entry in
            !entry.message.contains("正在调用工具")
                && !entry.message.contains("工具执行完成")
                && !entry.message.hasPrefix("Codex 正在执行：")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if item.stage == .awaitingPlanApproval, let analysisPlan = item.analysisPlan {
                AIAnalysisPlanView(ticket: ticket, item: item, plan: analysisPlan)
            } else if let report = item.report, [.awaitingApproval, .reviewing, .partial, .completed].contains(item.stage) {
                AIReportView(ticket: ticket, item: item, report: report)
            } else {
                progressContent
            }
        }
    }

    private var progressContent: some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                if item.stage == .failed || item.stage == .interrupted {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 27))
                        .foregroundStyle(item.stage == .interrupted ? DevFlowTheme.warning : DevFlowTheme.danger)
                } else {
                    ProgressView().controlSize(.large)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.stage.rawValue)
                        .font(.system(size: 18, weight: .semibold))
                    Text(progressMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            JobStageStrip(current: item.stage)

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title: "执行日志")
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
                .frame(maxHeight: 340)
                .background(Color.black.opacity(colorScheme == .dark ? 0.25 : 0.035), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DevFlowTheme.border(colorScheme)))
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
        .padding(25)
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
}

private struct AIAnalysisPlanView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let ticket: Ticket
    let item: WorkItem
    let plan: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("分析结果与修改方案")
                        .font(.system(size: 17, weight: .semibold))
                    Text("确认后 AI 才会开始修改本地代码")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusDot(color: DevFlowTheme.warning, text: "等待方案确认")
            }
            .padding(.horizontal, 25)
            .padding(.vertical, 16)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "AI 解决流程")
                JobStageStrip(current: item.stage)
            }
            .padding(.horizontal, 25)
            .padding(.vertical, 13)

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

            Divider()

            HStack {
                Button("返回配置") {
                    appState.jobCoordinator.requestRevision(itemID: item.id)
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
    private let steps = [
        WorkflowStep(title: "分析", symbol: "magnifyingglass"),
        WorkflowStep(title: "确认方案", symbol: "person.badge.shield.checkmark"),
        WorkflowStep(title: "AI 编码", symbol: "wand.and.stars"),
        WorkflowStep(title: "报告确认", symbol: "doc.text.magnifyingglass"),
        WorkflowStep(title: "代码提交", symbol: "arrow.up.circle"),
        WorkflowStep(title: "待测试", symbol: "checkmark.seal")
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                VStack(spacing: 7) {
                    Image(systemName: step.symbol)
                        .font(.system(size: 14, weight: .semibold))
                    Text(step.title)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(stepColor(index))
                .frame(maxWidth: .infinity)
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(stepColor(index).opacity(0.35))
                        .frame(width: 12, height: 1)
                        .offset(y: -12)
                }
            }
        }
    }

    private func stepColor(_ index: Int) -> Color {
        guard let reachedIndex = reachedStepIndex else {
            return .secondary
        }
        return index <= reachedIndex ? DevFlowTheme.accent : .secondary
    }

    private var reachedStepIndex: Int? {
        switch current {
        case .analyzing: 0
        case .awaitingPlanApproval: 1
        case .runningAI: 2
        case .reviewing, .awaitingApproval: 3
        case .committing, .pulling, .pushing, .partial: 4
        case .updatingTicket, .completed: 5
        case .preparing, .interrupted, .failed, .cancelled: nil
        }
    }

    private struct WorkflowStep: Identifiable {
        let title: String
        let symbol: String

        var id: String { title }
    }
}
