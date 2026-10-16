import SwiftUI

// Основной экран после входа: три вкладки внизу — «Объекты», «Точки», «Оборудование»
// (порядок как в данных: в объекте точки, у точки прибор; решение владельца 2026-10-06).
// По умолчанию открыта «Объекты» (этот список легче по трафику, решение владельца) — она же первая.
// «Настройки» — не вкладка, а кнопка ⚙︎ слева вверху каждого списка (см. settingsButton()):
// так Apple делает с редко нужными разделами (App Store, «Музыка», «Подкасты»).
struct MainTabView: View {
    @State private var dataStore: DataStore
    @State private var selectedTab: AppTab = .nodes
    private let session: AppSession

    /// Активно ли приложение (на экране) или свёрнуто.
    @Environment(\.scenePhase) private var scenePhase

    enum AppTab: Hashable {
        case nodes
        case measurePoints
        case equipment
    }

    init(session: AppSession) {
        // @State запоминает хранилище при первом показе и дальше не пересоздаёт его.
        _dataStore = State(initialValue: DataStore(session: session))
        self.session = session
    }

    var body: some View {
        // Сессию и хранилище передаём в КАЖДУЮ вкладку явно, а не только один раз на TabView.
        // Зачем: на iPad (TestFlight, сборка 23, iPadOS 26.6) приложение падало при сворачивании —
        // iOS делает снимок экрана в другой ориентации, SwiftUI перерисовывает экран, и какой-то экран
        // не находил объект в окружении («No Observable object…» → вылет). Вкладки и окна поверх (sheet)
        // SwiftUI размещает в отдельных «контейнерах» UIKit — передаём объекты прямо в них.
        TabView(selection: $selectedTab) {
            Tab("Объекты", systemImage: ListKind.nodes.symbolName, value: AppTab.nodes) {
                NodesListView()
                    .environment(session)
                    .environment(dataStore)
            }
            Tab("Точки", systemImage: ListKind.measurePoints.symbolName, value: AppTab.measurePoints) {
                MeasurePointsListView()
                    .environment(session)
                    .environment(dataStore)
            }
            Tab("Оборудование", systemImage: ListKind.equipment.symbolName, value: AppTab.equipment) {
                EquipmentListView()
                    .environment(session)
                    .environment(dataStore)
            }
        }
        // Хранилище списков доступно всем экранам внутри (через @Environment(DataStore.self)).
        .environment(dataStore)
        // При появлении экрана: показать кэш и запустить автообновление.
        .task {
            await dataStore.start()
        }
        // Вернулись в приложение — проверяем, не пора ли обновить списки (раз в час по Wi-Fi).
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                // Если iOS прервала загрузку, пока приложение было свёрнуто, — продолжаем её.
                dataStore.resumeAfterBackground()
                Task {
                    // Сначала — то, что iOS успела обновить в фоне, потом — обычное автообновление.
                    await dataStore.reloadCacheIfUpdatedInBackground()
                    dataStore.autoRefreshIfNeeded()
                }
            }
        }
    }
}
