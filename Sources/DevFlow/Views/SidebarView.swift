import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.top, 24)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)

            VStack(spacing: 5) {
                navigationRow(.all)
                navigationRow(.processing)
                navigationRow(.approval)
                navigationRow(.completed)
            }
            .padding(.horizontal, 10)

            HStack {
                Text("项目")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { appState.select(destination: .repositories) }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .hoverHighlight(cornerRadius: 6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("配置项目仓库")
            }
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 10)

            VStack(spacing: 5) {
                ForEach(appState.projects) { project in
                    projectRow(project)
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 20)

            VStack(spacing: 5) {
                navigationRow(.repositories)
                navigationRow(.agent)
                navigationRow(.settings)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 18)
        }
        .background {
            SidebarBackdrop()
        }
    }

    private var brand: some View {
        HStack(spacing: 13) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .padding(3)
                .background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .frame(width: 34, height: 34)

            Text("WorkSpace")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
    }

    private func navigationRow(_ destination: SidebarDestination) -> some View {
        let selected = appState.destination == destination && appState.selectedProjectID == nil
        return Button {
            appState.select(destination: destination)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: destination.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 20)
                Text(destination.rawValue)
                    .font(.system(size: 14, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer()
                if let count = appState.destinationCount(destination),
                   destination == .all || count > 0 {
                    CountBadge(count: count)
                }
            }
            .foregroundStyle(selected ? DevFlowTheme.accent : Color.primary.opacity(0.82))
            .padding(.horizontal, 14)
            .frame(height: 43)
            .contentShape(Rectangle())
            .hoverHighlight(
                isActive: selected,
                activeFill: DevFlowTheme.selectedFill(colorScheme),
                cornerRadius: 9
            )
        }
        .buttonStyle(.plain)
    }

    private func projectRow(_ project: Project) -> some View {
        let selected = appState.selectedProjectID == project.id
        return Button {
            appState.select(project: project)
        } label: {
            HStack(spacing: 12) {
                Text(project.name)
                    .font(.system(size: 14, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer()
                CountBadge(count: appState.ticketCount(for: project.id))
            }
            .foregroundStyle(selected ? DevFlowTheme.accent : Color.primary.opacity(0.82))
            .padding(.horizontal, 14)
            .frame(height: 43)
            .contentShape(Rectangle())
            .hoverHighlight(
                isActive: selected,
                activeFill: DevFlowTheme.selectedFill(colorScheme),
                cornerRadius: 9
            )
        }
        .buttonStyle(.plain)
    }
}

struct SidebarBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            SidebarVisualEffectView()
            Rectangle().fill(DevFlowTheme.sidebar(colorScheme))
        }
        .ignoresSafeArea()
    }
}

private struct SidebarVisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 23)
            .background(Color.primary.opacity(0.055), in: Capsule())
    }
}
