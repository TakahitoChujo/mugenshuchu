import SwiftUI
import SwiftData
import Charts
import Combine

enum AggregateMode: String, CaseIterable, Identifiable {
    case week = "週"
    case month = "月"
    var id: Self { self }
}

struct PeriodBin: Identifiable, Hashable {
    let id = UUID()
    let key: String
    let label: String
    let startDate: Date
    let endDate: Date
    let focusSeconds: Int
    let breakSeconds: Int
    let sessions: Int
}

// Calendar / DateFormatter 共通
private struct CalendarEnv {
    let cal: Calendar
    let dfSubtitle: DateFormatter
    let dfYMD: DateFormatter

    init() {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "ja_JP")
        c.firstWeekday = 2 // 月曜はじまり
        cal = c

        let df = DateFormatter()
        df.locale = c.locale
        df.calendar = c
        df.dateFormat = "M/d"
        dfSubtitle = df

        let df2 = DateFormatter()
        df2.locale = c.locale
        df2.calendar = c
        df2.dateFormat = "yyyy-MM-dd"
        dfYMD = df2
    }

    func dateFromYMD(_ ymd: String) -> Date? {
        let comps = ymd.split(separator: "-").compactMap { Int($0) }
        guard comps.count == 3 else { return nil }
        return cal.date(from: DateComponents(year: comps[0], month: comps[1], day: comps[2]))
    }

    func ymdString(from date: Date) -> String {
        dfYMD.string(from: date)
    }

    func weekBounds(for date: Date) -> (Date, Date) {
        let start = cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        let end = cal.date(byAdding: .day, value: 6, to: start) ?? date
        return (start, end)
    }

    func monthBounds(for date: Date) -> (Date, Date) {
        let y = cal.component(.year, from: date)
        let m = cal.component(.month, from: date)
        let start = cal.date(from: DateComponents(year: y, month: m, day: 1))!
        let range = cal.range(of: .day, in: .month, for: start)!
        let end = cal.date(byAdding: .day, value: range.count - 1, to: start)!
        return (start, end)
    }

    func binTitle(_ bin: PeriodBin, mode: AggregateMode) -> String {
        switch mode {
        case .week:
            let y = cal.component(.yearForWeekOfYear, from: bin.startDate)
            return "\(y)年 \(bin.label)"
        case .month:
            let y = cal.component(.year, from: bin.startDate)
            return "\(y)年 \(bin.label)"
        }
    }

    func binSubtitle(_ bin: PeriodBin) -> String {
        "\(dfSubtitle.string(from: bin.startDate)) 〜 \(dfSubtitle.string(from: bin.endDate))"
    }

    func previousDay(_ date: Date) -> Date? {
        cal.date(byAdding: .day, value: -1, to: date)
    }
}

// 中央のリング
private struct RingView: View {
    let progress: Double      // 0.0 ... 1.0
    let mainText: String      // "45分"
    let subText: String       // "目標60分"

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 10)

            Circle()
                .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [.orange, .pink, .orange]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 4) {
                Text(mainText)
                    .font(.title2)
                    .bold()
                    .monospacedDigit()
                Text(subText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 120, height: 120)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(subText)に対して\(mainText)")
    }
}

struct LogsView: View {
    @Query(sort: \DailyLog.ymd, order: .forward)
    private var logs: [DailyLog] // 古い→新しい

    @State private var mode: AggregateMode = .week
    @AppStorage("targetMinutesPerDay") private var targetMinutesPerDay: Int = 60

    private let env = CalendarEnv()

    // 今日のログ
    private var todayLog: DailyLog? {
        let todayYMD = env.ymdString(from: Date())
        // logs は古い→新しいなので、後ろから探す方が速い
        return logs.last { $0.ymd == todayYMD }
    }

    // 今日の集中合計（秒）
    private var todayFocusSeconds: Int {
        todayLog?.focusSeconds ?? 0
    }

    // 今日の目標達成率
    private var todayProgress: Double {
        let doneMin = todayFocusSeconds / 60
        guard targetMinutesPerDay > 0 else { return 0 }
        return Double(doneMin) / Double(targetMinutesPerDay)
    }

    // streak 日数（休憩だけの日はノーカン）
    // ルール：
    //   その日の focusSeconds > 0 の日が連続している限りカウントを伸ばす
    //   0 の日が出たらそこで止める
    private var streakDays: Int {
        // mapにしてO(1)アクセス
        var focusByYMD: [String:Int] = [:]
        for l in logs {
            focusByYMD[l.ymd] = l.focusSeconds
        }

        var count = 0
        var cursor = Date() // 今日
        while true {
            let key = env.ymdString(from: cursor)
            let focus = focusByYMD[key] ?? 0
            if focus > 0 {
                count += 1
            } else {
                // 集中0日が来たら連続終了
                break
            }
            guard let prev = env.previousDay(cursor) else { break }
            cursor = prev
        }
        return count
    }

    // 集計（週or月）
    private var bins: [PeriodBin] {
        let all = aggregate(logs: logs, by: mode, env: env)
        return Array(all.suffix(12)) // 直近12だけ
    }

