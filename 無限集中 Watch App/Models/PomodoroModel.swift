import Foundation
import WatchKit
import Combine
import UserNotifications
import WatchConnectivity

/// Apple Watch側 ポモドーロモデル（安定版）
/// - 表示用の残り時間は「開始時の残り秒 - floor(経過秒)」で管理
///   → 開始直後/再開直後にいきなり2秒飛ばない
/// - フェーズ終了判定と通知スケジュールは targetEnd で管理
/// - pause中はカウント停止した状態を正確に保持
/// - フェーズ終了は非同期で安全に遷移
/// - 日次集計はiPhoneに送信
final class PomodoroModel: NSObject, ObservableObject, WCSessionDelegate {

    enum Phase {
        case idle
        case focus
        case shortBreak
        case longBreak
    }

    // ===== UIに公開する状態 =====
    @Published var phase: Phase = .idle
    @Published var remaining: Int = 0             // 画面に出す残り秒
    @Published var isActive: Bool = false         // カウントダウンが進行中か
    @Published var isPaused: Bool = false         // 一時停止中か
    @Published var focusMinutes: Int = 25         // 次の集中セッション分数
    @Published var totalPhaseSeconds: Int = 0     // このフェーズの総秒数（リング100%）

    // ===== 内部状態 =====
    private var tickTimer: AnyCancellable?        // 1秒ごとの更新タイマー

    // 可視カウント用の基準：
    //   startReferenceTime … このフェーズ（or再開）をスタートした基準時刻
    //   startRemainingSeconds … スタート時点での「残り秒」
    //
    // UI表示では:
    //   elapsed = floor(now - startReferenceTime)
    //   remaining = max(startRemainingSeconds - elapsed, 0)
    //
    // pauseするときは、この時点の remaining を保存しておき、
    // resumeするときはそれを startRemainingSeconds に復元しなおす。
    private var startReferenceTime: Date?
    private var startRemainingSeconds: Int = 0

    // フェーズ全体の「本来の終了予定時刻」。
    // - バックグラウンド終了判定・ローカル通知スケジュール用
    // - pause中は無効化(nil)
    private var targetEnd: Date?

    // pause中に保持するスナップショット
    private var pausedRemaining: Int?
    private var pauseStart: Date?

    // 日次集計用
    private var focusAccumSecToday: Int = 0
    private var breakAccumSecToday: Int = 0
    private var sessionCountToday: Int = 0
    private var summaryDateYMD: String = ""   // "yyyy-MM-dd"

    // iPhone連携
    private lazy var wcSession: WCSession = {
        let s = WCSession.default
        if WCSession.isSupported() {
            s.delegate = self
            s.activate()
        }
        return s
    }()

    override init() {
        super.init()
        summaryDateYMD = Self.makeYMD(Date())
        _ = wcSession
        requestNotificationPermission()
    }

    // MARK: - 公開操作

    func startFocus() {
        startPhase(.focus)
    }

    func startShortBreak() {
        startPhase(.shortBreak)
    }

    func startLongBreak() {
        startPhase(.longBreak)
    }

    func pause() {
        guard isActive, !isPaused else { return }

        // 最新表示を確定させる
        updateRemainingNow()

        isPaused = true
        isActive = false

        pausedRemaining = remaining
        pauseStart = Date()

        // pause中は targetEnd を無効化する
        targetEnd = nil

        // 実行中のtickTimerを止める
        tickTimer?.cancel()
        tickTimer = nil
    }

    func resume() {
        guard isPaused, let still = pausedRemaining else { return }

        isPaused = false
        isActive = true

        // 再開基準をセット：
        // 「今この瞬間から still 秒残ってます」を、きっちり固定する
        startReferenceTime = Date()
        startRemainingSeconds = still

        // 表示もその still 秒から再開
        remaining = still

        // targetEnd を新しく張り直す（通知とフェーズ終了チェック用）
        targetEnd = Date().addingTimeInterval(TimeInterval(still))

        pausedRemaining = nil
        pauseStart = nil

        // 終了通知を再スケジュール
        schedulePhaseEndNotification(after: still)

        // tick再開
        startTicking()
    }

    func stop() {
        // 最新表示を確定させた上で集計
        updateRemainingNow()
        finalizeCurrentPhaseContribution()
        sendDailySummaryToPhone()

        // 全リセット
        tickTimer?.cancel()
        tickTimer = nil

        isActive = false
        isPaused = false
        phase = .idle

        remaining = 0
        totalPhaseSeconds = 0

        startReferenceTime = nil
        startRemainingSeconds = 0

        targetEnd = nil
        pausedRemaining = nil
        pauseStart = nil

        cancelScheduledNotification()
    }

    /// 画面復帰などで「今の正しい残り」を反映したいときに呼べる
    func refreshFromNow() {
        updateRemainingNow()
    }

    // MARK: - 内部: 残り時間計算と進行

    /// 現在時刻に基づいて remaining を更新し、0秒以下なら次フェーズへ進む準備をする。
    private func updateRemainingNow() {
        if isActive && !isPaused {
            // 動いてる場合は startReferenceTime からの経過で残りを出す
            guard let ref = startReferenceTime else {
                // 異常系防御：なかったら触らない
                return
            }
            let elapsed = max(0, Int(floor(Date().timeIntervalSince(ref))))
            let newRemain = max(startRemainingSeconds - elapsed, 0)
            remaining = newRemain

            if newRemain <= 0 {
                // 0になったら次フェーズへ。ただしその場で即切り替えると
                // tickTimer内で再帰的に動くので少し遅らせる
                DispatchQueue.main.async { [weak self] in
                    self?.completePhaseIfNeeded()
                }
            }
        } else {
            // 止まってる場合（pause中やidle）は pausedRemaining を信じる
            if let snap = pausedRemaining {
                remaining = snap
            }
            // idleとかでpausedRemainingがnilなら今のremainingをそのまま
        }
    }

