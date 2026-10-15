import Foundation

// Вошедший пользователь: отображаемое имя и права учётной записи на сервере ЛЭРС.
// Откуда: GET /api/v1/Login/Current (~1,8 КБ) — вместе со списком объектов (ListRefresher).
// Хранится в UserDefaults (SettingsStore) до следующего входа.
//
// Зачем права: не показывать кнопки, которыми пользователь всё равно не сможет воспользоваться
// (сервер ответил бы ошибкой уже после нажатия). Полного перечня прав в swagger нет — права
// приходят строками; сохраняем весь список, а проверяем только нужные приложению (UserPermission).

/// Права, от которых зависит, что показывает приложение. Значения — как их присылает сервер.
nonisolated enum UserPermission: String, Sendable {
    /// Ручной опрос прибора (раздел «Опрос прибора» в карточке точки).
    case manualPoll = "ManualPoll"
    /// Формирование отчётов (кнопка «Сформировать отчёт»).
    case printReport = "PrintReport"
    /// Просмотр нештатных ситуаций (ссылка в строке «Состояние» карточки точки).
    case viewIncident = "ViewIncident"
}

nonisolated struct CurrentUser: Codable, Equatable, Sendable {
    /// «Иванов И. И.». nil — сервер имени не прислал.
    let displayName: String?
    /// Администратор сервера — ему разрешено всё, какие бы права ни пришли списком.
    let isAdmin: Bool
    /// Все права учётной записи, как их прислал сервер («ViewData», «ManualPoll», …).
    let permissions: [String]

    /// Разрешено ли действие.
    func isAllowed(_ permission: UserPermission) -> Bool {
        return isAdmin || permissions.contains(permission.rawValue)
    }
}
