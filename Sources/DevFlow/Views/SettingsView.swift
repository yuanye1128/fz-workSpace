import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var draftAutoSyncIntervalHours = 2

    private var hasUnsavedAutoSyncInterval: Bool {
        draftAutoSyncIntervalHours != appState.clampedAutoSyncIntervalHours
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("设置")
                        .font(.system(size: 25, weight: .bold))
                    Text("配置知识库、AI 工具、主题和交付默认值")
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
                    ToolStatusRow(name: "Codex", command: "codex")
                    Divider()
                    ToolStatusRow(name: "Cursor", command: "agent")
                }

                settingsSection("交付默认值") {
                    LabeledContent("默认测试负责人") {
                        TextField("姓名或用户 ID", text: $appState.defaultTestAssignee)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                            .onSubmit { appState.persistState() }
                    }
                    Text("代码 push 成功后，应用会在最终确认时使用或覆盖此默认值。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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
}

private struct ToolStatusRow: View {
    @State private var available: Bool?
    let name: String
    let command: String

    var body: some View {
        HStack {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(DevFlowTheme.accent.opacity(0.1))
                Image(systemName: "terminal.fill").foregroundStyle(DevFlowTheme.accent)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 14, weight: .semibold))
                Text(command).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            if let available {
                StatusDot(color: available ? DevFlowTheme.success : DevFlowTheme.warning, text: available ? "可用" : "未检测到")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            available = await ProcessRunner.commandExists(command)
        }
    }
}
