import SwiftUI

enum DevFlowTheme {
    static let accent = Color(red: 0.13, green: 0.38, blue: 0.88)
    static let accentDark = Color(red: 0.31, green: 0.55, blue: 1.0)
    static let success = Color(red: 0.16, green: 0.65, blue: 0.42)
    static let warning = Color(red: 0.95, green: 0.55, blue: 0.18)
    static let danger = Color(red: 0.94, green: 0.24, blue: 0.28)

    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.059, green: 0.067, blue: 0.082) : Color(red: 0.975, green: 0.98, blue: 0.99)
    }

    static func sidebar(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.075, green: 0.086, blue: 0.106).opacity(0.36)
            : Color(red: 0.925, green: 0.94, blue: 0.965).opacity(0.18)
    }

    static func sidebarSeparator(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.085) : Color.white.opacity(0.72)
    }

    static func sidebarShadow(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.34) : Color.black.opacity(0.10)
    }

    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.102, green: 0.118, blue: 0.149) : .white
    }

    static func elevatedSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.126, green: 0.145, blue: 0.184) : .white
    }

    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.09)
    }

    static func secondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.66, green: 0.70, blue: 0.77) : Color(red: 0.39, green: 0.44, blue: 0.52)
    }

    static func selectedFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? accentDark.opacity(0.14) : accent.opacity(0.09)
    }
}

extension TicketPriority {
    var color: Color {
        switch self {
        case .urgent: DevFlowTheme.danger
        case .high: DevFlowTheme.warning
        case .normal: Color.secondary
        }
    }
}

extension TicketKind {
    var color: Color {
        switch self {
        case .bug: DevFlowTheme.danger
        case .feature: DevFlowTheme.warning
        case .suggestion: Color.mint
        case .support: Color.teal
        case .task: Color.indigo
        }
    }
}

extension TicketStatus {
    var color: Color {
        switch self {
        case .new: DevFlowTheme.accent
        case .processing: DevFlowTheme.success
        case .feedback: DevFlowTheme.warning
        case .testing: Color.indigo
        case .completed: Color.secondary
        }
    }
}
