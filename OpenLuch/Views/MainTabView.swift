import SwiftUI

// Основной экран после входа: три вкладки внизу — «Объекты», «Точки», «Оборудование»
// (порядок как в данных: в объекте точки, у точки прибор; решение владельца 2026-10-06).
// По умолчанию открыта «Объекты» (этот список легче по трафику, решение владельца) — она же первая.
// «Настройки» — не вкладка, а кнопка ⚙︎ слева вверху каждого списка (см. settingsButton()):
// так Apple делает с редко нужными разделами (App Store, «Музыка», «Подкасты»).
struct MainTabView: View {
    @State private var dataStore: DataStore
    @State private var selectedTab: AppTab = .nodes

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
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Объекты", systemImage: "building.2", value: AppTab.nodes) {
                NodesListView()
            }
            Tab("Точки", systemImage: "gauge.with.dots.needle.33percent", value: AppTab.measurePoints) {
                MeasurePointsListView()
            }
            Tab("Оборудование", systemImage: "wrench.and.screwdriver", value: AppTab.equipment) {
                EquipmentListView()
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
