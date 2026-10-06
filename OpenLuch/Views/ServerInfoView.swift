import Observation
import SwiftUI

// Экран «Настройки» → «О сервере»: версия сервера, лицензия, часовой пояс, контакты администратора.
// Сначала — сохранённые сведения (без сети), сразу же — обновление в фоне (два маленьких запроса,
// ~3 КБ вместе, при любой сети). Ошибка не стирает показанное.
struct ServerInfoView: View {
    @Environment(AppSession.self) private var session
    @State private var model: ServerInfoModel?

    var body: some View {
        Form {
            if let model {
                content(model)
            }
        }
        .navigationTitle("О сервере")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                model = ServerInfoModel(session: session)
            }
            await model?.start()
        }
    }

    @ViewBuilder
    private func content(_ model: ServerInfoModel) -> some View {
        if let details = model.details {
            serverSection(details, model: model)
            if let license = details.license {
                licenseSection(license)
            }
        } else if model.isLoading {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(model.isWaitingForNetwork ? "Нет сети, ждём подключения…" : "Загрузка…")
                        .foregroundStyle(.secondary)
                }
            }
        } else if model.isCacheLoaded {
            Section {
                if let errorMessage = model.errorMessage {
                    Label("Не удалось загрузить: \(errorMessage)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Button("Повторить") {
                    Task {
                        await model.refresh()
                    }
                }
            }
        }
    }

    // MARK: - Разделы

    private func serverSection(_ details: ServerDetails, model: ServerInfoModel) -> some View {
        Section {
            LabeledContent("Адрес", value: session.serverAddress?.displayText ?? "—")
            if let version = details.version {
                LabeledContent("Версия ЛЭРС УЧЁТ") {
                    Text(version)
                        .textSelection(.enabled)
                }
            }
            if let fullVersion = details.fullVersion, fullVersion != details.version {
                LabeledContent("Полная версия") {
                    Text(fullVersion)
                        .textSelection(.enabled)
                }
            }
            if let timeZone = details.timeZoneTitle {
                LabeledContent("Часовой пояс", value: timeZone)
            }
            if let territory = details.defaultTerritory {
                LabeledContent("Территория по умолчанию", value: territory)
            }
        } header: {
            Text("Сервер")
        } footer: {
            statusFooter(details, model: model)
        }
    }

    private func licenseSection(_ license: ServerLicense) -> some View {
        Section("Лицензия") {
            if let typeTitle = license.typeTitle {
                LabeledContent("Тип", value: typeTitle)
            }
            if let owner = license.owner {
                LabeledContent("Владелец", value: owner)
            }
            if let number = license.number {
                LabeledContent("Номер") {
                    Text(number)
                        .textSelection(.enabled)
                }
            }
            if let usage = license.nodesUsageText {
                LabeledContent("Объектов учёта", value: usage)
            }
            LabeledContent("Действует до", value: license.expireDay.map { TextFormatting.calendarDay($0) } ?? "бессрочно")
            if let subscriptionDay = license.subscriptionExpireDay {
                LabeledContent("Подписка на обновления до", value: TextFormatting.calendarDay(subscriptionDay))
            }
            if let activationDay = license.activationDay {
                LabeledContent("Активирована", value: TextFormatting.calendarDay(activationDay))
            }
        }
    }

    /// «Обновлено сегодня в 14:05», ход обновления или ошибка.
    @ViewBuilder
    private func statusFooter(_ details: ServerDetails, model: ServerInfoModel) -> some View {
        if model.isLoading {
            Text(model.isWaitingForNetwork ? "Нет сети, ждём подключения…" : "Обновление…")
        } else if let errorMessage = model.errorMessage {
            Text("Не удалось обновить: \(errorMessage) Показаны сведения от \(TextFormatting.updatedAt(details.savedAt)).")
        } else {
            Text("Обновлено \(TextFormatting.updatedAt(details.savedAt)).")
        }
    }
}

/// Загрузка сведений о сервере: кэш → сразу; сервер → при каждом открытии экрана (ответ ~3 КБ).
@Observable
final class ServerInfoModel {
    private(set) var details: ServerDetails?
    private(set) var isLoading = false
    private(set) var isWaitingForNetwork = false
    private(set) var errorMessage: String?
    private(set) var isCacheLoaded = false

    private let session: AppSession

    // Без этого на iOS 26 приложение падает при удалении объекта из памяти (см. CLAUDE.md).
    nonisolated deinit {}

    init(session: AppSession) {
        self.session = session
    }

    func start() async {
        if !isCacheLoaded {
            details = await session.cacheStore.loadServerDetails()
            isCacheLoaded = true
        }
        await refresh()
    }

    func refresh() async {
        if isLoading {
            return
        }
        guard let client = session.makeAPIClient(), let token = session.token else {
            return
        }
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            isWaitingForNetwork = false
        }
        // Сколько ждать, если сети нет, — показываем по NetworkMonitor (сам ответ крошечный).
        isWaitingForNetwork = !NetworkMonitor.shared.isNetworkAvailable

        do {
            let fresh = try await client.fetchServerDetails(token: token)
            details = fresh
            try? await session.cacheStore.saveServerDetails(fresh)
        } catch {
            let apiError = APIError.from(error)
            if apiError == .cancelled {
                return
            }
            if case .unauthorized = apiError {
                session.sessionExpired()
                return
            }
            errorMessage = apiError.errorDescription
        }
    }
}
