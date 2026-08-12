import Foundation
import SwiftUI

enum TicketKind: String, Codable, CaseIterable, Identifiable {
    case bug = "Bug"
    case feature = "需求"
    case suggestion = "建议"
    case support = "支持"
    case task = "任务"

    var id: String { rawValue }
}

enum TicketPriority: String, Codable, CaseIterable, Identifiable {
    case urgent = "紧急"
    case high = "高"
    case normal = "普通"

    var id: String { rawValue }

    var sortRank: Int {
        switch self {
        case .urgent: 0
        case .high: 1
        case .normal: 2
        }
    }
}

enum TicketStatus: String, Codable, CaseIterable, Identifiable {
    case new = "新建"
    case processing = "处理中"
    case feedback = "待反馈"
    case testing = "待测试"
    case completed = "已完成"

    var id: String { rawValue }
}

struct Project: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var symbol: String
}

struct Ticket: Identifiable, Codable, Hashable {
    let id: Int
    var projectID: String
    var projectName: String
    var kind: TicketKind
    var priority: TicketPriority
    var status: TicketStatus
    var title: String
    var description: String
    var targetVersion: String
    var updatedAt: Date
    var assignee: String
    var sourceURL: URL?
    var author: String? = nil

    var issueNumber: String { "#\(id)" }

    /// 去掉知识库抓取时夹带的「引用 / 描述」等标签噪音
    var displayDescription: String {
        Self.sanitizedDescription(description)
    }

    static func sanitizedDescription(_ raw: String) -> String {
        var text = raw
        let patterns = [
            #"^\s*引用\s*(?:\r?\n[ \t]*)+\s*描述\s*(?:\r?\n[ \t]*)+"#,
            #"^\s*描述\s*(?:\r?\n[ \t]*)+"#,
            #"^\s*引用\s*(?:\r?\n[ \t]*)+"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let replaced = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            if replaced != text {
                text = replaced
                break
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var requiresAuthorReassignment: Bool {
        kind == .bug || kind == .support
    }

    var normalizedAuthor: String {
        author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct RepositoryConfig: Identifiable, Codable, Hashable {
    var id = UUID()
    var projectID: String
    var displayName: String
    var path: String
    var defaultBranch: String
    var remoteName: String = "origin"
    var isDefault: Bool = false
}

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case codex = "Codex"
    case cursor = "Cursor"
    case claude = "Claude Code"

    var id: String { rawValue }
}

struct AIModelOption: Identifiable, Hashable, Sendable {
    var id: String { slug }
    var slug: String
    var displayName: String
    var reasoningLevels: [String]
    var defaultReasoning: String?

    var supportsReasoning: Bool { !reasoningLevels.isEmpty }
}

enum AIReasoningEffort {
    static let displayNames: [String: String] = [
        "minimal": "极低",
        "low": "低",
        "medium": "中",
        "high": "高",
        "xhigh": "很高",
        "max": "最大",
        "ultra": "极致"
    ]

    static func displayName(for effort: String) -> String {
        displayNames[effort] ?? effort
    }
}

enum ThemePreference: String, Codable, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "暗黑"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum SidebarDestination: String, CaseIterable, Identifiable {
    case all = "全部工单"
    case processing = "我的处理中"
    case approval = "等待我确认"
    case completed = "已完成"
    case repositories = "项目与仓库配置"
    case settings = "设置"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .all: "rectangle.stack"
        case .processing: "clock.badge.checkmark"
        case .approval: "checkmark.message"
        case .completed: "checkmark.circle"
        case .repositories: "shippingbox"
        case .settings: "gearshape"
        }
    }
}

enum SyncStatus: Equatable {
    case idle
    case syncing
    case synced(Date)
    case loginRequired
    case failed(String)
}

enum BoardLayout: String, CaseIterable, Identifiable {
    case cards = "卡片"
    case list = "列表"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .cards: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }
}

enum TicketSortOption: String, CaseIterable, Identifiable {
    case priority = "优先级"
    case updated = "最新更新"
    case version = "目标版本"

    var id: String { rawValue }
}

struct TicketFilters: Equatable {
    var kind: TicketKind?
    var priority: TicketPriority?
    var status: TicketStatus?
    var version: String?

    var isEmpty: Bool {
        kind == nil && priority == nil && status == nil && version == nil
    }
}

enum JobStage: String, Codable, CaseIterable {
    case preparing = "准备仓库"
    case analyzing = "AI 分析问题"
    case awaitingPlanApproval = "确认修改方案"
    case runningAI = "AI 开始编码"
    case reviewing = "查看报告"
    case awaitingApproval = "人工确认"
    case committing = "本地 Commit"
    case pulling = "拉取最新代码"
    case pushing = "Push"
    case updatingTicket = "转为待测试"
    case completed = "已完成"
    case partial = "部分完成"
    case interrupted = "执行已中断"
    case failed = "失败"
    case cancelled = "已取消"

    var requiresUserApproval: Bool {
        self == .awaitingPlanApproval || self == .awaitingApproval
    }

}

enum AIExecutionPhase: String, Codable, Equatable, Sendable {
    case analysis
    case modification
}

enum AIExecutionState: String, Codable, Equatable, Sendable {
    case launching
    case running
    case reconnecting
    case recovered
    case completed
    case interrupted
}

struct AIExecutionRecord: Codable, Equatable, Sendable {
    var runID: UUID
    var phase: AIExecutionPhase
    var runDirectory: String
    var workerPID: Int32
    var startedAt: Date
    var lastOutputOffset: Int64
    var state: AIExecutionState
}

