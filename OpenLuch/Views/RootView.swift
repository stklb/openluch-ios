import SwiftUI

// Корневой экран: показывает вход или основной экран — в зависимости от того,
// выполнен ли вход. Переключение происходит само, когда меняется AppSession.
struct RootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        Group {
            if session.isLoggedIn {
                MainTabView(session: session)
            } else {
                LoginView(session: session)
            }
        }
        // Вход выполнен — короткая вибрация «успех» (решение владельца 2026-10-06).
        // Здесь, а не на экране входа: экран входа в этот момент уже исчезает.
        // При запуске с сохранённым входом вибрации нет — значение не меняется; при выходе — тоже нет.
        .sensoryFeedback(.success, trigger: session.isLoggedIn) { _, isLoggedIn in
            isLoggedIn
        }
    }
}
