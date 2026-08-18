import SwiftUI

struct WorkloadChartView: View {
    let stats: WorkloadMonthlyStats
    @Environment(\.colorScheme) private var colorScheme
    @State private var revealed = false

    private static let barWidth: CGFloat = 40
    private static let columnWidth: CGFloat = 72

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("各月条数与环比")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("共 \(stats.total) 条")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if stats.usesVerticalLayout {
                verticalBars
            } else {
                columnBars
            }
        }
        .padding(16)
        .background(
            DevFlowTheme.surface(colorScheme),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DevFlowTheme.border(colorScheme))
        )
        .onAppear {
            revealed = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("各月工单条数与环比")
    }

    private var columnBars: some View {
        HStack(alignment: .bottom, spacing: 18) {
            ForEach(Array(stats.series.enumerated()), id: \.element.id) { index, item in
                VStack(spacing: 8) {
                    VStack(spacing: 2) {
                        Text("\(item.count)")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        if index > 0 {
                            momLabel(item.mom)
                        }
                    }
                    .frame(height: 38)

                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: Self.barWidth, height: 148)
                        .overlay(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(barFill)
                                .frame(width: Self.barWidth, height: barHeight(item.count, in: 148))
                                .animation(.easeOut(duration: 0.65).delay(Double(index) * 0.045), value: revealed)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Text(item.chartLabel(multiYear: stats.isMultiYear))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: Self.columnWidth)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(columnAccessibility(item, index: index))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verticalBars: some View {
        VStack(spacing: 10) {
            ForEach(Array(stats.series.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 10) {
                    Text(item.chartLabel(multiYear: stats.isMultiYear))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: stats.isMultiYear ? 72 : 44, alignment: .trailing)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.08))
                            Capsule()
                                .fill(barFill)
                                .frame(width: barHeight(item.count, in: geo.size.width))
                                .animation(.easeOut(duration: 0.65).delay(Double(index) * 0.04), value: revealed)
                        }
                    }
                    .frame(height: 10)
                    HStack(spacing: 8) {
                        Text("\(item.count)")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .frame(minWidth: 24, alignment: .trailing)
                        if index > 0 {
                            momLabel(item.mom)
                        }
                    }
                    .frame(width: 92, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(columnAccessibility(item, index: index))
            }
        }
    }

    private func barHeight(_ count: Int, in limit: CGFloat) -> CGFloat {
        guard revealed, count > 0 else { return 0 }
        return max(6, limit * CGFloat(count) / CGFloat(stats.maxCount))
    }

    private var barFill: LinearGradient {
        LinearGradient(
            colors: [
                DevFlowTheme.accent.opacity(colorScheme == .dark ? 0.95 : 0.82),
                DevFlowTheme.accent
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func momLabel(_ mom: WorkloadMonthOverMonth) -> some View {
        Text("环比 \(mom.label)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(momColor(mom))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func momColor(_ mom: WorkloadMonthOverMonth) -> Color {
        if mom.isIncrease { return DevFlowTheme.danger }
        if mom.isDecrease { return DevFlowTheme.success }
        return Color.secondary.opacity(0.75)
    }

    private func columnAccessibility(_ item: WorkloadMonthStat, index: Int) -> String {
        if index == 0 {
            return "\(item.chartLabel(multiYear: stats.isMultiYear)) \(item.count) 条"
        }
        return "\(item.chartLabel(multiYear: stats.isMultiYear)) \(item.count) 条，环比 \(item.mom.label)"
    }
}
