import Foundation
import SwiftData
import WatchConnectivity

final class PhoneWCManager: NSObject, WCSessionDelegate {
    static let shared = PhoneWCManager()
    var context: ModelContext!

    func start(with context: ModelContext) {
        self.context = context
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: - WCSessionDelegate (iOS側 必須メソッド)

    // iOSで必須: セッションアクティベート完了
    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        // 必要なら print などでデバッグ
        // print("WC activate: \(activationState) err: \(String(describing: error))")
    }

    // iOSで必須: Watchの切替などで一時的に非アクティブになる
    func sessionDidBecomeInactive(_ session: WCSession) {
        // no-op
    }

    // iOSで必須: 非アクティブ解除時に呼ばれる。再アクティブしておく
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    // MARK: - 受信（Watch -> iPhone）
    // transferUserInfo(...) で送られてきたデータがここに来る
    func session(_ session: WCSession,
                 didReceiveUserInfo userInfo: [String : Any] = [:]) {

        // 期待形式: dailySummary
        guard userInfo["type"] as? String == "dailySummary",
              let ymd = userInfo["ymd"] as? String,
              let focus = userInfo["focusSeconds"] as? Int,
              let brk = userInfo["breakSeconds"] as? Int,
              let ses = userInfo["sessions"] as? Int,
              let ts  = userInfo["updatedAt"] as? TimeInterval else {
            return
        }

        Task { @MainActor in
            // その日のログがあれば更新、なければ新規保存
            let q = FetchDescriptor<DailyLog>(predicate: #Predicate { $0.ymd == ymd })
            if let ex = try? context.fetch(q).first {
                // 既存より新しければ上書き
                if ts > ex.updatedAt.timeIntervalSince1970 {
                    ex.focusSeconds = focus
                    ex.breakSeconds = brk
                    ex.sessions = ses
                    ex.updatedAt = Date(timeIntervalSince1970: ts)
                    try? context.save()
                }
            } else {
                // 新しい日なら挿入
                let log = DailyLog(
                    ymd: ymd,
                    focusSeconds: focus,
                    breakSeconds: brk,
                    sessions: ses,
                    updatedAt: Date(timeIntervalSince1970: ts)
                )
                context.insert(log)
                try? context.save()
            }

            pruneIfNeeded()
        }
    }

    // MARK: - ログを最大365日ぶんに丸める
    @MainActor
    private func pruneIfNeeded() {
        let all = (try? context.fetch(
            FetchDescriptor<DailyLog>(
                sortBy: [SortDescriptor(\.ymd, order: .reverse)]
            )
        )) ?? []

        if all.count > 365 {
            for item in all.dropFirst(365) {
                context.delete(item)
            }
            try? context.save()
        }
    }
}
