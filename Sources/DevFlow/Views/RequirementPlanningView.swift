import SwiftUI

struct RequirementPlanningSessionView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    let ticket: Ticket
    let session: RequirementPlanSession
    @Binding var answer: String
    @Binding var externalLaunchError: String?
    var onHandoffSuccess: () -> Void

    private var answeredCount: Int {
        session.messages.filter { $0.role == .user }.count
    }

    private var canFinishEarly: Bool {
        session.phase == .questioning
            && answeredCount >= session.intensity.questionRange.lowerBound
    }

    private var progressText: String {
        return "已问 \(session.askedCount) 个问题 · 强度 \(session.intensity.rawValue)，题数随理解浮动"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch session.phase {
            case .ready:
                documentContent
            case .failed:
                failedContent
            case .questioning, .compiling:
                conversationContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "需求拆解")
            Text(progressText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("题数随理解浮动；仍不清楚的关键点可以一并问清。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 25)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var conversationContent: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if session.messages.isEmpty, session.phase == .compiling {
                            planningStatusRow(text: "正在阅读工单并准备第一个关键问题…")
                        }
                        ForEach(session.messages) { message in
                            planningBubble(message)
                                .id(message.id)
                        }
                        if session.phase == .compiling, !session.messages.isEmpty {
                            planningStatusRow(text: "正在根据你的回答继续拆解…")
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("planning-bottom")
                    }
                    .padding(25)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { scrollToBottom(proxy) }
                .onChange(of: session.messages.count) { _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: session.phase) { _ in
                    scrollToBottom(proxy)
                }
            }

            Divider()
            answerBar
        }
    }

    private var answerBar: some View {
        let canReply = session.phase == .questioning
        return VStack(alignment: .leading, spacing: 10) {
            TextField("回复当前问题…", text: $answer, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .lineLimit(3...6)
                .disabled(!canReply)

            if canFinishEarly {
                Button {
                    appState.requirementPlanner.submitAnswer(
                        sessionID: session.id,
                        answer: answer,
                        finishNow: true
                    )
                    answer = ""
                } label: {
                    Text("生成开发计划")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canReply)
            }

            HStack {
                Spacer()
                if canFinishEarly {
                    Button("回复") { submitAnswer() }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(!canReply || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("回复") { submitAnswer() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!canReply || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(18)
        .opacity(canReply ? 1 : 0.55)
        .allowsHitTesting(canReply)
    }

    private var documentContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("开发计划已就绪。确认后打开外部客户端实施，工作台不再编码。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(session.developmentDocument ?? "")
                        .font(.system(size: 13))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(25)
            }

            Divider()
            HStack {
                Button("重新拆解") {
                    answer = ""
                    appState.requirementPlanner.reset(ticketID: ticket.id)
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button {
                    do {
                        try appState.requirementPlanner.handoffToExternalAgent(sessionID: session.id)
                        onHandoffSuccess()
                    } catch {
                        externalLaunchError = error.localizedDescription
                    }
                } label: {
                    Label("在 \(session.provider.rawValue) 中实施", systemImage: "arrow.up.forward.app.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(18)
        }
    }

    private var failedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DevFlowTheme.danger)
                VStack(alignment: .leading, spacing: 4) {
                    Text("拆解未完成")
                        .font(.system(size: 16, weight: .semibold))
                    Text(session.errorMessage ?? "模型没有按协议输出问题或开发文档。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack {
                Button("重新开始") {
                    answer = ""
                    appState.requirementPlanner.reset(ticketID: ticket.id)
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button("重试本轮") {
                    appState.requirementPlanner.retry(sessionID: session.id)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(25)
    }

    private func planningBubble(_ message: PlanningMessage) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                if !isUser {
                    Text("分析师")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(message.content)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(
                isUser ? DevFlowTheme.accent.opacity(colorScheme == .dark ? 0.22 : 0.10)
                    : Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private func planningStatusRow(text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func submitAnswer() {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appState.requirementPlanner.submitAnswer(sessionID: session.id, answer: trimmed)
        answer = ""
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("planning-bottom", anchor: .bottom)
            }
        }
    }
}
