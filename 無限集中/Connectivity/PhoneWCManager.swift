import Foundation
import WatchConnectivity
import SwiftData

/// iPhone側の WatchConnectivity 管理
final class PhoneWCManager: NSObject, WCSessionDelegate {
    static let shared = PhoneWCManager()

    private var isStarted = false
    private var context: ModelContext?

    private override init() { super.init() }

    /// アプリ起動時に1回だけ呼ぶ（重複起動は無視）
    func start(with context: ModelContext) {
        guard WCSession.isSupported() else { return }
        if isStarted { return }
        isStarted = true

        self.context = context
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    /// Watch からの日次サマリ受信（バックグラウンドでも呼ばれる）
    /// 期待キー: ymd(String "YYYY-MM-DD"), focus(Int), break(Int), sessions(Int), ts(TimeInterval)
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        guard let ctx = context else { return }

        let ymd      = (userInfo["ymd"] as? String) ?? Self.makeYMD(from: Date())
        let focus    = (userInfo["focus"] as? Int) ?? (userInfo["focusSeconds"] as? Int) ?? 0
        let brk      = (userInfo["break"] as? Int) ?? (userInfo["breakSeconds"] as? Int) ?? 0
        let sessions = (userInfo["sessions"] as? Int) ?? 0
        let ts       = (userInfo["ts"] as? TimeInterval) ?? Date().timeIntervalSince1970

        updateDailyLog(ctx: ctx, ymd: ymd, focus: focus, brk: brk, ses: sessions, ts: ts)
    }

    // MARK: - 保存ロジック（逆戻り防止つき）
    private func updateDailyLog(ctx: ModelContext, ymd: String, focus: Int, brk: Int, ses: Int, ts: TimeInterval) {
        var fd = FetchDescriptor<DailyLog>(predicate: #Predicate { $0.ymd == ymd })
        fd.fetchLimit = 1

        do {
            if let existing = try ctx.fetch(fd).first {
                // 値が小さく来たら既存を優先（逆戻り防止）
                let mergedFocus = max(existing.focusSeconds, focus)
                let mergedBreak = max(existing.breakSeconds, brk)
                let mergedSes   = max(existing.sessions, ses)
                let mergedTS    = max(existing.updatedAt.timeIntervalSince1970, ts)

                if mergedFocus != existing.focusSeconds ||
                   mergedBreak != existing.breakSeconds ||
                   mergedSes   != existing.sessions     ||
                   mergedTS    >  existing.updatedAt.timeIntervalSince1970 {

                    existing.focusSeconds = mergedFocus
                    existing.breakSeconds = mergedBreak
                    existing.sessions     = mergedSes
                    existing.updatedAt    = Date(timeIntervalSince1970: mergedTS)
                    try ctx.save()
                }
            } else {
                // 新規
                let log = DailyLog(
                    ymd: ymd,
                    focusSeconds: max(0, focus),
                    breakSeconds: max(0, brk),
                    sessions: max(0, ses),
                    updatedAt: Date(timeIntervalSince1970: ts)
                )
                ctx.insert(log)
                try ctx.save()
            }
        } catch {
            // print("SwiftData update error: \(error)")
        }
    }

    // MARK: - 補助
    private static func makeYMD(from date: Date) -> String {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "ja_JP_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }
}
