import SwiftUI
import SwiftData

@main
struct PhoneApp: App {
    // SwiftData コンテナ
    var container: ModelContainer = {
        let schema = Schema([DailyLog.self])
        return try! ModelContainer(for: schema)
    }()

    var body: some Scene {
        WindowGroup {
            LogsView()                            // ← 別ファイルの LogsView を使用
                .modelContainer(container)        // SwiftData 注入
                .onAppear {
                    PhoneWCManager.shared.start(with: container.mainContext)
                }
        }
    }
}
