import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var escapeKeyMonitor: Any?

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                SidebarView()
                    .frame(minWidth: 250, idealWidth: 250, maxWidth: 250, maxHeight: .infinity, alignment: .topLeading)
                    .layoutPriority(2)

                Rectangle()
                    .fill(DevFlowTheme.sidebarSeparator(colorScheme))
                    .frame(width: 1)
                    .shadow(color: DevFlowTheme.sidebarShadow(colorScheme), radius: 7, x: 3, y: 0)
                    .zIndex(2)
                    .allowsHitTesting(false)

                Group {
                    switch appState.destination {
                    case .repositories:
                        RepositoryConfigView()
                    case .settings:
                        SettingsView()
                    default:
                        TicketBoardView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(DevFlowTheme.canvas(colorScheme))
            .allowsHitTesting(!appState.showingTicketModal)

            if appState.showingTicketModal, let ticket = appState.selectedTicket {
                TicketModalLayer(ticket: ticket)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                    .zIndex(20)
            }
        }
        .animation(.easeOut(duration: 0.18), value: appState.showingTicketModal)
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

    private func configureWindowBackdrop() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
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
