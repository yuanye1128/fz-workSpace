import AppKit
import SwiftUI

struct TicketCardView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false
    let ticket: Ticket

    private let cornerRadius: CGFloat = 12
    private let cardMinHeight: CGFloat = 296

    private var selected: Bool {
        appState.selectedTicket?.id == ticket.id
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var issueLinkColor: Color {
        selected ? DevFlowTheme.accent : Color.secondary
    }

    private var displayStatus: TicketStatus {
        if let item = appState.activeWorkItem(for: ticket.id) {
            if item.stage.requiresUserApproval { return ticket.status }
            return .processing
        }
        return ticket.status
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Button {
                    if let url = ticket.sourceURL {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(ticket.kind.rawValue)
                        Text(ticket.issueNumber)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(issueLinkColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .hoverHighlight(cornerRadius: 6)
                }
                .buttonStyle(.plain)
                .disabled(ticket.sourceURL == nil)
                .help(ticket.sourceURL == nil ? "暂无原工单地址" : "打开原工单")

                TagPill(text: ticket.priority.rawValue, color: ticket.priority.color, emphasized: true)

                Spacer(minLength: 8)

                Text(ticket.projectName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(ticket.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)

            Text(ticket.displayDescription)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(DevFlowTheme.secondaryText(colorScheme))
                .lineSpacing(4)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TagPill(text: displayStatus.rawValue, color: displayStatus.color)
                Spacer()
                Text(ticket.targetVersion)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Divider()

            HStack {
                Text("更新于 \(ticket.updatedAt.devFlowTicketUpdatedText)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if ticket.status != .testing {
                    if appState.destination == .processing {
                        Button("移除") {
                            appState.removeFromProcessing(ticketID: ticket.id)
                        }
                        .buttonStyle(CardActionButtonStyle())
                    } else {
                        Button("去解决") {
                            appState.open(ticket: ticket, focusSolve: true)
                        }
                        .buttonStyle(CardActionButtonStyle())
                    }
                }
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, minHeight: cardMinHeight, alignment: .topLeading)
        .background(DevFlowTheme.surface(colorScheme))
        .clipShape(cardShape)
        .overlay {
            cardShape.strokeBorder(
                selected ? DevFlowTheme.accent : DevFlowTheme.border(colorScheme),
                lineWidth: selected ? 2 : 1
            )
        }
        .compositingGroup()
        .shadow(color: .black.opacity(hovering ? 0.10 : 0.045), radius: hovering ? 8 : 3, x: 0, y: hovering ? 3 : 1)
        .contentShape(cardShape)
        .onTapGesture { appState.open(ticket: ticket) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ticket.kind.rawValue) \(ticket.issueNumber)，\(ticket.title)，\(ticket.priority.rawValue)，\(displayStatus.rawValue)")
        .accessibilityAction(named: "查看详情") { appState.open(ticket: ticket) }
    }
}

struct TicketListRow: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let ticket: Ticket

    private var selected: Bool {
        appState.selectedTicket?.id == ticket.id
    }

    private var displayStatus: TicketStatus {
        if let item = appState.activeWorkItem(for: ticket.id), !item.stage.requiresUserApproval {
            return .processing
        }
        return ticket.status
    }

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(ticket.priority.color.opacity(ticket.priority == .normal ? 0.35 : 0.88))
                .frame(width: 4, height: 44)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Button {
                        if let url = ticket.sourceURL {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Text(ticket.issueNumber)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selected ? DevFlowTheme.accent : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                            .hoverHighlight(cornerRadius: 6)
                    }
                    .buttonStyle(.plain)
                    .disabled(ticket.sourceURL == nil)
                    .help(ticket.sourceURL == nil ? "暂无原工单地址" : "打开原工单")
                    Text(ticket.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(ticket.projectName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    TagPill(text: ticket.kind.rawValue, color: ticket.kind.color)
                    TagPill(text: ticket.priority.rawValue, color: ticket.priority.color)
                    TagPill(text: displayStatus.rawValue, color: displayStatus.color)
                    Text(ticket.targetVersion)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(ticket.updatedAt.devFlowTicketUpdatedText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            if ticket.status != .testing {
                if appState.destination == .processing {
                    Button("移除") {
                        appState.removeFromProcessing(ticketID: ticket.id)
                    }
                    .buttonStyle(CardActionButtonStyle())
                } else {
                    Button("去解决") {
                        appState.open(ticket: ticket, focusSolve: true)
                    }
                    .buttonStyle(CardActionButtonStyle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(DevFlowTheme.surface(colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? DevFlowTheme.accent : DevFlowTheme.border(colorScheme), lineWidth: selected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { appState.open(ticket: ticket) }
    }
}