    /// 残り0ならフェーズ完了扱いにする（重複呼び出し防御あり）
    private func completePhaseIfNeeded() {
        // すでに idle なら何もしない
        guard phase != .idle else { return }

        // アクティブでなければ「本当に終わった」状況じゃない（pauseで0秒になることはあり得るので避ける）
        guard isActive, !isPaused else { return }

        // まだ残ってるなら未完了
        if remaining > 0 { return }

        // 念のため0固定
        remaining = 0

        phaseCompleted()
    }

    // MARK: - フェーズ開始／遷移

    private func startPhase(_ newPhase: Phase) {
        rollDateIfNeeded()

        phase = newPhase
        isActive = true
        isPaused = false
        pausedRemaining = nil
        pauseStart = nil

        // フェーズごとの長さを決定
        switch newPhase {
        case .focus:
            totalPhaseSeconds = focusMinutes * 60
            hapticStartFocus()
        case .shortBreak, .longBreak:
            totalPhaseSeconds = 5 * 60
            hapticStrongBreakStart()
        case .idle:
            totalPhaseSeconds = 0
        }

        // カウントダウンの基準をセット
        startReferenceTime = Date()
        startRemainingSeconds = totalPhaseSeconds
        remaining = totalPhaseSeconds

        // このフェーズが終わる予定の絶対時刻（通知・バックグラウンド判断用）
        targetEnd = Date().addingTimeInterval(TimeInterval(totalPhaseSeconds))

        // フェーズ終了タイミングのローカル通知をセット
        schedulePhaseEndNotification(after: totalPhaseSeconds)

        // tick開始
        startTicking()
    }

    /// 1秒ごとに updateRemainingNow() を呼ぶタイマーを張る
    private func startTicking() {
        tickTimer?.cancel()
        tickTimer = nil

        tickTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                // pause中/停止中は動かさない
                guard self.isActive, !self.isPaused else { return }
                self.updateRemainingNow()
            }
    }

    /// フェーズ完了後の遷移処理
    private func phaseCompleted() {
        // 最後に過ごした分を日次集計へ
        finalizeCurrentPhaseContribution()

        // 次のフェーズに進む
        switch phase {
        case .focus:
            sessionCountToday += 1
            startShortBreak()

        case .shortBreak, .longBreak:
            startFocus()

        case .idle:
            break
        }

        // iPhone側へ最新のサマリを送信
        sendDailySummaryToPhone()
    }

    /// このフェーズで消費した時間を1日分の合計に足す
    private func finalizeCurrentPhaseContribution() {
        // 最新残りを確定させて spent を出す
        updateRemainingNow()

        guard totalPhaseSeconds > 0 else { return }
        let spent = totalPhaseSeconds - remaining
        guard spent > 0 else { return }

        switch phase {
        case .focus:
            focusAccumSecToday += spent
        case .shortBreak, .longBreak:
            breakAccumSecToday += spent
        case .idle:
            break
        }
    }

    // MARK: - 日次リセット／iPhone送信

    private func rollDateIfNeeded() {
        let today = Self.makeYMD(Date())
        if today != summaryDateYMD {
            summaryDateYMD = today
            focusAccumSecToday = 0
            breakAccumSecToday = 0
            sessionCountToday = 0
        }
    }

    private func sendDailySummaryToPhone() {
        guard WCSession.isSupported() else { return }

        let payload: [String: Any] = [
            "type": "dailySummary",
            "ymd": summaryDateYMD,
            "focusSeconds": focusAccumSecToday,
            "breakSeconds": breakAccumSecToday,
            "sessions": sessionCountToday,
            "updatedAt": Date().timeIntervalSince1970
        ]
        wcSession.transferUserInfo(payload)
    }

    // MARK: - ローカル通知

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            // 失敗しても落とさない
        }
    }

    /// 今のフェーズが終わるタイミングでローカル通知（ハプティック）を入れる
    private func schedulePhaseEndNotification(after seconds: Int) {
        cancelScheduledNotification()
        guard seconds > 0 else { return }

        let content = UNMutableNotificationContent()
        switch phase {
        case .focus:
            content.title = "集中おわり"
            content.body = "休憩に入りましょう"
        case .shortBreak, .longBreak:
            content.title = "休憩おわり"
            content.body = "次の集中を始める？"
        case .idle:
            content.title = "完了"
            content.body = "次のセッションを開始できます"
        }
        content.sound = UNNotificationSound.default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(seconds),
            repeats: false
        )

        let req = UNNotificationRequest(
            identifier: "pomodoroPhaseEnd",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(req) { _ in }
    }

    private func cancelScheduledNotification() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["pomodoroPhaseEnd"])
    }

    // MARK: - ユーティリティ

    private static func makeYMD(_ date: Date) -> String {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    private func hapticStartFocus() {
        let device = WKInterfaceDevice.current()
        device.play(.start)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            device.play(.success)
        }
    }

    private func hapticStrongBreakStart() {
        let device = WKInterfaceDevice.current()
        device.play(.notification)
    }

    // MARK: - WCSessionDelegate

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // 必要ならログ出す
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        // 任意
    }
}
