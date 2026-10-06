import SwiftUI

// Точка входа в приложение.
// Атрибут @main говорит системе: «запуск начинается здесь».
// WindowGroup — главное окно приложения; внутри него показываем первый экран.
@main
struct OpenLuchApp: App {
    // Одна «сессия» на всё приложение: знает, выполнен ли вход.
    // @State — SwiftUI хранит этот объект всё время, пока работает приложение.
    @State private var session = AppSession()
    /// Активно ли приложение, свёрнуто или в фоне.
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Сразу запускаем наблюдение за сетью, чтобы к первому запросу было известно,
        // есть ли у телефона сеть (см. NetworkMonitor).
        _ = NetworkMonitor.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Передаём сессию всем экранам внутри (они получают её через @Environment).
                .environment(session)
        }
        // Ушли из приложения — просим iOS разбудить его для обновления кэша (см. BackgroundRefresh).
        .onChange(of: scenePhase) {
            if scenePhase == .background {
                BackgroundRefresh.schedule(cacheStore: session.cacheStore)
            }
        }
        // Фоновое обновление кэша: iOS запускает его сама, когда сочтёт удобным.
        .backgroundTask(.appRefresh(BackgroundRefresh.taskIdentifier)) {
            await BackgroundRefresh.run(session: session)
        }
    }
}
