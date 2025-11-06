import SwiftUI
import SwiftData

@main
struct PhoneApp: App {
    // SwiftData コンテナ（DailyLogのみ登録）
    private let container: ModelContainer = {
        let schema = Schema([DailyLog.self])
        return try! ModelContainer(for: schema)
    }()

    /// ✅ アプリ起動時に WCSession をアクティベート（UIに依存しない）
    init() {
        PhoneWCManager.shared.start(with: container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            LogsView()
                .modelContainer(container)
        }
    }
}
