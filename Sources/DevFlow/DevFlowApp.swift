import AppKit
import SwiftUI

@main
struct DevFlowApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .preferredColorScheme(appState.themePreference.colorScheme)
                .frame(minWidth: 1024, minHeight: 700)
                .onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
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
        .defaultSize(width: 1440, height: 900)
        Settings {
            SettingsView()
                .environmentObject(appState)
                .preferredColorScheme(appState.themePreference.colorScheme)
                .frame(width: 720, height: 560)
        }
    }
}
