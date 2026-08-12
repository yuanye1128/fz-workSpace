import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RepositoryConfigView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedProjectID: String?
    @State private var showingImporter = false

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            Divider()

            HStack(spacing: 0) {
                projectList
                    .frame(width: 220)
                Divider()
                repositoryList
            }
        }
        .background(DevFlowTheme.canvas(colorScheme))
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first, let projectID = selectedProjectID else { return }
            let repository = RepositoryConfig(
                projectID: projectID,
                displayName: url.lastPathComponent,
                path: url.path,
                defaultBranch: "main",
                isDefault: appState.repositories.filter { $0.projectID == projectID }.isEmpty
            )
            appState.upsert(repository: repository)
            Task {
                let validation = await GitService().validateRepository(path: url.path)
                if !validation.currentBranch.isEmpty {
                    var updated = repository
                    updated.defaultBranch = validation.currentBranch
                    appState.upsert(repository: updated)
                }
            }
        }
        .onAppear {
            selectedProjectID = selectedProjectID ?? appState.projects.first?.id
        }
    }

    private var pageHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("项目与仓库配置")
                    .font(.system(size: 25, weight: .bold))
                Text("为每个知识库项目配置一个或多个本地 Git 仓库")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showingImporter = true
            } label: {
                Label("添加仓库", systemImage: "folder.badge.plus")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(selectedProjectID == nil)
        }
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .padding(.bottom, 20)
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "知识库项目")
                .padding(.horizontal, 18)
                .padding(.top, 20)
            ForEach(appState.projects) { project in
                Button {
                    selectedProjectID = project.id
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: project.symbol).frame(width: 20)
                        Text(project.name)
                        Spacer()
                        Text("\(appState.repositories.filter { $0.projectID == project.id }.count)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 13)
                    .frame(height: 42)
                    .background(selectedProjectID == project.id ? DevFlowTheme.selectedFill(colorScheme) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            Spacer()
        }
        .background(DevFlowTheme.sidebar(colorScheme).opacity(0.56))
    }

    private var repositoryList: some View {
        let repositories = appState.repositories.filter { $0.projectID == selectedProjectID }
        return Group {
            if repositories.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "externaldrive.badge.plus")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(DevFlowTheme.accent)
                    Text("这个项目还没有代码仓库")
                        .font(.system(size: 17, weight: .semibold))
                    Text("添加本地 Git 仓库后，才能从工单启动 Codex、Cursor 或 Claude Code。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Button("选择仓库目录") { showingImporter = true }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 13) {
                        ForEach(repositories) { repository in
                            RepositoryRow(repository: repository)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RepositoryRow: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var currentBranch = ""
    @State private var isLoadingBranch = true
    let repository: RepositoryConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(DevFlowTheme.accent.opacity(0.1))
                    Image(systemName: "folder.fill").foregroundStyle(DevFlowTheme.accent)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(repository.displayName).font(.system(size: 15, weight: .semibold))
                        if repository.isDefault { TagPill(text: "默认", color: DevFlowTheme.accent) }
                    }
                    Text(repository.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Menu {
                    Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repository.path) }
                    Button("移除", role: .destructive) { appState.removeRepository(id: repository.id) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("当前分支").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(.secondary)
                        if isLoadingBranch {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(currentBranch.isEmpty ? "未知" : currentBranch)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(minWidth: 160, alignment: .leading)
                    .frame(height: 29)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                }
                Spacer()
                Button("刷新分支") {
                    Task { await refreshBranch(updateStored: true) }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(18)
        .background(DevFlowTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DevFlowTheme.border(colorScheme)))
        .task { await refreshBranch(updateStored: true) }
    }

    private func refreshBranch(updateStored: Bool) async {
        isLoadingBranch = true
        let validation = await GitService().validateRepository(path: repository.path)
        currentBranch = validation.currentBranch
        isLoadingBranch = false
        if updateStored, !validation.currentBranch.isEmpty, validation.currentBranch != repository.defaultBranch {
            var updated = repository
            updated.defaultBranch = validation.currentBranch
            appState.upsert(repository: updated)
        }
    }
}
