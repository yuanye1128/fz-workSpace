import AppKit
import Darwin
import SwiftUI

enum WindowChrome {
    static let sidebarWidth: CGFloat = 250
    /// 保证工单卡片最少两列所需的内容区最小宽度（含左右 padding）
    static let minBoardWidth: CGFloat = 800
    static let minHeight: CGFloat = 700

    static func minWidth(sidebarCollapsed: Bool) -> CGFloat {
        minBoardWidth + (sidebarCollapsed ? 0 : sidebarWidth)
    }
}

@main
struct DevFlowApp: App {
    @StateObject private var appState: AppState

    init() {
        if let configurationPath = DurableExecutionWorker.configurationPath(from: CommandLine.arguments) {
            Darwin.exit(DurableExecutionWorker.run(configurationPath: configurationPath))
        }
        _appState = StateObject(wrappedValue: AppState())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .preferredColorScheme(appState.preferredSwiftUIColorScheme)
                .id(appState.themeRevision)
                .onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
                    appState.applyAppearance()
                    appState.jobCoordinator.recoverPersistedJobs()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    let state = appState
                    let semaphore = DispatchSemaphore(value: 0)
                    Task { @MainActor in
                        await state.persistCookiesBeforeExit()
                        semaphore.signal()
                    }
                    _ = semaphore.wait(timeout: .now() + 2)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1440, height: 900)
        Settings {
            SettingsView()
                .environmentObject(appState)
                .preferredColorScheme(appState.preferredSwiftUIColorScheme)
                .id(appState.themeRevision)
                .frame(width: 720, height: 560)
        }
    }
}