struct AIReport: Codable, Equatable {
    var summary: String
    var reasoning: String
    var changedFiles: [String]
    var tests: [String]
    var risks: [String]
    var diff: String
    var rawOutput: String
}

struct JobLogEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var timestamp = Date()
    var message: String
    var level: String = "info"
}

struct WorkItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var ticketID: Int
    var provider: AIProvider
    var modelID: String? = nil
    var reasoningEffort: String? = nil
    var repositoryPath: String
    var branch: String
    var helperContext: String
    var stage: JobStage
    var logs: [JobLogEntry]
    var analysisPlan: String?
    var report: AIReport?
    var commitHash: String?
    var errorMessage: String?
    var execution: AIExecutionRecord? = nil
    var createdAt = Date()
    var updatedAt = Date()
}

extension Date {
    var devFlowRelativeText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: self, relativeTo: Date())
    }

    var devFlowTicketUpdatedText: String {
        let now = Date()
        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            let hours = max(0, calendar.dateComponents([.hour], from: self, to: now).hour ?? 0)
            return hours == 0 ? "刚刚" : "\(hours) 小时前"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: self)
    }
}

enum SampleData {
    static let projects: [Project] = [
        Project(id: "cloud", name: "云平台", symbol: "cube"),
        Project(id: "ops", name: "运营后台", symbol: "square.grid.2x2"),
        Project(id: "mobile", name: "移动端", symbol: "iphone"),
        Project(id: "data", name: "数据中心", symbol: "server.rack")
    ]

    static let tickets: [Ticket] = [
        Ticket(id: 18426, projectID: "ops", projectName: "运营后台", kind: .bug, priority: .urgent, status: .new, title: "用户导出功能报错：权限校验失败", description: "在用户列表导出数据时报错 500，日志显示权限校验失败，但用户已具备导出权限，需要检查权限缓存与接口校验逻辑。", targetVersion: "v3.8.0", updatedAt: Date().addingTimeInterval(-600), assignee: "陈宇", sourceURL: nil),
        Ticket(id: 18425, projectID: "ops", projectName: "运营后台", kind: .feature, priority: .high, status: .new, title: "增加用户批量禁用功能", description: "支持按条件批量禁用用户账号，并记录操作日志。需要提供前端操作入口和后端接口。", targetVersion: "v3.8.0", updatedAt: Date().addingTimeInterval(-1500), assignee: "陈宇", sourceURL: nil),
        Ticket(id: 18424, projectID: "ops", projectName: "运营后台", kind: .bug, priority: .high, status: .processing, title: "角色编辑页面保存后权限未生效", description: "角色编辑保存后，返回列表查看权限未更新，需刷新页面才生效，影响用户体验。", targetVersion: "v3.7.1", updatedAt: Date().addingTimeInterval(-3600), assignee: "陈宇", sourceURL: nil),
        Ticket(id: 18423, projectID: "ops", projectName: "运营后台", kind: .bug, priority: .high, status: .new, title: "用户详情页加载缓慢", description: "进入用户详情页时，接口响应时间过长，导致页面加载缓慢，影响排查效率。初步定位是 user_profile 接口在高并发下查询耗时较长，怀疑与关联表查询和索引缺失有关。需要优化接口查询逻辑，减少不必要的字段和关联查询，并考虑增加合适的索引。", targetVersion: "v3.8.0", updatedAt: Date().addingTimeInterval(-3600), assignee: "陈宇", sourceURL: nil),
        Ticket(id: 18422, projectID: "ops", projectName: "运营后台", kind: .suggestion, priority: .normal, status: .feedback, title: "操作日志增加筛选条件", description: "希望在操作日志页面增加按时间、操作人、操作类型筛选的功能，提升日志查询效率。", targetVersion: "v3.8.0", updatedAt: Date().addingTimeInterval(-10800), assignee: "陈宇", sourceURL: nil),
        Ticket(id: 18421, projectID: "ops", projectName: "运营后台", kind: .bug, priority: .normal, status: .processing, title: "通知模板变量解析错误", description: "部分通知模板中的变量无法正确解析，导致发送内容缺失，需要修复模板渲染逻辑。", targetVersion: "v3.7.0", updatedAt: Date().addingTimeInterval(-18000), assignee: "陈宇", sourceURL: nil),
        Ticket(id: 18420, projectID: "ops", projectName: "运营后台", kind: .support, priority: .normal, status: .new, title: "新增数据导入模板下载", description: "支持在导入页面下载标准模板文件，并提供字段说明，降低用户使用成本。", targetVersion: "v3.8.0", updatedAt: Date().addingTimeInterval(-86400), assignee: "陈宇", sourceURL: nil),
        Ticket(id: 18419, projectID: "ops", projectName: "运营后台", kind: .bug, priority: .high, status: .feedback, title: "短信发送偶发失败", description: "部分用户反馈短信发送失败，错误码为 50005，需要排查短信服务接口稳定性。", targetVersion: "v3.7.1", updatedAt: Date().addingTimeInterval(-86400), assignee: "陈宇", sourceURL: nil),
        Ticket(id: 18418, projectID: "ops", projectName: "运营后台", kind: .task, priority: .normal, status: .new, title: "后台管理页面支持暗黑模式", description: "希望后台管理系统支持暗黑模式切换，提升夜间使用体验。", targetVersion: "v3.9.0", updatedAt: Date().addingTimeInterval(-172800), assignee: "陈宇", sourceURL: nil)
    ]
}
