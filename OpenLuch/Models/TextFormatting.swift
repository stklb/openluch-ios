import Foundation

// Как показывать пользователю числа, размеры и даты.
// Всё в одном месте, чтобы во всех экранах было одинаково. Интерфейс только на русском,
// поэтому русский формат задан явно — независимо от языка телефона.
nonisolated enum TextFormatting {

    /// Русские правила для дат и чисел.
    static let russian = Locale(identifier: "ru_RU")

    // MARK: - Размер данных

    /// Размер в байтах для людей: «850 Б», «12 КБ», «2,7 МБ».
    /// Считаем по 1024 байта в килобайте.
    static func bytes(_ count: Int64) -> String {
        let kilobyte: Double = 1024
        let megabyte: Double = 1024 * 1024
        let value = Double(count)

        if value < kilobyte {
            return "\(count) Б"
        }
        if value < megabyte {
            // Килобайты — целым числом: «12 КБ».
            let kilobytes = Int((value / kilobyte).rounded())
            return "\(kilobytes) КБ"
        }
        // Мегабайты — с одним знаком после запятой: «2,7 МБ».
        let megabytes = value / megabyte
        return megabytes.formatted(.number.precision(.fractionLength(1)).locale(russian)) + " МБ"
    }

    /// Ход загрузки: «Получено 120 КБ из 2,7 МБ» или «Получено 120 КБ», если полный размер неизвестен.
    static func downloadProgress(_ progress: DownloadProgress) -> String {
        if let expected = progress.expectedBytes {
            return "Получено \(bytes(progress.receivedBytes)) из \(bytes(expected))"
        }
        return "Получено \(bytes(progress.receivedBytes))"
    }

    // MARK: - Дата обновления

    /// Когда обновлялись данные: «сегодня в 14:05», «вчера в 09:30», «1 окт. в 18:00»,
    /// а для прошлых лет — «12 дек. 2025 г. в 18:00».
    /// `now` можно подменить в тестах.
    static func updatedAt(_ date: Date, now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = russian

        let time = date.formatted(Date.FormatStyle(locale: russian).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))

        if calendar.isDate(date, inSameDayAs: now) {
            return "сегодня в \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "вчера в \(time)"
        }
        var dayStyle = Date.FormatStyle(locale: russian).day().month(.abbreviated)
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            dayStyle = dayStyle.year()
        }
        return "\(date.formatted(dayStyle)) в \(time)"
    }

    // MARK: - Показания приборов

    /// Значение параметра с разделением тысяч (решения владельца 2026-10-07 и 2026-10-11; полная точность — в PDF-отчётах).
    /// По модулю:
    /// - меньше 1 — три знака после запятой: «0,021» (тепло за час), «0,000»;
    /// - от 1 до 10 — два знака: «3,62» (батарея), «5,00»;
    /// - от 10 до 1000 — один знак: «32,5», «-60,0», «999,9»;
    /// - от 1000 — без дробной части: «7 758», «708 430» (месячные объёмы бывают ~120 000).
    /// Число знаков постоянное (и у целых чисел) — так числа в столбце таблицы стоят ровнее.
    static func reading(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(readingFractionDigits(value))).locale(russian))
    }

    /// Сколько знаков после запятой у значения в `reading`.
    static func readingFractionDigits(_ value: Double) -> Int {
        // Границу сравниваем с уже округлённым числом: 0,9996 с тремя знаками стало бы «1,000» — такое
        // показываем как «1,00»; 9,996 — как «10,0»; 999,96 — как «1 000».
        func rounded(_ digits: Int) -> Double {
            let scale = pow(10, Double(digits))
            return abs((value * scale).rounded() / scale)
        }
        if rounded(3) < 1 { return 3 }
        if rounded(2) < 10 { return 2 }
        if rounded(1) < 1000 { return 1 }
        return 0
    }

    /// Время записи прибора. Сервер присылает его БЕЗ часового пояса («2026-10-03T00:31:23» —
    /// это время по часам точки учёта), поэтому показываем те же цифры, ничего не пересчитывая:
    /// «3 окт. в 00:31», для прошлых лет — «12 дек. 2025 г. в 18:00». nil — если строку не разобрать.
    static func deviceDateTime(_ text: String, now: Date = Date()) -> String? {
        // Берём «гггг-мм-ддTчч:мм:сс» (доли секунды, если есть, отбрасываем).
        let mainPart = String(text.prefix(19))
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        // Часовой пояс UTC и при разборе, и при показе — так цифры времени не сдвигаются.
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let date = parser.date(from: mainPart), let utc = TimeZone(identifier: "UTC") else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        var dayStyle = Date.FormatStyle(locale: russian, timeZone: utc).day().month(.abbreviated)
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            dayStyle = dayStyle.year()
        }
        let timeStyle = Date.FormatStyle(locale: russian, timeZone: utc)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        return "\(date.formatted(dayStyle)) в \(date.formatted(timeStyle))"
    }

    /// Число без лишних нулей: 30 → «30», 0,5 → «0,5» (коэффициенты трансформации).
    static func plainNumber(_ value: Double) -> String {
        return value.formatted(.number.locale(russian).grouping(.never))
    }

    // MARK: - Календарная дата

    /// День «2024-07-02» (так хранятся даты поверки, см. Equipment) → «02.07.2024».
    /// Если строка не похожа на дату — возвращаем её как есть.
    static func calendarDay(_ day: String) -> String {
        let parts = day.split(separator: "-")
        if parts.count != 3 {
            return day
        }
        return "\(parts[2]).\(parts[1]).\(parts[0])"
    }

    /// То же с годом из двух цифр: «2027-07-01» → «01.07.27». Для узких мест (дата поверки в списке).
    static func shortCalendarDay(_ day: String) -> String {
        let parts = day.split(separator: "-")
        if parts.count != 3 || parts[0].count != 4 {
            return day
        }
        return "\(parts[2]).\(parts[1]).\(parts[0].suffix(2))"
    }

    // MARK: - Поиск

    /// Подходит ли текст под строку поиска. Каждое слово запроса должно найтись где-то в тексте
    /// (в любом порядке): «котельная тихоокеанская» найдёт «Котельная №1, ул. Тихоокеанская».
    /// Без учёта регистра и разницы «е»/«ё» (поиск «учет» найдёт «учёт»).
    static func matches(_ text: String, query: String) -> Bool {
        let words = query.split(separator: " ")
        for word in words {
            if text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], locale: russian) == nil {
                return false
            }
        }
        return true
    }

    // MARK: - Количество

    /// Слово в нужной форме для числа: 1 объект, 2 объекта, 5 объектов, 21 объект, 11 объектов.
    /// one — для 1, 21, 31…; few — для 2–4, 22–24…; many — для 0, 5–20, 25–30…
    static func plural(_ count: Int, one: String, few: String, many: String) -> String {
        let lastTwoDigits = abs(count) % 100
        let lastDigit = abs(count) % 10

        if lastTwoDigits >= 11 && lastTwoDigits <= 14 {
            return many
        }
        if lastDigit == 1 {
            return one
        }
        if lastDigit >= 2 && lastDigit <= 4 {
            return few
        }
        return many
    }

    /// «128 объектов».
    static func nodesCount(_ count: Int) -> String {
        return "\(count) " + plural(count, one: "объект", few: "объекта", many: "объектов")
    }

    /// «1 точка учёта», «3 точки учёта», «1550 точек учёта».
    static func measurePointsCount(_ count: Int) -> String {
        return "\(count) " + plural(count, one: "точка", few: "точки", many: "точек") + " учёта"
    }

    /// «1 точка», «3 точки», «1550 точек» — без «учёта», где места мало (кэш в «Настройках»).
    static func pointsShortCount(_ count: Int) -> String {
        return "\(count) " + plural(count, one: "точка", few: "точки", many: "точек")
    }

    /// «1 год», «4 года», «16 лет».
    static func years(_ count: Int) -> String {
        return "\(count) " + plural(count, one: "год", few: "года", many: "лет")
    }

    /// «1 отчёт», «3 отчёта», «12 отчётов».
    static func reportsCount(_ count: Int) -> String {
        return "\(count) " + plural(count, one: "отчёт", few: "отчёта", many: "отчётов")
    }

    /// «1 единица оборудования», «3 единицы оборудования», «64 единицы оборудования».
    static func equipmentCount(_ count: Int) -> String {
        return "\(count) " + plural(count, one: "единица", few: "единицы", many: "единиц") + " оборудования"
    }
}
