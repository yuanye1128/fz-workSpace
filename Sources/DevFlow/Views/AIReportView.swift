import SwiftUI

struct AIReportView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: ReportTab = .summary
    @State private var commitMessage = ""
    @State private var assignee = ""
    @State private var transferToAuthor = true
    @State private var showingDiscardConfirmation = false

    let ticket: Ticket
    let item: WorkItem
    let report: AIReport
    var showsWorkflowStrip: Bool = true

    private enum ReportTab: String, CaseIterable, Identifiable {
        case summary = "修改报告"
        case diff = "代码差异"
        var id: String { rawValue }
    }

    private var canApprove: Bool {
        item.stage == .awaitingApproval || item.stage == .reviewing
    }

    private var isMissingRequiredAuthor: Bool {
        transferToAuthor
            && ticket.requiresAuthorReassignment
            && ticket.sourceURL != nil
            && ticket.normalizedAuthor.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("报告类型", selection: $selectedTab) {
                    ForEach(ReportTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Spacer()
                StatusDot(color: reportStatusColor, text: reportStatusText)
            }
            .padding(.horizontal, 25)
            .padding(.vertical, 14)

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

            Group {
                switch selectedTab {
                case .summary: summaryView
                case .diff: diffView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            approvalBar
        }
        .onAppear {
            if commitMessage.isEmpty {
                commitMessage = ticket.suggestedCommitMessage(summary: report.summary)
            }
            assignee = appState.defaultTestAssignee
        }
    }

    private var summaryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                reportSection("修改内容", text: report.summary)
                reportSection("为什么这样修改", text: report.reasoning)

                reportList("修改文件", items: report.changedFiles, symbol: "doc.badge.ellipsis")
                reportList("测试结果", items: report.tests, symbol: "checkmark.seal")
                reportList("潜在影响", items: report.risks, symbol: "exclamationmark.triangle")
            }
            .padding(25)
            .textSelection(.enabled)
        }
    }

    private var diffView: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(DiffPresentation.attributedDiff(report.diff, colorScheme: colorScheme))
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(18)
        }
        .background(colorScheme == .dark ? Color.black.opacity(0.24) : Color(red: 0.97, green: 0.975, blue: 0.985))
    }

    private var reportStatusText: String {
        switch item.stage {
        case .partial: "代码已提交，工单待重试"
        case .completed: "交付已完成"
        default: "等待人工确认"
        }
    }

    private var reportStatusColor: Color {
        switch item.stage {
        case .partial: DevFlowTheme.danger
        case .completed: DevFlowTheme.success
        default: DevFlowTheme.warning
        }
    }

    @ViewBuilder
    private var deliveryAssigneeControl: some View {
        if ticket.kind == .feature {
            deliveryRuleLabel("完成后转为待测试，负责人保持不变", color: .secondary)
        } else if ticket.requiresAuthorReassignment {
            VStack(alignment: .trailing, spacing: 6) {
                Toggle(isOn: $transferToAuthor) {
                    Text(transferToAuthor
                         ? (ticket.normalizedAuthor.isEmpty
                            ? "完成后转交创建人"
                            : "完成后转交创建人：\(ticket.normalizedAuthor)")
                         : "完成后不转交创建人")
                        .font(.system(size: 12, weight: .medium))
                        .multilineTextAlignment(.trailing)
                }
                .toggleStyle(.checkbox)
                .frame(width: 220, alignment: .trailing)

                if transferToAuthor, ticket.normalizedAuthor.isEmpty {
                    Text("未获取到工单创建人，请刷新后再审批")
                        .font(.system(size: 11))
                        .foregroundStyle(DevFlowTheme.danger)
                        .frame(width: 220, alignment: .trailing)
                }
            }
        } else {
            TextField("测试负责人", text: $assignee)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
    }

    private func deliveryRuleLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .multilineTextAlignment(.trailing)
            .frame(width: 180, alignment: .trailing)
    }

    private func reportSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(title: title)
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(5)
                .textSelection(.enabled)
        }
    }

    private func reportList(_ title: String, items: [String], symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: title)
            if items.isEmpty {
                Text("无")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items, id: \.self) { item in
                    Label(item, systemImage: symbol)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var approvalBar: some View {
        VStack(spacing: 12) {
            if canApprove {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Commit Message")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("fix: #123 修复xxx / update: #123 新增xxx", text: $commitMessage)
                            .textFieldStyle(.roundedBorder)
                    }
                    deliveryAssigneeControl
                }
            }

            HStack {
                if canApprove {
                    Button("放弃修改", role: .destructive) {
                        showingDiscardConfirmation = true
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("继续修改") {
                        appState.jobCoordinator.requestRevision(itemID: item.id)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    Button {
                        Task {
                            await appState.jobCoordinator.approveAndDeliver(
                                itemID: item.id,
                                commitMessage: commitMessage,
                                manualAssignee: assignee,
                                reassignToAuthor: transferToAuthor
                            )
                        }
                    } label: {
                        Label("批准并提交", systemImage: "checkmark.shield.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isMissingRequiredAuthor)
                } else {
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 25)
        .padding(.vertical, 16)
        .alert("确认放弃本轮修改？", isPresented: $showingDiscardConfirmation) {
            Button("继续查看", role: .cancel) {}
            Button("放弃并恢复文件", role: .destructive) {
                appState.jobCoordinator.discard(itemID: item.id)
            }
        } message: {
            Text("这会恢复仓库中的未提交修改并清理本轮生成的未跟踪文件，且不会执行 commit、push 或工单更新。")
        }
    }
}

enum DiffPresentation {
    static func attributedDiff(_ diff: String, colorScheme: ColorScheme) -> AttributedString {
        let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            var empty = AttributedString("暂无差异")
            empty.foregroundColor = .secondary
            return empty
        }

        let addition = Color(red: 0.12, green: 0.45, blue: 0.92)
        let deletion = Color(red: 0.90, green: 0.22, blue: 0.25)
        let meta = colorScheme == .dark ? Color.secondary : Color(red: 0.35, green: 0.40, blue: 0.48)
        let fileHeader = DevFlowTheme.accent
        let separator = colorScheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.18)

        var output = AttributedString()
        let sections = splitUnifiedDiff(trimmed)
        for (index, section) in sections.enumerated() {
            if index > 0 {
                output.append(AttributedString("\n"))
                var line = AttributedString("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
                line.foregroundColor = separator
                output.append(line)
            }

            if !section.header.isEmpty {
                var header = AttributedString(section.header + "\n")
                header.foregroundColor = fileHeader
                header.font = .system(size: 11.5, weight: .semibold, design: .monospaced)
                output.append(header)

                var rule = AttributedString("────────────────────────────────────────\n")
                rule.foregroundColor = separator
                output.append(rule)
            }

            for rawLine in section.lines {
                let line = rawLine.hasSuffix("\n") ? String(rawLine.dropLast()) : rawLine
                var attr = AttributedString(line + "\n")
                attr.font = .system(size: 11.5, design: .monospaced)
                if line.hasPrefix("+") && !line.hasPrefix("+++") {
                    attr.foregroundColor = addition
                } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                    attr.foregroundColor = deletion
                } else if line.hasPrefix("@@") {
                    attr.foregroundColor = meta
                } else if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("+++") || line.hasPrefix("---") {
                    attr.foregroundColor = fileHeader
                }
                output.append(attr)
            }
        }
        return output
    }

    private struct DiffSection {
        var header: String
        var lines: [String]
    }

    private static func splitUnifiedDiff(_ diff: String) -> [DiffSection] {
        var sections: [DiffSection] = []
        var currentHeader = ""
        var currentLines: [String] = []

        func flush() {
            guard !currentHeader.isEmpty || !currentLines.isEmpty else { return }
            sections.append(DiffSection(header: currentHeader, lines: currentLines))
            currentHeader = ""
            currentLines = []
        }

        for line in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                flush()
                currentHeader = displayPath(from: line)
                currentLines = [line]
            } else if currentHeader.isEmpty, line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                if line.hasPrefix("+++ ") {
                    currentHeader = displayPath(from: line)
                }
                currentLines.append(line)
            } else {
                currentLines.append(line)
            }
        }
        flush()
        return sections.isEmpty
            ? [DiffSection(header: "", lines: diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))]
            : sections
    }

    private static func displayPath(from line: String) -> String {
        if line.hasPrefix("diff --git ") {
            let parts = line.split(separator: " ")
            if let b = parts.last {
                let path = String(b)
                return path.hasPrefix("b/") ? String(path.dropFirst(2)) : path
            }
        }
        if line.hasPrefix("+++ ") || line.hasPrefix("--- ") {
            var path = String(line.dropFirst(4))
            if path.hasPrefix("a/") || path.hasPrefix("b/") {
                path = String(path.dropFirst(2))
            }
            if path == "/dev/null" { return "新文件 / 删除文件" }
            return path
        }
        return line
    }
}
