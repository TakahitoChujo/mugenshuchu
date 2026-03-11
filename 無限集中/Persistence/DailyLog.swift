import Foundation    // ← これを追加
import SwiftData

@Model
final class DailyLog {
    @Attribute(.unique) var ymd: String      // 主キー（日付）
    var focusSeconds: Int
    var breakSeconds: Int
    var sessions: Int
    var updatedAt: Date

    init(ymd: String, focusSeconds: Int, breakSeconds: Int, sessions: Int, updatedAt: Date) {
        self.ymd = ymd
        self.focusSeconds = focusSeconds
        self.breakSeconds = breakSeconds
        self.sessions = sessions
        self.updatedAt = updatedAt
    }
}
