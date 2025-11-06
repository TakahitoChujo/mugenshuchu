import SwiftUI
import WatchKit

struct TimerView: View {
    @EnvironmentObject var model: PomodoroModel

    @State private var crownValue: Double = 25
    @State private var showPauseDialog = false // ダイアログ表示フラグ

    // 画面サイズに応じてリングサイズ可変（40mm〜46mmで収まるやつ）:contentReference[oaicite:16]{index=16}
    private var ringSize: CGFloat {
        let bounds = WKInterfaceDevice.current().screenBounds
        let shortestSide = min(bounds.width, bounds.height)
        let base = shortestSide * 0.85
        return max(120, min(base, 180))
    }

    // リングの進捗（残り/合計）
    private var progressRatio: CGFloat {
        guard model.totalPhaseSeconds > 0 else { return 0.0 }
        let remain = CGFloat(model.remaining)
        let total = CGFloat(model.totalPhaseSeconds)
        return max(0.0, min(1.0, remain / total))
    }

    private var remainingText: String {
        timeString(from: model.remaining)
    }

    private var statusText: String {
        if model.isPaused { return "PAUSE" }
        switch model.phase {
        case .focus: return "FOCUS"
        case .shortBreak, .longBreak: return "BREAK"
        case .idle: return ""
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .focus: return .orange
        case .shortBreak, .longBreak: return .blue
        case .idle: return .clear
        }
    }

    // フェーズ別のグラデ（オレンジ/青/グレー）:contentReference[oaicite:17]{index=17}
    private var ringGradient: AngularGradient {
        let gradientColors: [Color]
        switch model.phase {
        case .focus:
            gradientColors = [
                Color(red: 0.45, green: 0.17, blue: 0.00),
                Color(red: 0.90, green: 0.40, blue: 0.00),
                Color(red: 1.00, green: 0.70, blue: 0.10),
                Color(red: 0.90, green: 0.40, blue: 0.00),
                Color(red: 0.45, green: 0.17, blue: 0.00),
            ]
        case .shortBreak, .longBreak:
            gradientColors = [
                Color(red: 0.00, green: 0.12, blue: 0.27),
                Color(red: 0.00, green: 0.25, blue: 0.60),
                Color(red: 0.00, green: 0.50, blue: 1.00),
                Color(red: 0.00, green: 0.25, blue: 0.60),
                Color(red: 0.00, green: 0.12, blue: 0.27),
            ]
        case .idle:
            gradientColors = [
                Color.gray.opacity(0.4),
                Color.gray.opacity(0.2),
                Color.gray.opacity(0.1),
                Color.gray.opacity(0.2),
                Color.gray.opacity(0.4),
            ]
        }

        return AngularGradient(
            gradient: Gradient(colors: gradientColors),
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(360)
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            mainContent
                .blur(radius: showPauseDialog ? 2 : 0)
                .animation(.easeInOut(duration: 0.15), value: showPauseDialog)

            if showPauseDialog {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()

                pauseDialogCard
            }
        }
        .focusable(true)
        .digitalCrownRotation(
            $crownValue,
            from: 1,
            through: 60,
            by: 1,
            sensitivity: .low,
            isHapticFeedbackEnabled: true
        )
        .onAppear {
            // 復帰時に現在の残り時間を正しく追いつかせる
            model.refreshFromNow()

            // Crownの初期値をモデルのfocusMinutesに合わせる
            crownValue = Double(model.focusMinutes)
        }
    }

    // MARK: - メインUI
    private var mainContent: some View {
        VStack(spacing: 12) {
            ZStack {
                // 背景リング
                Circle()
                    .stroke(Color.white.opacity(0.08),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round))

                // 残り率リング
                Circle()
                    .trim(from: 0, to: progressRatio)
                    .stroke(ringGradient,
                            style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.2), value: progressRatio)
                    .animation(.easeInOut(duration: 0.2), value: model.phase)

                VStack(spacing: 8) {
                    Text(remainingText)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.white)

                    if model.isActive {
                        Button {
                            model.pause()
                            showPauseDialog = true
                        } label: {
                            Text("PAUSE")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 20)
                                        .fill(Color.white.opacity(0.15))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20)
                                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            model.focusMinutes = Int(crownValue)
                            model.startFocus()
                        } label: {
                            Text("START")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 20)
                                        .fill(Color.white.opacity(0.15))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20)
                                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(24)
            }
            .frame(width: ringSize, height: ringSize)
            .padding(.top, 20)

            if !statusText.isEmpty {
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundColor(statusColor)
                    .padding(.top, 4)
            }

            Spacer(minLength: 0)

            if !model.isActive && model.phase == .idle {
                Text("")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - 一時停止ダイアログ（再開 or リセットのみ / キャンセルなし）:contentReference[oaicite:18]{index=18}
    private var pauseDialogCard: some View {
        VStack(spacing: 12) {
            Text("PAUSE")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            VStack(spacing: 8) {
                Button {
                    model.resume()
                    showPauseDialog = false
                } label: {
                    Text("RESTART")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.white.opacity(0.15))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                        )
                }

                Button {
                    model.stop()
                    showPauseDialog = false
                } label: {
                    Text("RESET")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.red.opacity(0.3))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.red.opacity(0.6), lineWidth: 1)
                        )
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.black.opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .frame(maxWidth: ringSize * 0.9)
    }

    private func timeString(from seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}
