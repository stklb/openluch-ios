import SwiftUI

// Разделы карточки точки учёта с последними данными: «Текущие данные» (или часовые, суточные…) и «Интеграторы»
// (накопленные значения счётчиков: M1, V1, Q, ВНР…; так они называются в ЛЭРС).
// Данные и их загрузка — в PointReadingsModel.
//
// Пока идёт обновление (или если оно не удалось), на экране остаются сохранённые ранее значения:
// они серые, а над ними строка состояния — «Обновление…» со стандартным индикатором и датой,
// от которой эти данные. Так делают приложения Apple (например, «Почта» и «Акции»): старые данные
// не прячут, но честно показывают, что они не свежие.
//
// Показываются только параметры, выбранные в ЛЭРС для этой точки (MeasurePoint.selectedParamsList):
// прибор присылает много лишнего (углы фаз, коэффициенты мощности…). Остальные — по ссылке в подписи
// под последним разделом: «Отображаются только выбранные в точке учёта параметры. Показать все»
// (выбор не запоминается: при новом открытии карточки снова только выбранные).
struct PointReadingsSections: View {
    let model: PointReadingsModel
    /// Номера параметров, выбранных для показа у точки; nil — показываем все.
    let selectedParameterIds: [Int]?

    /// true — пользователь нажал «Показать все параметры».
    @State private var isShowingAllParameters = false

    var body: some View {
        if let readings = model.readings {
            if model.isShowingStaleData {
                staleStatusSection(savedAt: readings.savedAt)
            }
            let consumption = ParameterSelection.split(readings.consumption?.values ?? [],
                                                       selectedIds: selectedParameterIds)
            let totals = ParameterSelection.split(readings.totals?.values ?? [],
                                                  selectedIds: selectedParameterIds)
            // Подпись «только выбранные / все» нужна, если скрытые параметры вообще есть
            // (у точки ничего не выбрано или выбраны все — переключать нечего).
            let hasHiddenParameters = !consumption.hidden.isEmpty || !totals.hidden.isEmpty
            recordSection(title: consumptionTitle(readings.consumption),
                          record: readings.consumption,
                          selection: consumption,
                          emptyText: "Прибор ещё не передавал данные.",
                          groupsIntoTables: true,
                          showsSelectionNote: false)
            // Подпись — под последним разделом: она относится к обоим.
            // Интеграторы — без таблицы «подача/обратка»: M1, M2, V1, V2… просто идут в два столбца
            // (решение владельца 2026-10-07).
            recordSection(title: "Интеграторы",
                          record: readings.totals,
                          selection: totals,
                          emptyText: "Интеграторов нет.",
                          groupsIntoTables: false,
                          showsSelectionNote: hasHiddenParameters)
        } else if model.isCacheLoaded {
            // Данных на телефоне нет: идёт первая загрузка или она не удалась.
            Section("Последние данные") {
                if model.isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(model.isWaitingForNetwork ? "Нет сети, ждём подключения…" : "Загрузка данных…")
                            .foregroundStyle(.secondary)
                    }
                } else if let errorMessage = model.errorMessage {
                    Label("Не удалось загрузить: \(errorMessage)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    retryButton
                }
            }
        }
    }

    // MARK: - Разделы

    /// Строка над старыми данными: идёт обновление или оно не удалось, и от какого времени данные.
    @ViewBuilder
    private func staleStatusSection(savedAt: Date) -> some View {
        Section {
            if model.isLoading {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.isWaitingForNetwork ? "Нет сети, ждём подключения…" : "Обновление…")
                        Text("Показаны данные от \(TextFormatting.updatedAt(savedAt))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                // Обновление не удалось (или его отменили) — данные так и остались старыми.
                VStack(alignment: .leading, spacing: 2) {
                    Label(model.errorMessage.map { "Не удалось обновить: \($0)" } ?? "Данные не обновлены",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Показаны данные от \(TextFormatting.updatedAt(savedAt))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                retryButton
            }
        }
    }

    @ViewBuilder
    private func recordSection(title: String, record: LastDataRecord?,
                               selection: (shown: [DataValue], hidden: [DataValue]),
                               emptyText: String, groupsIntoTables: Bool, showsSelectionNote: Bool) -> some View {
        let values = isShowingAllParameters ? selection.shown + selection.hidden : selection.shown
        // groupsIntoTables = false — без таблиц, все значения в два столбца.
        let layout = ReadingsLayout(values: values)
        let tables = groupsIntoTables ? layout.tables : []
        let singles = groupsIntoTables ? layout.singles : values
        Section {
            if values.isEmpty {
                // Значения есть, но ни одно не выбрано для показа — честно говорим об этом,
                // а не «данных нет».
                Text(selection.hidden.isEmpty ? emptyText : "Выбранных для показа параметров нет.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tables, id: \.self) { table in
                    ReadingsTableView(table: table, units: model.units, isStale: model.isShowingStaleData)
                }
                if !singles.isEmpty {
                    ReadingsPairsView(values: singles, units: model.units, isStale: model.isShowingStaleData)
                }
            }
        } header: {
            // Время записи — справа в заголовке: так на экране на строку меньше.
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                if let dateTime = record?.dateTime, let shown = TextFormatting.deviceDateTime(dateTime) {
                    Text(shown)
                        .textCase(nil)
                        .accessibilityLabel("Запись прибора: \(shown) по времени точки учёта")
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                ReadingsLegend(values: values)
                if showsSelectionNote {
                    selectionNote
                }
            }
        }
    }

    /// Подпись со ссылкой: «Отображаются только выбранные в точке учёта параметры. Показать все»
    /// и обратно. Ссылка в тексте — стандартный Text с Markdown; нажатие перехватываем
    /// (OpenURLAction) и переключаем показ, никуда не переходя.
    private var selectionNote: some View {
        let text: LocalizedStringKey = isShowingAllParameters
            ? "Отображаются все параметры. [Показать только выбранные](openluch:selection)"
            : "Отображаются только выбранные в точке учёта параметры. [Показать все](openluch:selection)"
        return Text(text)
            .environment(\.openURL, OpenURLAction { _ in
                withAnimation {
                    isShowingAllParameters.toggle()
                }
                return .handled
            })
    }

    private var retryButton: some View {
        Button("Повторить") {
            Task {
                await model.refresh()
            }
        }
    }

    private func consumptionTitle(_ record: LastDataRecord?) -> String {
        // «Текущие данные», «Суточные данные»… — коротко, чтобы справа поместилось время записи.
        if let typeTitle = record?.dataTypeTitle {
            return "\(typeTitle.prefix(1).uppercased())\(typeTitle.dropFirst()) данные"
        }
        return "Последние данные"
    }
}
