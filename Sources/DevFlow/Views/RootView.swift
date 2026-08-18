import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var escapeKeyMonitor: Any?
    @State private var isSidebarCollapsed = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                SidebarBackdrop()
                    .frame(width: isSidebarCollapsed ? 0 : WindowChrome.sidebarWidth)
                DevFlowTheme.canvas(colorScheme)
            }
            .ignoresSafeArea()

            HStack(spacing: 0) {
                SidebarView()
                    .frame(
                        minWidth: isSidebarCollapsed ? 0 : WindowChrome.sidebarWidth,
                        idealWidth: isSidebarCollapsed ? 0 : WindowChrome.sidebarWidth,
                        maxWidth: isSidebarCollapsed ? 0 : WindowChrome.sidebarWidth,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
                    .opacity(isSidebarCollapsed ? 0 : 1)
                    .clipped()
                    .layoutPriority(2)

                Rectangle()
                    .fill(DevFlowTheme.sidebarSeparator(colorScheme))
                    .frame(width: isSidebarCollapsed ? 0 : 1)
                    .shadow(color: DevFlowTheme.sidebarShadow(colorScheme), radius: 7, x: 3, y: 0)
                    .zIndex(2)
                    .allowsHitTesting(false)

                Group {
                    switch appState.destination {
                    case .repositories:
                        RepositoryConfigView()
                    case .agent:
                        AgentChatView()
                    case .settings:
                        SettingsView()
                    case .workload:
                        WorkloadView(scanStore: appState.workloadScan)
                    default:
                        TicketBoardView()
                    }
                }
                .frame(minWidth: WindowChrome.minBoardWidth, maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .padding(.top, 28)
            .allowsHitTesting(!appState.showingTicketModal)

            if appState.showingTicketModal, let ticket = appState.selectedTicket {
                TicketModalLayer(ticket: ticket)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                    .zIndex(20)
            }
        }
        .frame(
            minWidth: WindowChrome.minWidth(sidebarCollapsed: isSidebarCollapsed),
            minHeight: WindowChrome.minHeight
        )
        .ignoresSafeArea(.container, edges: .top)
        .toolbar {
            sidebarToggleToolbarItem
        }
        .animation(.interactiveSpring(response: 0.34, dampingFraction: 0.86), value: isSidebarCollapsed)
        .animation(.easeOut(duration: 0.18), value: appState.showingTicketModal)
        .background {
            FullSizeWindowConfigurator(
                minContentWidth: WindowChrome.minWidth(sidebarCollapsed: isSidebarCollapsed),
                minContentHeight: WindowChrome.minHeight
            )
        }
        .onAppear {
            guard escapeKeyMonitor == nil else { return }
            configureWindowBackdrop()
            escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53, appState.showingTicketModal else { return event }
                appState.requestTicketModalClose()
                return nil
            }
        }
        .onDisappear {
            if let escapeKeyMonitor {
                NSEvent.removeMonitor(escapeKeyMonitor)
                self.escapeKeyMonitor = nil
            }
        }
        .sheet(isPresented: $appState.showingKnowledgeBaseSession) {
            KnowledgeBaseSessionView(controller: appState.knowledgeBaseSession)
                .environmentObject(appState)
                .frame(minWidth: 980, minHeight: 720)
        }
        .task {
            await appState.restoreSessionIfNeeded()
            await appState.runAutomaticSyncLoop()
        }
    }

    @ToolbarContentBuilder
    private var sidebarToggleToolbarItem: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) {
                sidebarToggleButton
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) {
                sidebarToggleButton
            }
        }
    }

    private var sidebarToggleButton: some View {
        TitlebarSidebarToggle(
            isCollapsed: isSidebarCollapsed,
            isDisabled: appState.showingTicketModal
        ) {
            isSidebarCollapsed.toggle()
        }
        .padding(.leading, 5)
        .help(isSidebarCollapsed ? "展开侧边栏" : "收起侧边栏")
        .accessibilityLabel(isSidebarCollapsed ? "展开侧边栏" : "收起侧边栏")
    }

    private func configureWindowBackdrop() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.toolbar?.displayMode = .iconOnly
        }
    }

}

/// 标题栏侧栏开关：默认无边框，悬停/按下时显示系统风格浅底。
private struct TitlebarSidebarToggle: View {
    var isCollapsed: Bool
    var isDisabled: Bool
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(TitlebarHoverIconButtonStyle(isHovered: isHovered && !isDisabled))
        .disabled(isDisabled)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.arrow.set()
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct TitlebarHoverIconButtonStyle: ButtonStyle {
    var isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(fillOpacity(isPressed: configuration.isPressed)))
            )
    }

    private func fillOpacity(isPressed: Bool) -> Double {
        if isPressed { return 0.14 }
        if isHovered { return 0.08 }
        return 0
    }
}

private struct FullSizeWindowConfigurator: NSViewRepresentable {
    var minContentWidth: CGFloat
    var minContentHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(nsView.window)
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.toolbar?.displayMode = .iconOnly

        let contentMin = NSSize(width: minContentWidth, height: minContentHeight)
        window.contentMinSize = contentMin
        let frameMin = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentMin)).size
        window.minSize = frameMin

        // 侧栏展开导致最小宽度变大时，若当前窗口偏小则同步抬升，避免左右裁切
        var frame = window.frame
        var needsSetFrame = false
        if frame.width < frameMin.width {
            frame.origin.x -= (frameMin.width - frame.width) / 2
            frame.size.width = frameMin.width
            needsSetFrame = true
        }
        if frame.height < frameMin.height {
            frame.origin.y -= (frameMin.height - frame.height) / 2
            frame.size.height = frameMin.height
            needsSetFrame = true
        }
        if needsSetFrame {
            window.setFrame(frame, display: true)
        }
    }
}

private struct TicketModalLayer: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let ticket: Ticket

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(colorScheme == .dark ? 0.52 : 0.22))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    appState.requestTicketModalClose()
                }

            TicketDetailModal(ticket: ticket)
                .frame(minWidth: 780, idealWidth: 900, maxWidth: 960, minHeight: 640, idealHeight: 760, maxHeight: 820)
                .padding(28)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.42 : 0.18), radius: 34, x: 0, y: 18)
        }
    }
}
