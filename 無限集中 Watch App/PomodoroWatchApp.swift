import SwiftUI

@main
struct PomodoroWatchApp: App {
    @StateObject private var model = PomodoroModel()

    var body: some Scene {
        WindowGroup {
            TimerView()
                .environmentObject(model)
        }
    }
}
