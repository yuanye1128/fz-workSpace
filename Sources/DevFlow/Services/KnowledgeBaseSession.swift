import Foundation
import SwiftUI
import WebKit

enum KnowledgeBaseQuery {
    static let allAssignedIssuesURL = "https://kb.fzyun.net/issues?assigned_to_id=424&set_filter=1&sort=priority%3Adesc%2Cupdated_on%3Adesc"
    private static let legacyURL = "https://kb.fzyun.net/issues?assigned_to_id=424&page=1&set_filter=1&sort=fixed_version%2Cpriority%3Adesc%2Cupdated_on%3Adesc"

    static func migratedURL(_ rawURL: String) -> String {
        rawURL == legacyURL ? allAssignedIssuesURL : allPagesURL(rawURL)
    }

    static func allPagesURL(_ rawURL: String) -> String {
        guard var components = URLComponents(string: rawURL) else { return rawURL }
        components.queryItems = components.queryItems?.filter { $0.name != "page" }
        return components.url?.absoluteString ?? rawURL
    }
}

@MainActor
final class KnowledgeBaseSessionController: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var currentURL: String = ""
    @Published var statusMessage = "尚未连接"
    @Published var isLoading = false

    private var navigationContinuation: CheckedContinuation<Void, Error>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func sync(using appState: AppState, background: Bool = false) async {
        guard appState.beginSyncIfPossible() else { return }
        defer { appState.finishSync() }

        let allPagesURL = KnowledgeBaseQuery.migratedURL(appState.knowledgeBaseURL)
        guard let url = URL(string: allPagesURL) else {
            appState.syncStatus = .failed("知识库地址无效")
            return
        }
        if allPagesURL != appState.knowledgeBaseURL {
            appState.knowledgeBaseURL = allPagesURL
            appState.persistState()
        }
        if !background {
            appState.syncStatus = .syncing
        }
        statusMessage = background ? "正在后台更新工单" : "正在读取用户名下所有分页工单"
        do {
            await restorePersistedCookies(using: appState.persistence)
            try await load(url)
            let response = try await extractAllTickets()
            if response.loginRequired {
                appState.markLoginRequired()
                if !background {
                    appState.showingKnowledgeBaseSession = true
                    statusMessage = "请在此窗口完成知识库登录"
                } else {
                    statusMessage = "后台同步需要重新登录"
                }
                return
            }
            if let error = response.error {
                throw KnowledgeBaseError.parseFailed(error)
            }
            let tickets = response.tickets.map { $0.ticket }
            let projectNames = Array(Set(response.tickets.map(\.project))).sorted()
            let existingTicketIDs = Set(appState.tickets.map(\.id))
            let newlyDiscoveredTickets = tickets.filter { !existingTicketIDs.contains($0.id) }
            appState.projects = projectNames.map { name in
                Project(id: name, name: name, symbol: symbol(for: name))
            }
            await persistCookies(using: appState.persistence)
            appState.updateTickets(tickets, newlyDiscoveredTickets: newlyDiscoveredTickets)
            statusMessage = "已读取 \(response.pageCount) 页，共同步 \(tickets.count) 个工单"
        } catch {
            appState.syncStatus = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    func prepareSession(using persistence: PersistenceStore) async {
        await restorePersistedCookies(using: persistence)
    }

    func persistCookies(using persistence: PersistenceStore) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
        // 先把 session cookie 写成带过期时间的持久 cookie，再同步写入磁盘（对齐浏览器配置文件行为）
        let expiry = Date().addingTimeInterval(60 * 60 * 24 * 30)
        var persisted: [HTTPCookie] = []
        for cookie in cookies {
            if cookie.isSessionOnly {
                var properties = cookie.properties ?? [:]
                properties[.name] = cookie.name
                properties[.value] = cookie.value
                properties[.domain] = cookie.domain
                properties[.path] = cookie.path
                properties[.expires] = expiry
                properties[.discard] = "FALSE"
                if cookie.isSecure { properties[.secure] = "TRUE" }
                if cookie.isHTTPOnly { properties[HTTPCookiePropertyKey(rawValue: "HttpOnly")] = "TRUE" }
                if let durable = HTTPCookie(properties: properties) {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        store.setCookie(durable) { continuation.resume() }
                    }
                    persisted.append(durable)
                    continue
                }
            }
            persisted.append(cookie)
        }
        persistence.saveCookies(persisted)
    }

    private func restorePersistedCookies(using persistence: PersistenceStore) async {
        let cookies = persistence.loadCookies()
        guard !cookies.isEmpty else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in cookies {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.setCookie(cookie) { continuation.resume() }
            }
        }
    }

    func updateTicket(ticket: Ticket, statusName: String, assignee: String) async throws {
        guard let sourceURL = ticket.sourceURL else { throw KnowledgeBaseError.missingTicketURL }
        let editURL = sourceURL.appendingPathComponent("edit")
        try await load(editURL)
        let loginRequired = try await evaluateBoolean(#"Boolean(document.querySelector('#login-form, form[action*="/login"]'))"#)
        if loginRequired { throw KnowledgeBaseError.loginRequired }

        let script = """
        const statusName = args.statusName;
        const assignee = args.assignee;
        const statusSelect = document.querySelector('#issue_status_id, select[name="issue[status_id]"]');
        const assigneeSelect = document.querySelector('#issue_assigned_to_id, select[name="issue[assigned_to_id]"]');
        const form = document.querySelector('#issue-form, form.edit_issue');
        if (!statusSelect || !form) return { ok: false, error: '未找到工单编辑表单或状态字段' };
        const statusOption = [...statusSelect.options].find(option => option.textContent.trim() === statusName || option.textContent.includes(statusName));
        if (!statusOption) return { ok: false, error: `未找到状态：${statusName}` };
        statusSelect.value = statusOption.value;
        if (assignee && assigneeSelect) {
          const assigneeOption = [...assigneeSelect.options].find(option => option.value === assignee || option.textContent.trim() === assignee || option.textContent.includes(assignee));
          if (!assigneeOption) return { ok: false, error: `未找到负责人：${assignee}` };
          assigneeSelect.value = assigneeOption.value;
        }
        form.requestSubmit();
        return { ok: true };
        """

        let result = try await webView.callAsyncJavaScript(script, arguments: ["statusName": statusName, "assignee": assignee], in: nil, contentWorld: .page)
        guard let dictionary = result as? [String: Any], dictionary["ok"] as? Bool == true else {
            let message = (result as? [String: Any])?["error"] as? String ?? "工单更新失败"
            throw KnowledgeBaseError.updateFailed(message)
        }
        try await waitForNextNavigation(timeout: 20)
    }

    func loadConfiguredURL(_ rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        currentURL = webView.url?.absoluteString ?? currentURL
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        currentURL = webView.url?.absoluteString ?? currentURL
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    private func load(_ url: URL) async throws {
        if webView.url == url, !webView.isLoading { return }
        try await withCheckedThrowingContinuation { continuation in
            navigationContinuation?.resume(throwing: KnowledgeBaseError.navigationSuperseded)
            navigationContinuation = continuation
            webView.load(URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30))
        }
    }

    private func waitForNextNavigation(timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    self.navigationContinuation = continuation
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw KnowledgeBaseError.timeout
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func extractAllTickets() async throws -> KBResponse {
        let script = """
        const loginRequired = Boolean(document.querySelector('#login-form, form[action*="/login"]')) || location.pathname.includes('/login');
        if (loginRequired) return JSON.stringify({ loginRequired: true, tickets: [], pageCount: 0 });

        const ticketsByID = new Map();
        const visitedPages = new Set();
        let pageDocument = document;
        let pageURL = location.href;
        let pageCount = 0;

        try {
          while (pageDocument && pageCount < 200) {
            if (visitedPages.has(pageURL)) break;
            visitedPages.add(pageURL);
            pageCount += 1;

            const text = (row, selector) => row.querySelector(selector)?.textContent?.trim() || '';
            const rows = [...pageDocument.querySelectorAll('table.issues tbody tr')];
            for (const row of rows) {
              const link = row.querySelector('td.subject a, td.id a, a.issue');
              const rawHref = link?.getAttribute('href') || '';
              const href = rawHref ? new URL(rawHref, pageURL).href : '';
              const idText = text(row, 'td.id') || link?.textContent || '';
              const ticket = {
                id: Number(idText.replace(/\\D/g, '')),
                project: text(row, 'td.project') || '未分类项目',
                tracker: text(row, 'td.tracker'),
                priority: text(row, 'td.priority'),
                status: text(row, 'td.status'),
                subject: text(row, 'td.subject') || link?.textContent?.trim() || '',
                description: '',
                version: text(row, 'td.fixed_version') || text(row, 'td.version'),
                assignee: text(row, 'td.assigned_to'),
                author: text(row, 'td.author'),
                updated: text(row, 'td.updated_on'),
                url: href
              };
              if (ticket.id && ticket.subject && !ticketsByID.has(ticket.id)) {
                ticketsByID.set(ticket.id, ticket);
              }
            }

            const nextLink = pageDocument.querySelector('a[rel="next"], .pagination .next a, .pagination a.next, li.next.page a');
            const nextHref = nextLink?.getAttribute('href');
            if (!nextHref) break;
            const nextURL = new URL(nextHref, pageURL).href;
            if (visitedPages.has(nextURL)) break;

            const response = await fetch(nextURL, { credentials: 'include' });
            if (!response.ok) throw new Error(`第 ${pageCount + 1} 页加载失败（HTTP ${response.status}）`);
            const html = await response.text();
            pageDocument = new DOMParser().parseFromString(html, 'text/html');
            if (pageDocument.querySelector('#login-form, form[action*="/login"]')) {
              return JSON.stringify({ loginRequired: true, tickets: [], pageCount });
            }
            pageURL = nextURL;
          }

          const tickets = [...ticketsByID.values()];
          let nextTicketIndex = 0;
          const loadDescription = async () => {
            while (nextTicketIndex < tickets.length) {
              const index = nextTicketIndex++;
              const ticket = tickets[index];
              if (!ticket.url) continue;
              try {
                const response = await fetch(ticket.url, { credentials: 'include' });
                if (!response.ok) continue;
                const html = await response.text();
                const doc = new DOMParser().parseFromString(html, 'text/html');
                ticket.description = doc.querySelector('#issue_description_wiki, .description .wiki')?.textContent?.trim() || '';
                ticket.description = ticket.description.replace(/^\\s*引用\\s*(?:\\r?\\n[ \\t]*)+\\s*描述\\s*(?:\\r?\\n[ \\t]*)+/, '').trim();
                ticket.description = ticket.description.replace(/^\\s*(?:引用|描述)\\s*(?:\\r?\\n[ \\t]*)+/, '').trim();
                if (!ticket.author) {
                  ticket.author = doc.querySelector('.issue .author a')?.textContent?.trim() || '';
                }
              } catch (_) {}
            }
          };
          const workerCount = Math.min(6, tickets.length);
          await Promise.all(Array.from({ length: workerCount }, loadDescription));

          return JSON.stringify({ loginRequired: false, tickets, pageCount });
        } catch (error) {
          return JSON.stringify({ loginRequired: false, tickets: [], pageCount, error: error?.message || '分页工单读取失败' });
        }
        """
        let value = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        guard let json = value as? String, let data = json.data(using: String.Encoding.utf8) else {
            throw KnowledgeBaseError.parseFailed("知识库没有返回可解析的数据")
        }
        return try JSONDecoder().decode(KBResponse.self, from: data)
    }

    private func evaluateBoolean(_ script: String) async throws -> Bool {
        let value = try await webView.evaluateJavaScript(script)
        return value as? Bool ?? false
    }

    private func symbol(for project: String) -> String {
        if project.contains("移动") { return "iphone" }
        if project.contains("数据") { return "server.rack" }
        if project.contains("云") { return "cube" }
        return "square.grid.2x2"
    }
}

private struct KBResponse: Decodable {
    var loginRequired: Bool
    var tickets: [KBTicket]
    var pageCount: Int
    var error: String?
}

private struct KBTicket: Decodable {
    var id: Int
    var project: String
    var tracker: String
    var priority: String
    var status: String
    var subject: String
    var description: String
    var version: String
    var assignee: String
    var author: String
    var updated: String
    var url: String

    var ticket: Ticket {
        let kindValue = KBTicket.kind(from: tracker)
        return Ticket(
            id: id,
            projectID: project,
            projectName: project,
            kind: kindValue,
            priority: priority.contains("紧急") ? .urgent : (priority.contains("高") ? .high : .normal),
            status: mapStatus(status),
            title: subject,
            description: {
                let cleaned = Ticket.sanitizedDescription(description)
                return cleaned.isEmpty ? "知识库列表未提供描述，打开原工单可查看完整内容。" : cleaned
            }(),
            targetVersion: version.isEmpty ? "未指定" : version,
            updatedAt: parsedUpdatedAt,
            assignee: assignee,
            sourceURL: URL(string: url),
            author: author.isEmpty ? nil : author
        )
    }

    private var parsedUpdatedAt: Date {
        let normalized = updated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return Date() }

        if let date = ISO8601DateFormatter().date(from: normalized) {
            return date
        }

        for format in [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd HH:mm",
            "yyyy年MM月dd日 HH:mm:ss",
            "yyyy年MM月dd日 HH:mm"
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: normalized) {
                return date
            }
        }

        return Date()
    }

    private func mapStatus(_ value: String) -> TicketStatus {
        if value.contains("测试") { return .testing }
        if value.contains("完成") || value.contains("关闭") { return .completed }
        if value.contains("反馈") { return .feedback }
        if value.contains("处理") || value.contains("进行") { return .processing }
        return .new
    }

    private static func kind(from tracker: String) -> TicketKind {
        let normalized = tracker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("bug") || tracker.contains("错误") || tracker.contains("缺陷") {
            return .bug
        }
        if tracker.contains("建议") || normalized.contains("suggest") || normalized.contains("proposal") {
            return .suggestion
        }
        if tracker.contains("支持") || normalized.contains("support") {
            return .support
        }
        if tracker.contains("任务") || normalized.contains("task") {
            return .task
        }
        return .feature
    }
}

