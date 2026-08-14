import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var draftAutoSyncIntervalHours = 2
    @State private var toolAvailability: [AIProvider: Bool] = [:]
    @State private var draggingProvider: AIProvider?

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
                    Text("已安装的工具可拖动排序，工单详情中的 AI 工具会使用同一顺序。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    ForEach(Array(appState.orderedAIProviders.enumerated()), id: \.element) { index, provider in
                        if index > 0 {
                            Divider()
                        }
                        toolRow(provider)
                    }
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
