import AppKit
import SwiftUI

struct TicketDetailModal: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedRepositoryID: UUID?
    @State private var branch = ""
    @State private var provider: AIProvider = .codex
    @State private var helperContext = ""
    @State private var showingCloseConfirmation = false
    @FocusState private var focusedField: Field?

    let ticket: Ticket

    private enum Field { case helper }

    private var repositories: [RepositoryConfig] {
        appState.repositories(for: ticket)
    }

    private var selectedRepository: RepositoryConfig? {
        repositories.first { $0.id == selectedRepositoryID }
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
        if isShowingConfiguration && hasUnsavedInput { return true }
        guard let workItem else { return false }
        return ![.cancelled, .completed, .failed].contains(workItem.stage)
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

            if isTestingTicket {
                testingDetailContent
            } else if let workItem, workItem.stage != .cancelled {
                WorkItemContent(ticket: ticket, item: workItem)
            } else {
                configurationContent
            }
        }
        .background(DevFlowTheme.elevatedSurface(colorScheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DevFlowTheme.border(colorScheme)))
        .task {
            configureDefaults()
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

    private var headerStatus: TicketStatus {
        if let item = appState.activeWorkItem(for: ticket.id), item.stage != .awaitingApproval {
            return .processing
        }
        return ticket.status
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text(ticket.issueNumber)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(DevFlowTheme.accent)
                    TagPill(text: ticket.kind.rawValue, color: ticket.kind.color)
                    TagPill(text: ticket.priority.rawValue, color: ticket.priority.color)
                    TagPill(text: headerStatus.rawValue, color: headerStatus.color)
                }
                Text(ticket.title)
                    .font(.system(size: 23, weight: .bold))
                    .lineLimit(2)
            }
            Spacer()
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
                        SectionLabel(title: "解决配置")
                            .id(Field.helper)

                        repositoryPicker
                        branchField
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
                        withAnimation { proxy.scrollTo(Field.helper, anchor: .top) }
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
            Text(ticket.description)
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

    private var repositoryPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择代码仓库")
                .font(.system(size: 12, weight: .semibold))
            if repositories.isEmpty {
                Button {
                    appState.closeTicketModal()
                    appState.select(destination: .repositories)
                } label: {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                        Text("尚未配置仓库，前往添加")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .foregroundStyle(DevFlowTheme.accent)
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .background(DevFlowTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: selectedRepositoryID) { _ in
                    Task { await loadCurrentBranch() }
                }
            }
        }
    }

    private var branchField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前分支")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                TextField("例如 feature/issue-\(ticket.id)", text: $branch)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 11)
            .frame(height: 40)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DevFlowTheme.border(colorScheme)))
        }
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI 工具")
                .font(.system(size: 12, weight: .semibold))
            Picker("AI 工具", selection: $provider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
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
                Text("可选")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DevFlowTheme.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(DevFlowTheme.accent.opacity(0.12), in: Capsule())
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $helperContext)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .focused($focusedField, equals: .helper)
                    .onChange(of: helperContext) { value in
                        if value.count > 300 { helperContext = String(value.prefix(300)) }
                    }
                if helperContext.isEmpty {
                    Text("例如：该功能位于用户管理模块，重点检查 lib/user/profile 目录")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary.opacity(0.72))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 168)
            .background(DevFlowTheme.accent.opacity(colorScheme == .dark ? 0.10 : 0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(focusedField == .helper ? DevFlowTheme.accent : DevFlowTheme.accent.opacity(0.35), lineWidth: focusedField == .helper ? 2 : 1)
            )
            HStack {
                Spacer()
                Text("\(helperContext.count)/300")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(DevFlowTheme.accent.opacity(colorScheme == .dark ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DevFlowTheme.accent.opacity(0.22)))
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
            HStack(spacing: 4) {
                ForEach(Array(["AI 修改", "查看报告", "人工确认", "Commit", "拉取", "Push", "待测试"].enumerated()), id: \.offset) { index, title in
                    VStack(spacing: 5) {
                        Image(systemName: ["wand.and.stars", "doc.text.magnifyingglass", "person.badge.shield.checkmark", "tray.and.arrow.down", "arrow.down.circle", "arrow.up.circle", "checkmark.seal"][index])
                            .font(.system(size: 11))
                        Text(title)
                            .font(.system(size: 8.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(index == 0 ? DevFlowTheme.accent : .secondary)
                    if index < 6 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
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
        guard let selectedRepository else { return }
        let validation = await GitService().validateRepository(path: selectedRepository.path)
        if !validation.currentBranch.isEmpty {
            branch = validation.currentBranch
        } else if branch.isEmpty {
            branch = selectedRepository.defaultBranch
        }
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

    var body: some View {
        VStack(spacing: 0) {
            if let report = item.report, [.awaitingApproval, .reviewing, .partial, .completed].contains(item.stage) {
                AIReportView(ticket: ticket, item: item, report: report)
            } else {
                progressContent
            }
        }
    }

    private var progressContent: some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                if item.stage == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 27))
                        .foregroundStyle(DevFlowTheme.danger)
                } else {
                    ProgressView().controlSize(.large)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.stage.rawValue)
                        .font(.system(size: 18, weight: .semibold))
                    Text(item.errorMessage ?? "\(item.provider.rawValue) 正在处理 \(ticket.issueNumber)，你可以在此查看实时进度。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            JobStageStrip(current: item.stage)

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title: "执行日志")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(item.logs) { entry in
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
                }
                .frame(maxHeight: 340)
                .background(Color.black.opacity(colorScheme == .dark ? 0.25 : 0.035), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DevFlowTheme.border(colorScheme)))
            }

            HStack {
                if item.stage == .failed {
                    Button("返回配置") {
                        appState.jobCoordinator.dismiss(itemID: item.id)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                if ![.failed, .completed].contains(item.stage) {
                    Button("取消任务", role: .destructive) {
                        appState.jobCoordinator.cancel(itemID: item.id)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(25)
    }
}

struct JobStageStrip: View {
    let current: JobStage
    private let stages: [JobStage] = [.runningAI, .reviewing, .awaitingApproval, .committing, .pulling, .pushing, .updatingTicket, .completed]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(stages, id: \.self) { stage in
                VStack(spacing: 6) {
                    Circle()
                        .fill(stageColor(stage))
                        .frame(width: 9, height: 9)
                    Text(stage.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(stage == current ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
                if stage != stages.last {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: 1)
                        .offset(y: -8)
                }
            }
        }
    }

    private func stageColor(_ stage: JobStage) -> Color {
        guard let currentIndex = stages.firstIndex(of: current), let index = stages.firstIndex(of: stage) else {
            return Color.secondary.opacity(0.25)
        }
        if index < currentIndex { return DevFlowTheme.success }
        if index == currentIndex { return DevFlowTheme.accent }
        return Color.secondary.opacity(0.22)
    }
}