    // サマリ
    private var totalFocusSec: Int {
        bins.reduce(0) { $0 + $1.focusSeconds }
    }
    private var totalBreakSec: Int {
        bins.reduce(0) { $0 + $1.breakSeconds }
    }
    private var totalSessions: Int {
        bins.reduce(0) { $0 + $1.sessions }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {

                    // 1. 今日のダッシュボード
                    dashboardCard

                    // 2. 週/月セグメント + 合計
                    headerBlock

                    // 3. グラフ
                    chartBlock

                    // 4. 期間ごとのカードリスト
                    listBlock
                }
                .padding(.bottom, 16)
            }
            .navigationTitle("集中時間記録")
            .toolbar {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .imageScale(.medium)
                }
            }
        }
    }

    // MARK: - 1. ダッシュボード
    private var dashboardCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                RingView(
                    progress: todayProgress,
                    mainText: "\(todayFocusSeconds / 60)分",
                    subText: "目標\(targetMinutesPerDay)分"
                )

                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("今日の集中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(todayFocusSeconds / 60)分 集中")
                            .font(.headline)
                            .monospacedDigit()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("連続日数")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(streakDays)日 継続中")
                            .font(.headline)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal)
        .padding(.top)
    }

    // MARK: - 2. 週/月セグメント + 合計
    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("表示", selection: $mode) {
                ForEach(AggregateMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            #if os(iOS)
            .pickerStyle(.segmented)
            #endif

            HStack {
                statBlock(title: "集中", seconds: totalFocusSec)
                Divider().frame(height: 22)
                statBlock(title: "休憩", seconds: totalBreakSec)
                Divider().frame(height: 22)
                VStack(alignment: .leading) {
                    Text("回数")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(totalSessions)")
                        .font(.headline)
                        .monospacedDigit()
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .padding(.horizontal)
    }

    private func statBlock(title: String, seconds: Int) -> some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(minutesText(seconds))
                .font(.headline)
                .monospacedDigit()
        }
    }

    // MARK: - 3. グラフ
    private var chartBlock: some View {
        VStack(alignment: .leading, spacing: 8) {

            Chart {
                ForEach(bins) { bin in
                    // 集中 = オレンジ
                    BarMark(
                        x: .value("期間", bin.label),
                        y: .value("分", bin.focusSeconds / 60)
                    )
                    .foregroundStyle(.orange)

                    // 休憩 = 青
                    BarMark(
                        x: .value("期間", bin.label),
                        y: .value("分", bin.breakSeconds / 60)
                    )
                    .foregroundStyle(.blue)
                }
            }
            .chartYAxisLabel("分")
            .frame(height: 220)

            // カスタム凡例
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 10, height: 10)
                    Text("集中")
                        .font(.caption)
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 10, height: 10)
                    Text("休憩")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .padding(.horizontal)
    }

    // MARK: - 4. 期間リスト
    private var listBlock: some View {
        VStack(spacing: 12) {
            ForEach(bins) { bin in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(env.binTitle(bin, mode: mode))
                            .font(.headline)

                        Text(env.binSubtitle(bin))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("集中 \(minutesText(bin.focusSeconds))")
                        Text("休憩 \(minutesText(bin.breakSeconds))")
                            .foregroundStyle(.secondary)
                        Text("回数 \(bin.sessions)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .monospacedDigit()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .padding(.horizontal)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - 集計ロジック
    private func aggregate(logs: [DailyLog], by mode: AggregateMode, env: CalendarEnv) -> [PeriodBin] {
        var dict: [String: PeriodBin] = [:]

        for l in logs {
            guard let date = env.dateFromYMD(l.ymd) else { continue }

            switch mode {
            case .week:
                let year = env.cal.component(.yearForWeekOfYear, from: date)
                let week = env.cal.component(.weekOfYear, from: date)
                let key  = String(format: "%04d-W%02d", year, week)
                let (start, end) = env.weekBounds(for: date)

                var bin = dict[key] ?? PeriodBin(
                    key: key,
                    label: "W\(week)",
                    startDate: start,
                    endDate: end,
                    focusSeconds: 0,
                    breakSeconds: 0,
                    sessions: 0
                )

                bin = PeriodBin(
                    key: bin.key,
                    label: bin.label,
                    startDate: bin.startDate,
                    endDate: bin.endDate,
                    focusSeconds: bin.focusSeconds + l.focusSeconds,
                    breakSeconds: bin.breakSeconds + l.breakSeconds,
                    sessions: bin.sessions + l.sessions
                )

                dict[key] = bin

            case .month:
                let y = env.cal.component(.year, from: date)
                let m = env.cal.component(.month, from: date)
                let key = String(format: "%04d-%02d", y, m)
                let (start, end) = env.monthBounds(for: date)

                var bin = dict[key] ?? PeriodBin(
                    key: key,
                    label: "\(m)月",
                    startDate: start,
                    endDate: end,
                    focusSeconds: 0,
                    breakSeconds: 0,
                    sessions: 0
                )

                bin = PeriodBin(
                    key: bin.key,
                    label: bin.label,
                    startDate: bin.startDate,
                    endDate: bin.endDate,
                    focusSeconds: bin.focusSeconds + l.focusSeconds,
                    breakSeconds: bin.breakSeconds + l.breakSeconds,
                    sessions: bin.sessions + l.sessions
                )

                dict[key] = bin
            }
        }

        return dict.values.sorted { a, b in
            a.startDate < b.startDate
        }
    }

    // 分表示
    private func minutesText(_ seconds: Int) -> String {
        let totalMin = seconds / 60
        if totalMin >= 60 {
            let h = totalMin / 60
            let rm = totalMin % 60
            return "\(h)時間\(rm)分"
        } else {
            return "\(totalMin)分"
        }
    }
}
