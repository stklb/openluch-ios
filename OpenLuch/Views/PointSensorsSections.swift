import SwiftUI

// Раздел «Датчики» в карточке точки учёта. Внутри — подзаголовки магистралей (подающая,
// обратная, прочие), под ними строки: что измеряет датчик и какой прибор («Температура — КТСП-Р № 2198»).
// По нажатию на строку — карточка прибора. Данные и правила загрузки — PointSensorsModel.
struct PointSensorsSections: View {
    @Environment(DataStore.self) private var dataStore

    let model: PointSensorsModel

    var body: some View {
        if !model.isCacheLoaded {
            // Кэш читается — доли секунды, ничего не показываем.
            EmptyView()
        } else if let cached = model.cached {
            savedSensorsSections(cached)
        } else if let progress = model.progress {
            // Первая загрузка: сохранённых датчиков нет.
            Section {
                DownloadProgressView(progress: progress)
            } header: {
                Text("Датчики")
            } footer: {
                Text("Датчики загружаются один раз и сохраняются на устройстве. Ответ сервера большой — на медленной связи это может занять пару минут.")
            }
        } else if let errorMessage = model.errorMessage {
            Section("Датчики") {
                Label("Не удалось загрузить: \(errorMessage)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Повторить") {
                    Task {
                        await model.refresh()
                    }
                }
            }
        }
    }

    // MARK: - Сохранённые датчики

    @ViewBuilder
    private func savedSensorsSections(_ cached: CachedPointSensors) -> some View {
        // Магистрали, на которых есть датчики, — в порядке: подающая, обратная, прочие.
        let pipes = SensorPipe.allCases.filter { pipe in
            cached.sensors.contains { $0.pipe == pipe }
        }

        // Один раздел «Датчики»; магистрали — подзаголовками внутри него (как в программе ЛЭРС).
        Section {
            if pipes.isEmpty {
                Text("Датчики не указаны")
                    .foregroundStyle(.secondary)
            }
            ForEach(pipes, id: \.self) { pipe in
                Text(pipe.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(cached.sensors.filter { $0.pipe == pipe }, id: \.self) { sensor in
                    sensorRow(sensor)
                }
            }
        } header: {
            Text("Датчики")
        } footer: {
            statusFooter(cached)
        }
    }

    /// «Температура — КТСП-Р № 2198». Если прибор есть в справочнике — со ссылкой на его карточку.
    @ViewBuilder
    private func sensorRow(_ sensor: PointSensor) -> some View {
        // Сначала — из справочника оборудования (он обновляется чаще), иначе — из ответа с датчиками.
        let equipment = dataStore.equipment(withId: sensor.equipmentId) ?? sensor.equipment

        if let equipment {
            NavigationLink(value: equipment) {
                LabeledContent(sensor.measuredTitle, value: equipment.shortTitle)
            }
        } else {
            LabeledContent(sensor.measuredTitle, value: sensor.equipmentTitle)
        }
    }

    /// Под датчиками: «Обновлено 3 окт. в 14:05», ход обновления или ошибка.
    @ViewBuilder
    private func statusFooter(_ cached: CachedPointSensors) -> some View {
        if let progress = model.progress {
            VStack(alignment: .leading, spacing: 4) {
                Text("Обновление датчиков…")
                DownloadProgressView(progress: progress)
            }
        } else if let errorMessage = model.errorMessage {
            Label("Не удалось обновить датчики: \(errorMessage)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Text("Датчики обновлены \(TextFormatting.updatedAt(cached.savedAt)). Автоматически обновляются раз в сутки по Wi-Fi.")
        }
    }
}