enum KnowledgeBaseError: LocalizedError {
    case missingTicketURL
    case loginRequired
    case navigationSuperseded
    case timeout
    case parseFailed(String)
    case updateFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingTicketURL: "工单缺少知识库地址"
        case .loginRequired: "知识库登录已失效，请重新登录"
        case .navigationSuperseded: "知识库页面导航被新的操作替换"
        case .timeout: "知识库页面响应超时"
        case let .parseFailed(message), let .updateFailed(message): message
        }
    }
}

struct KnowledgeBaseSessionView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: KnowledgeBaseSessionController
    @State private var isSyncingFromLogin = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isSyncingFromLogin)
                .accessibilityLabel("关闭")

                VStack(alignment: .leading, spacing: 3) {
                    Text("知识库会话")
                        .font(.system(size: 16, weight: .semibold))
                    Text(controller.statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if controller.isLoading && !isSyncingFromLogin {
                    ProgressView().controlSize(.small)
                }
                Button("登录完成并同步") {
                    Task {
                        isSyncingFromLogin = true
                        await controller.sync(using: appState)
                        isSyncingFromLogin = false
                        if case .synced = appState.syncStatus {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isSyncingFromLogin)
            }
            .padding(14)
            Divider()
            ZStack {
                WebViewContainer(webView: controller.webView)
                    .blur(radius: isSyncingFromLogin ? 6 : 0)
                    .allowsHitTesting(!isSyncingFromLogin)

                if isSyncingFromLogin {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("正在同步工单…")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            Task {
                await controller.prepareSession(using: appState.persistence)
                if controller.webView.url == nil {
                    controller.loadConfiguredURL(appState.knowledgeBaseURL)
                }
            }
        }
    }
}

private struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
