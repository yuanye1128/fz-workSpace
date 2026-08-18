import SwiftUI

struct WorkloadView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var scanStore: WorkloadScanStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            monthPicker
            Divider()
            results
        }
        .background(DevFlowTheme.canvas(colorScheme))
        .animation(.easeInOut(duration: 0.22), value: scanStore.isScanning)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("我的工作量")
                    .font(.system(size: 25, weight: .bold))
                Text("按已完成当月结算，可计入待测试贡献。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if scanStore.isScanning {
                Button("停止") {
                    scanStore.stopScan()
                }
                .buttonStyle(SecondaryButtonStyle())
            } else {
                Button("统计完成工作量") {
                    scanStore.startScan(using: appState)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(scanStore.selectedMonths.isEmpty)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .padding(.bottom, 20)
    }

    private var monthPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("月份")
                    .font(.system(size: 12, weight: .semibold))
                Picker("年份", selection: $scanStore.selectedYear) {
                    ForEach(yearOptions, id: \.self) { year in
                        Text(String(year)).tag(year)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 96)
                .disabled(scanStore.isScanning)
                Spacer()
                Button("全选") { scanStore.selectAllMonths() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(scanStore.isScanning)
                Button("清空") { scanStore.selectedMonths.removeAll() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(scanStore.isScanning)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(1...12, id: \.self) { month in
                    let key = scanStore.monthKey(month)
                    let enabled = key <= scanStore.currentMonthKey && !scanStore.isScanning
                    Button {
                        guard enabled else { return }
                        if scanStore.selectedMonths.contains(key) {
                            scanStore.selectedMonths.remove(key)
                        } else {
                            scanStore.selectedMonths.insert(key)
                        }
                    } label: {
                        Text("\(month)月")
                            .font(.system(size: 13, weight: scanStore.selectedMonths.contains(key) ? .semibold : .medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.5))
                            .background(
                                scanStore.selectedMonths.contains(key)
                                    ? DevFlowTheme.selectedFill(colorScheme)
                                    : Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .onChange(of: scanStore.selectedYear) { newYear in
            scanStore.selectedMonths = scanStore.selectedMonths.filter {
                $0.hasPrefix("\(newYear)-") && $0 <= scanStore.currentMonthKey
            }
        }
    }

    private var results: some View {
        Group {
            if scanStore.isScanning, let scanProgress = scanStore.scanProgress {
                centeredScanProgress(scanProgress)
                    .transition(.opacity)
            } else if scanStore.rows.isEmpty {
                emptyState
                    .transition(.opacity)
            } else {
                resultContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func centeredScanProgress(_ progress: WorkloadScanProgress) -> some View {
        VStack(spacing: 22) {
            WorkloadRingProgress(fraction: progress.fractionCompleted, percent: progress.percent)
            VStack(spacing: 8) {
                Text(progress.title)
                    .font(.system(size: 18, weight: .semibold))
                Text(progress.detailText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                if progress.percent == nil, !progress.counterText.isEmpty {
                    Text(progress.counterText)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(DevFlowTheme.accent)
                } else if let total = progress.total {
                    Text("\(progress.completed) / \(total)")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(progress.title)
        .accessibilityValue(
            progress.counterText.isEmpty
                ? progress.detailText
                : "\(progress.counterText)，\(progress.detailText)"
        )
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(DevFlowTheme.accent)
            Text("还没有统计结果")
                .font(.system(size: 18, weight: .semibold))
            Text(scanStore.status)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("只会统计已发生月份的完成工作量，不会改知识库工单。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
    }

    private var resultContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(scanStore.status)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
                .padding(.top, 14)
            WorkloadChartView(stats: WorkloadMonthlyStats.build(months: scanStore.scannedMonths, rows: scanStore.rows))
                .padding(.horizontal, 28)
                .padding(.top, 16)
            Spacer(minLength: 0)
        }
    }

    private var yearOptions: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((current - 3)...current)
    }
}

private struct WorkloadRingProgress: View {
    var fraction: Double?
    var percent: Int?

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 10)
            if let fraction {
                Circle()
                    .trim(from: 0, to: min(1, max(0.001, fraction)))
                    .stroke(
                        DevFlowTheme.accent,
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.22), value: fraction)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { timeline in
                    let turn = timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.15) / 1.15
                    Circle()
                        .trim(from: 0, to: 0.22)
                        .stroke(
                            DevFlowTheme.accent,
                            style: StrokeStyle(lineWidth: 10, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90 + turn * 360))
                }
            }
            if let percent {
                VStack(spacing: 0) {
                    Text("\(percent)")
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("%")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 172, height: 172)
        .accessibilityHidden(true)
    }
}
