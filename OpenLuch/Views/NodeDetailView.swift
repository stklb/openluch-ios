import SwiftUI

// Карточка объекта учёта: в заголовке — кружок состояния и название; ниже одним блоком адрес,
// сезон, ответственный (только имя), комментарий; затем незавершённые работы (если есть) и точки учёта.
// Всё берётся из кэша на телефоне — открывается мгновенно и без интернета, трафика не тратит.
// Сеть нужна, только если пользователь сам нажмёт «Открыть в Картах» (откроется приложение «Карты»).
struct NodeDetailView: View {
    @Environment(DataStore.self) private var dataStore

    let node: Node

    var body: some View {
        // Если список обновился, пока карточка открыта, — показываем свежие сведения.
        let current = dataStore.node(withId: node.id) ?? node
        let points = dataStore.measurePoints(ofNode: node.id)
        let jobs = dataStore.jobs(ofNode: node.id)

        List {
            mainSection(current)
            if !jobs.isEmpty {
                jobsSection(jobs, points: points)
            }
            pointsSection(points)
        }
        // Небольшие отступы между разделами — как в карточке точки.
        .listSectionSpacing(.compact)
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Заголовок экрана: цветной кружок состояния + название (до двух строк),
            // как значок системы у карточки точки.
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    StateDot(state: current.itemState)
                    Text(current.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Разделы

    /// Сведения об объекте одним блоком (решение владельца 2026-10-06: карточка как можно короче).
    /// Название с цветным кружком состояния — в заголовке экрана; тип, номер и подробное
    /// состояние не показываем.
    @ViewBuilder
    private func mainSection(_ current: Node) -> some View {
        let responsibleName = current.responsibleName ?? ""
        let comment = current.comment ?? ""
        let hasRows = current.seasonTitle != nil || !current.address.isEmpty
            || current.mapLocation != nil || !responsibleName.isEmpty || !comment.isEmpty

        if hasRows {
            Section {
                if !current.address.isEmpty || current.mapLocation != nil {
                    addressRow(current)
                }
                if let seasonTitle = current.seasonTitle {
                    LabeledContent("Сезон", value: seasonTitle)
                }
                if !responsibleName.isEmpty {
                    captionedText("Ответственный", responsibleName)
                }
                if !comment.isEmpty {
                    captionedText("Комментарий", comment)
                }
            }
        }
    }

    /// Адрес и справа — значок «Открыть в Картах» (одна строка вместо отдельного раздела).
    /// Значок — по центру строки по вертикали, как всё, что стоит справа в строках списков iOS
    /// (шеврон ›, кнопка ⓘ). Разделитель не нужен: кнопку выдаёт цвет (синий акцент).
    private func addressRow(_ current: Node) -> some View {
        HStack(spacing: 8) {
            captionedText("Адрес", current.address.isEmpty ? "Не указан" : current.address)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let mapURL = mapURL(for: current) {
                Link(destination: mapURL) {
                    Image(systemName: "map")
                        .imageScale(.large)
                        // Зона нажатия 44×44 точки — минимум по правилам Apple; сам значок не крупнее.
                        // Значок прижат вправо — на одной линии с другими значениями справа и шевронами ›.
                        .frame(width: 44, height: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                // Без этого нажатие по строке списка срабатывало бы на всю строку.
                .buttonStyle(.borderless)
                .accessibilityLabel("Открыть в Картах")
            }
        }
    }

    /// Мелкая серая подпись сверху и текст под ней — длинный текст (ФИО, адрес) не жмётся вправо.
    private func captionedText(_ caption: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(text)
                .textSelection(.enabled)
        }
    }

    /// Незавершённые работы (назначенные и просроченные). Приходят вместе со списком объектов,
    /// поэтому отдельной даты «Обновлено» нет. Только просмотр — работами управляют в ЛЭРС.
    private func jobsSection(_ jobs: [NodeJob], points: [MeasurePoint]) -> some View {
        Section {
            ForEach(jobs) { job in
                jobRow(job, pointTitle: points.first { $0.id == job.measurePointId }?.title)
            }
        } header: {
            Text("Работы: \(jobs.count)")
        }
    }

    /// Одна работа: название; тип и номер наряда; сроки (просроченная — оранжевым ⚠︎, как поверка
    /// в оборудовании); точка, исполнитель, описание — серым, если указаны.
    private func jobRow(_ job: NodeJob, pointTitle: String?) -> some View {
        let typeTitle = job.typeTitle ?? ""
        let showsType = !typeTitle.isEmpty && typeTitle != job.displayTitle
        let orderNumber = job.workOrderNumber ?? ""
        let subtitle = [showsType ? typeTitle : "", orderNumber.isEmpty ? "" : "наряд № \(orderNumber)"]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let performer = job.performerName ?? ""

        return VStack(alignment: .leading, spacing: 4) {
            Text(job.displayTitle)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let period = job.periodText {
                if job.isOverdue {
                    Label("\(period), просрочена", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else {
                    Text(period)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let pointTitle {
                Text("Точка: \(pointTitle)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !performer.isEmpty {
                Text("Исполнитель: \(performer)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let description = job.description {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }

    private func pointsSection(_ points: [MeasurePoint]) -> some View {
        Section {
            if dataStore.measurePointsUpdatedAt == nil {
                Text("Список точек учёта ещё не загружен. Он загрузится автоматически по Wi-Fi или при открытии вкладки «Точки».")
                    .foregroundStyle(.secondary)
            } else if points.isEmpty {
                Text("У объекта нет обычных точек учёта.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(points) { point in
                    NavigationLink(value: point) {
                        MeasurePointRow(point: point, showsNode: false)
                    }
                }
            }
        } header: {
            Text(points.isEmpty ? "Точки учёта" : "Точки учёта: \(points.count)")
        }
    }

    // MARK: - Вспомогательное

    /// Ссылка на точку в приложении «Карты» (откроется только по нажатию).
    private func mapURL(for node: Node) -> URL? {
        guard let location = node.mapLocation else {
            return nil
        }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "ll", value: "\(location.latitude),\(location.longitude)"),
            URLQueryItem(name: "q", value: node.title)
        ]
        return components?.url
    }
}
