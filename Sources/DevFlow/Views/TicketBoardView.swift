import SwiftUI

struct TicketBoardView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    /// 卡片之间的行列间距（左右、上下一致）
    private let gridSpacing: CGFloat = 16
    /// 滚动内容相对边缘的留白（上下左右一致）
    private let gridPadding: CGFloat = 24
    private let minimumCardWidth: CGFloat = 320
    private let minimumColumnCount = 2
    private let maximumGridColumnCount = 4

    @State private var topBarWidth: CGFloat = 1200

    private func gridContentWidth(for availableWidth: CGFloat) -> CGFloat {
        max(0, availableWidth - gridPadding * 2)
    }

    private func gridColumns(for availableWidth: CGFloat) -> [GridItem] {
        let contentWidth = gridContentWidth(for: availableWidth)
        let fitted = Int((contentWidth + gridSpacing) / (minimumCardWidth + gridSpacing))
        let columnCount = min(maximumGridColumnCount, max(minimumColumnCount, fitted))
        return Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: gridSpacing, alignment: .top),
            count: columnCount
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if !appState.needsLogin {
                filterBar
                    .background(DevFlowTheme.canvas(colorScheme))
                Divider()
            }

            Group {
                if appState.needsLogin {
                    loginRequiredState
                } else if appState.filteredTickets.isEmpty {
                    emptyState
                } else if appState.boardLayout == .list {
                    listContent
                } else {
                    cardContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DevFlowTheme.canvas(colorScheme))
    }

    private var cardContent: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: gridPadding)

                    LazyVGrid(columns: gridColumns(for: geometry.size.width), alignment: .leading, spacing: gridSpacing) {
                        ForEach(appState.filteredTickets) { ticket in
                            TicketCardView(ticket: ticket)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }

                    Color.clear.frame(height: gridPadding)
                }
                .frame(width: gridContentWidth(for: geometry.size.width), alignment: .leading)
                .padding(.horizontal, gridPadding)
            }
            .scrollIndicators(.automatic)
        }
    }

    private var listContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: gridPadding)
                LazyVStack(spacing: gridSpacing) {
                    ForEach(appState.filteredTickets) { ticket in
                        TicketListRow(ticket: ticket)
                    }
                }
                Color.clear.frame(height: gridPadding)
            }
            .padding(.horizontal, gridPadding)
        }
        .scrollIndicators(.automatic)
    }

    private var topBar: some View {
        let isCompact = topBarWidth < 980
        let isNarrow = topBarWidth < 860
        let titleMax: CGFloat = isNarrow ? 160 : (isCompact ? 220 : 360)
        let searchMin: CGFloat = isNarrow ? 120 : (isCompact ? 150 : 170)
        let searchIdeal: CGFloat = isNarrow ? 160 : (isCompact ? 220 : 330)
        let barSpacing: CGFloat = isNarrow ? 8 : (isCompact ? 12 : 18)

        return HStack(spacing: barSpacing) {
            VStack(alignment: .leading, spacing: 6) {
                Text(appState.selectedTitle)
                    .font(.system(size: isNarrow ? 22 : 26, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(appState.needsLogin ? "登录后同步知识库工单" : "今天有 \(appState.filteredTickets.count) 个待处理事项")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 0, idealWidth: min(260 as CGFloat, titleMax), maxWidth: titleMax, alignment: .leading)
            .layoutPriority(1)

            // 随窗口宽度伸缩，窄屏时可收至 0，避免顶栏被挤出
            Spacer(minLength: 0)

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索标题或编号", text: $appState.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
            }
            .padding(.horizontal, 14)
            .frame(minWidth: searchMin, idealWidth: searchIdeal, maxWidth: 420, minHeight: 40, maxHeight: 40)
            .background(DevFlowTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DevFlowTheme.border(colorScheme)))
            .layoutPriority(0)

            HStack(spacing: 10) {
                syncIndicator(compact: isCompact)

                Button {
                    if appState.needsLogin {
                        appState.showingKnowledgeBaseSession = true
                    } else {
                        Task { await appState.knowledgeBaseSession.sync(using: appState, background: true) }
                    }
                } label: {
                    HStack(spacing: 7) {
                        if appState.isSynchronizing && !appState.needsLogin {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: appState.needsLogin ? "person.crop.circle.badge.plus" : "arrow.clockwise")
                                .frame(width: 14, height: 14)
                        }
                        if !isNarrow {
                            Text(appState.needsLogin ? "去登录" : "刷新")
                        }
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .fixedSize(horizontal: true, vertical: false)
                .focusable(false)

                Button {
                    appState.presentNewTicketNotifications()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "bell")
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 34, height: 34)

                        if appState.hasUnreadNewTickets {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                                .offset(x: 3, y: 3)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(appState.newTicketNotifications.isEmpty)
                .popover(isPresented: $appState.showingNewTicketsPopover, arrowEdge: .top) {
                    NewTicketNotificationsPopover(tickets: appState.newTicketNotifications)
                }

                Menu {
                    Button("设置") { appState.select(destination: .settings) }
                    Divider()
                    Button("知识库登录") { appState.showingKnowledgeBaseSession = true }
                } label: {
                    ZStack {
                        Circle().fill(DevFlowTheme.accent.opacity(0.14))
                        Image(systemName: "person.fill")
                            .foregroundStyle(DevFlowTheme.accent)
                    }
                    .frame(width: 36, height: 36)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        }
        .padding(.leading, isNarrow ? 18 : 28)
        .padding(.trailing, isNarrow ? 14 : 22)
        .padding(.top, 10)
        .padding(.bottom, 20)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: TopBarWidthKey.self, value: geometry.size.width)
            }
        }
        .onPreferenceChange(TopBarWidthKey.self) { topBarWidth = $0 }
    }

    private func syncIndicator(compact: Bool) -> some View {
        HStack(spacing: 7) {
            switch appState.syncStatus {
            case .syncing:
                ProgressView().controlSize(.small)
                if !compact { Text("正在同步") }
            case let .synced(date):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(DevFlowTheme.success)
                if !compact {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("知识库已同步")
                        Text("上次同步于 \(date.formatted(.dateTime.year().month().day().hour().minute()))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            case .loginRequired:
                Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(DevFlowTheme.warning)
                if !compact { Text("需要登录") }
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DevFlowTheme.danger)
                if !compact { Text("同步失败") }
            case .idle:
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                if !compact { Text("尚未同步") }
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help(syncStatusHelpText)
    }

    private var syncStatusHelpText: String {
        switch appState.syncStatus {
        case .syncing: return "正在同步"
        case let .synced(date):
            return "知识库已同步 · 上次同步于 \(date.formatted(.dateTime.year().month().day().hour().minute()))"
        case .loginRequired: return "需要登录"
        case .failed: return "同步失败"
        case .idle: return "尚未同步"
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            FilterMenu(title: "类型", value: appState.filters.kind?.rawValue) {
                Button("全部类型") { appState.filters.kind = nil }
                Divider()
                ForEach(TicketKind.allCases) { kind in
                    Button(kind.rawValue) { appState.filters.kind = kind }
                }
            }
            FilterMenu(title: "优先级", value: appState.filters.priority?.rawValue) {
                Button("全部优先级") { appState.filters.priority = nil }
                Divider()
                ForEach(TicketPriority.allCases) { priority in
                    Button(priority.rawValue) { appState.filters.priority = priority }
                }
            }
            FilterMenu(title: "状态", value: appState.filters.status?.rawValue) {
                Button("全部状态") { appState.filters.status = nil }
                Divider()
                ForEach(TicketStatus.allCases) { status in
                    Button(status.rawValue) { appState.filters.status = status }
                }
            }
            FilterMenu(title: "版本", value: appState.filters.version) {
                Button("全部版本") { appState.filters.version = nil }
                Divider()
                ForEach(appState.availableVersions, id: \.self) { version in
                    Button(version) { appState.filters.version = version }
                }
            }

            Spacer()

            Menu {
                ForEach(TicketSortOption.allCases) { option in
                    Button(option.rawValue) { appState.sortOption = option }
                }
            } label: {
                Label("排序：\(appState.sortOption.rawValue)", systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 13)
                    .frame(height: 38)
                    .background(DevFlowTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(DevFlowTheme.border(colorScheme)))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                appState.boardLayout = appState.boardLayout == .cards ? .list : .cards
            } label: {
                Image(systemName: appState.boardLayout == .cards ? BoardLayout.list.symbol : BoardLayout.cards.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(DevFlowTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(DevFlowTheme.border(colorScheme)))
            }
            .buttonStyle(.plain)
            .help(appState.boardLayout == .cards ? "切换为列表视图" : "切换为卡片视图")
            .accessibilityLabel(appState.boardLayout == .cards ? "切换为列表视图" : "切换为卡片视图")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private var loginRequiredState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(DevFlowTheme.accent)
            Text("请先登录知识库")
                .font(.system(size: 17, weight: .semibold))
            Text("登录后将同步分配给你的工单")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button("去登录") { appState.showingKnowledgeBaseSession = true }
                .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: appState.filters.isEmpty ? "checkmark.circle" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(DevFlowTheme.accent)
            Text(appState.filters.isEmpty ? "当前没有待处理工单" : "没有符合筛选条件的工单")
                .font(.system(size: 17, weight: .semibold))
            Text(appState.filters.isEmpty ? "刷新知识库或切换其他项目查看" : "调整筛选条件后再试一次")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if !appState.filters.isEmpty {
                Button("清除筛选") { appState.filters = TicketFilters() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FilterMenu<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            HStack(spacing: 8) {
                Text(value ?? title)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(value == nil ? Color.primary.opacity(0.82) : DevFlowTheme.accent)
            .padding(.horizontal, 13)
            .frame(height: 38)
            .background(DevFlowTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(value == nil ? DevFlowTheme.border(colorScheme) : DevFlowTheme.accent.opacity(0.4)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct NewTicketNotificationsPopover: View {
    let tickets: [Ticket]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("新的工单")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(tickets.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Divider()

            if tickets.isEmpty {
                Text("暂时没有新的工单")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 300, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(tickets) { ticket in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(ticket.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(2)
                                HStack(spacing: 8) {
                                    TagPill(text: ticket.kind.rawValue, color: ticket.kind.color)
                                    TagPill(text: ticket.priority.rawValue, color: ticket.priority.color)
                                    Spacer()
                                    Text(ticket.issueNumber)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
                .frame(width: 340, height: min(CGFloat(tickets.count) * 88, 360))
            }
        }
        .padding(16)
        .frame(width: 372)
    }
}

private struct TopBarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 1200
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
