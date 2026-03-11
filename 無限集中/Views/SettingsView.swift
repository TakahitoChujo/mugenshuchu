import SwiftUI

struct SettingsView: View {
    @AppStorage("targetMinutesPerDay") private var targetMinutesPerDay: Int = 60

    var body: some View {
        Form {
            Section(header: Text("1日の目標")) {
                Stepper(
                    value: $targetMinutesPerDay,
                    in: 10...300,
                    step: 5
                ) {
                    HStack {
                        Text("目標集中時間")
                        Spacer()
                        Text("\(targetMinutesPerDay)分")
                            .monospacedDigit()
                            .foregroundColor(.primary)
                    }
                }
                Text("この分数以上 集中した日を『達成』としてカウントします。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text("目標は端末に保存されます（iCloudなしでOK）。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("設定")
    }
}
