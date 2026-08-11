import SwiftUI

struct AIReportView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: ReportTab = .summary
    @State private var commitMessage = ""
    @State private var assignee = ""
    @State private var showingDiscardConfirmation = false

    let ticket: Ticket
    let item: WorkItem
    let report: AIReport

    private enum ReportTab: String, CaseIterable, Identifiable {
        case summary = "修改报告"
        case diff = "代码差异"
        case logs = "原始输出"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("报告类型", selection: $selectedTab) {
                    ForEach(ReportTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                }
                .pickerStyle(.segmented)
                .frame(width: 330)
                Spacer()
                StatusDot(color: reportStatusColor, text: reportStatusText)
            }
            .padding(.horizontal, 25)
            .padding(.vertical, 14)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "AI 解决流程")
                JobStageStrip(current: item.stage)
            }
            .padding(.horizontal, 25)
            .padding(.vertical, 13)

            Divider()

            Group {
                switch selectedTab {
                case .summary: summaryView
                case .diff: codeView(report.diff)
                case .logs: codeView(report.rawOutput)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            approvalBar
        }
        .onAppear {
            commitMessage = "[#\(ticket.id)] \(ticket.title)"
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
        }
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

    private var isMissingRequiredAuthor: Bool {
        ticket.requiresAuthorReassignment && ticket.sourceURL != nil && ticket.normalizedAuthor.isEmpty
    }

    @ViewBuilder
    private var deliveryAssigneeControl: some View {
        if ticket.kind == .feature {
            deliveryRuleLabel("完成后转为待测试，负责人保持不变", color: .secondary)
        } else if ticket.requiresAuthorReassignment {
            if ticket.normalizedAuthor.isEmpty {
                deliveryRuleLabel("未获取到工单创建人，请刷新后再审批", color: DevFlowTheme.danger)
            } else {
                deliveryRuleLabel("完成后转交创建人：\(ticket.normalizedAuthor)", color: DevFlowTheme.accent)
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
                }
            }
        }
    }

    private func codeView(_ text: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text.isEmpty ? "暂无内容" : text)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(18)
        }
        .background(colorScheme == .dark ? Color.black.opacity(0.24) : Color(red: 0.97, green: 0.975, blue: 0.985))
    }

    private var approvalBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                TextField("Commit 信息", text: $commitMessage)
                    .textFieldStyle(.roundedBorder)
                deliveryAssigneeControl
            }
            HStack {
                Button("放弃修改", role: .destructive) {
                    showingDiscardConfirmation = true
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("继续修改") {
                    appState.jobCoordinator.requestRevision(itemID: item.id)
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
                if item.stage == .partial {
                    Button {
                        Task {
                            await appState.jobCoordinator.retryTicketUpdate(itemID: item.id, manualAssignee: assignee)
                        }
                    } label: {
                        Label("仅重试工单更新", systemImage: "arrow.clockwise.circle.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isMissingRequiredAuthor)
                } else {
                    Button {
                        Task {
                            await appState.jobCoordinator.approveAndDeliver(
                                itemID: item.id,
                                commitMessage: commitMessage,
                                manualAssignee: assignee
                            )
                        }
                    } label: {
                        Label("批准并提交", systemImage: "checkmark.shield.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isMissingRequiredAuthor)
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
