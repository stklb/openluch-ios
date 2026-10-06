import SwiftUI

// Раздел «Опрос прибора» во вкладке «Данные» карточки точки: кнопка «Опросить текущие»
// и ход опроса. Логика — PointPollModel. Опрос запускается сразу, без подтверждения
// (решение владельца 2026-10-07).
struct PointPollSection: View {
    let model: PointPollModel
    /// Запустить опрос (задачу создаёт карточка — она же отменяет её, когда пользователь уходит).
    let onStart: () -> Void
    /// Перестать ждать результат.
    let onStop: () -> Void

    var body: some View {
        Section {
            switch model.status {
            case .idle:
                startButton(title: "Опросить текущие")

            case .starting:
                progressRow(title: "Запуск опроса…", subtitle: nil)

            case .waiting(let sessionId, let startedAt):
                progressRow(title: "Прибор опрашивается…",
                            subtitle: waitingSubtitle(sessionId: sessionId, startedAt: startedAt))
                Button("Перестать ждать", role: .cancel) {
                    onStop()
                }

            case .succeeded(let recordTime):
                VStack(alignment: .leading, spacing: 2) {
                    Label("Получены новые данные", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let recordTime, let shown = TextFormatting.deviceDateTime(recordTime) {
                        Text("Запись прибора: \(shown)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                startButton(title: "Опросить ещё раз")

            case .noNewData:
                VStack(alignment: .leading, spacing: 2) {
                    Label("Новых данных пока нет", systemImage: "clock")
                    Text("Опрос может идти дольше. Обновите данные позже кнопкой ↻ вверху.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                startButton(title: "Опросить ещё раз")

            case .failed(let message):
                Label("Опрос не запущен: \(message)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                startButton(title: "Повторить")
            }
        }
        // Подписи под кнопкой нет — название «Опросить текущие» говорит само за себя (решение владельца 2026-10-07).
        // Итог опроса — вибрацией (ждать его до 3 минут, человек мог отвлечься):
        // новые данные — «успех», опрос не запустился — «предупреждение». «Новых данных пока нет» — без вибрации.
        .sensoryFeedback(trigger: model.status) { _, newStatus in
            switch newStatus {
            case .succeeded:
                return .success
            case .failed:
                return .warning
            default:
                return nil
            }
        }
    }

    private func startButton(title: String) -> some View {
        Button {
            onStart()
        } label: {
            Label(title, systemImage: "antenna.radiowaves.left.and.right")
        }
    }

    private func progressRow(title: String, subtitle: String?) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// «Сеанс № 1234 · запущен в 14:05. Проверяем каждые 20 с».
    private func waitingSubtitle(sessionId: Int?, startedAt: Date) -> String {
        let time = startedAt.formatted(Date.FormatStyle(locale: TextFormatting.russian)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        var text = "Запущен в \(time), ждём новую запись (до 3 минут)"
        if let sessionId {
            text = "Сеанс № \(sessionId). " + text
        }
        return text
    }
}
