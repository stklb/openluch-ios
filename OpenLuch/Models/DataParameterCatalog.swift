import Foundation

// Справочник параметров данных: код сервера («T_in») → обозначение («T1»), название по-русски и категория
// (по категории находим единицу измерения: °C, т, м³, Гкал…).
//
// Коды — из swagger (DataParameter). Здесь описаны самые частые; для незнакомого кода
// показываем сам код, а значение — без единицы (разбор от этого не ломается).
nonisolated enum DataParameterCatalog {

    struct Info {
        /// Общепринятое короткое обозначение: «T1», «M2», «A+»… Показывается в последних данных
        /// (решение владельца 2026-10-06: короче, чем «Температура в подаче»).
        let symbol: String
        /// Полное название по-русски: для VoiceOver и там, где места хватает.
        let title: String
        /// Категория как в API (DataParameterCategory): "Temperature", "Mass", "Heat"…
        let category: String
    }

    /// Название и категория параметра — или nil, если код незнакомый.
    static func info(for code: String) -> Info? {
        if let info = fixed[code] {
            return info
        }
        // Энергия по тарифам: Ap1…Ap4, An1…An4, Rp1…Rp4, Rn1…Rn4.
        if code.count == 3, let tariff = Int(String(code.last!)), let base = fixed[String(code.prefix(2))] {
            return Info(symbol: "\(base.symbol) Т\(tariff)",
                        title: "\(base.title), тариф \(tariff)",
                        category: base.category)
        }
        return nil
    }

    /// Название параметра для пользователя (незнакомый код — как есть).
    static func title(for code: String) -> String {
        return info(for: code)?.title ?? code
    }

    /// Короткое обозначение параметра (незнакомый код — как есть).
    static func symbol(for code: String) -> String {
        return info(for: code)?.symbol ?? code
    }

    /// Единица измерения параметра: из единиц сервера, а для электрических
    /// величин (их в списке сервера нет) — стандартная. Пустая строка — без единицы.
    static func unit(for code: String, serverUnits: ServerUnits?) -> String {
        guard let category = info(for: code)?.category else {
            return ""
        }
        if let unitCode = serverUnits?.unitsByCategory[category] {
            return unitTitle(unitCode)
        }
        return defaultUnits[category] ?? ""
    }

    /// Единица измерения из кода сервера (Unit): "CelsiusDegree" → «°C».
    static func unitTitle(_ unitCode: String) -> String {
        return unitTitles[unitCode] ?? ""
    }

    // MARK: - Таблицы

    private static let fixed: [String: Info] = [
        // Температура
        "T_in": Info(symbol: "T1", title: "Температура в подаче", category: "Temperature"),
        "T_out": Info(symbol: "T2", title: "Температура в обратке", category: "Temperature"),
        "T_cw": Info(symbol: "Tхв", title: "Температура холодной воды", category: "Temperature"),
        "T_outdoor": Info(symbol: "Tнв", title: "Температура наружного воздуха", category: "Temperature"),
        "T_indoor": Info(symbol: "Tвн", title: "Температура в помещении", category: "Temperature"),
        "T_delta": Info(symbol: "ΔT", title: "Разность температур", category: "Temperature"),
        "T": Info(symbol: "T", title: "Температура", category: "Temperature"),
        // Давление
        "P_in": Info(symbol: "P1", title: "Давление в подаче", category: "Pressure"),
        "P_out": Info(symbol: "P2", title: "Давление в обратке", category: "Pressure"),
        "P_cw": Info(symbol: "Pхв", title: "Давление холодной воды", category: "Pressure"),
        "P": Info(symbol: "P", title: "Давление", category: "Pressure"),
        "P_delta": Info(symbol: "ΔP", title: "Перепад давления", category: "PressureDrop"),
        // Масса
        "M_in": Info(symbol: "M1", title: "Масса в подаче", category: "Mass"),
        "M_out": Info(symbol: "M2", title: "Масса в обратке", category: "Mass"),
        "M_delta": Info(symbol: "ΔM", title: "Разность масс", category: "Mass"),
        "M": Info(symbol: "M", title: "Масса", category: "Mass"),
        // Объём
        "V_in": Info(symbol: "V1", title: "Объём в подаче", category: "Volume"),
        "V_out": Info(symbol: "V2", title: "Объём в обратке", category: "Volume"),
        "V_delta": Info(symbol: "ΔV", title: "Разность объёмов", category: "Volume"),
        "V": Info(symbol: "V", title: "Объём", category: "Volume"),
        "V_std": Info(symbol: "Vст", title: "Объём при стандартных условиях", category: "Volume"),
        // Тепло
        "Q_in": Info(symbol: "Q1", title: "Тепло в подаче", category: "Heat"),
        "Q_out": Info(symbol: "Q2", title: "Тепло в обратке", category: "Heat"),
        "Q_delta": Info(symbol: "Q", title: "Потреблённое тепло", category: "Heat"),
        // Прочее
        "T_internal": Info(symbol: "Tприб", title: "Температура внутри прибора", category: "Temperature"),
        "T_control": Info(symbol: "Tконтр", title: "Контрольная температура", category: "Temperature"),
        "T_base": Info(symbol: "Tбаз", title: "Базовая температура", category: "Temperature"),
        "H": Info(symbol: "H", title: "Уровень", category: "WaterLevel"),
        "ValvePercent": Info(symbol: "Клапан", title: "Открытие клапана", category: "ValvePercent"),
        "Humidity": Info(symbol: "Влажн.", title: "Влажность", category: "Humidity"),
        "CarbonDioxideContent": Info(symbol: "CO₂", title: "Содержание CO₂", category: "CarbonDioxideContent"),
        "M_balance": Info(symbol: "Небаланс M", title: "Небаланс масс", category: "Mass"),
        // Время
        "NormalOperationDuration": Info(symbol: "ВНР", title: "Время нормальной работы", category: "Time"),
        "StopDuration": Info(symbol: "ВОС", title: "Время останова", category: "Time"),
        "NoPowerDuration": Info(symbol: "Без питания", title: "Время без питания", category: "Time"),
        "IncidentDuration": Info(symbol: "Время НС", title: "Время нештатных ситуаций", category: "Time"),
        "FlowUnderrunDuration": Info(symbol: "G < min", title: "Время расхода ниже минимума", category: "Time"),
        "FlowOverrunDuration": Info(symbol: "G > max", title: "Время расхода выше максимума", category: "Time"),
        "TempDiffLowDuration": Info(symbol: "ΔT < min", title: "Время малой разности температур", category: "Time"),
        // Электроэнергия (накопленная)
        "Ap": Info(symbol: "A+", title: "Активная энергия, приём", category: "ActiveElectricalEnergy"),
        "An": Info(symbol: "A−", title: "Активная энергия, отдача", category: "ActiveElectricalEnergy"),
        "Rp": Info(symbol: "R+", title: "Реактивная энергия, приём", category: "ReactiveElectricalEnergy"),
        "Rn": Info(symbol: "R−", title: "Реактивная энергия, отдача", category: "ReactiveElectricalEnergy"),
        // Электрическая мощность
        "Pp": Info(symbol: "P+", title: "Активная мощность", category: "ActiveElectricPower"),
        "Pn": Info(symbol: "P−", title: "Активная мощность, отдача", category: "ActiveElectricPower"),
        "PA": Info(symbol: "PA", title: "Активная мощность, фаза A", category: "ActiveElectricPower"),
        "PB": Info(symbol: "PB", title: "Активная мощность, фаза B", category: "ActiveElectricPower"),
        "PC": Info(symbol: "PC", title: "Активная мощность, фаза C", category: "ActiveElectricPower"),
        "Q": Info(symbol: "Q", title: "Реактивная мощность", category: "ReactiveElectricPower"),
        "Qp": Info(symbol: "Q+", title: "Реактивная мощность, приём", category: "ReactiveElectricPower"),
        "Qn": Info(symbol: "Q−", title: "Реактивная мощность, отдача", category: "ReactiveElectricPower"),
        "QA": Info(symbol: "QA", title: "Реактивная мощность, фаза A", category: "ReactiveElectricPower"),
        "QB": Info(symbol: "QB", title: "Реактивная мощность, фаза B", category: "ReactiveElectricPower"),
        "QC": Info(symbol: "QC", title: "Реактивная мощность, фаза C", category: "ReactiveElectricPower"),
        "S": Info(symbol: "S", title: "Полная мощность", category: "ApparentElectricPower"),
        "SA": Info(symbol: "SA", title: "Полная мощность, фаза A", category: "ApparentElectricPower"),
        "SB": Info(symbol: "SB", title: "Полная мощность, фаза B", category: "ApparentElectricPower"),
        "SC": Info(symbol: "SC", title: "Полная мощность, фаза C", category: "ApparentElectricPower"),
        // Активная мощность, рассчитанная по току (на my.lers.ru почти совпадает с Pp)
        "ElectricCurrent_P": Info(symbol: "P (по I)", title: "Активная мощность (по току)", category: "ActiveElectricPower"),
        "PowerProfile_Pp": Info(symbol: "P+ профиль", title: "Профиль мощности: активная, приём", category: "ActiveElectricPower"),
        "PowerProfile_Pn": Info(symbol: "P− профиль", title: "Профиль мощности: активная, отдача", category: "ActiveElectricPower"),
        "PowerProfile_Qp": Info(symbol: "Q+ профиль", title: "Профиль мощности: реактивная, приём", category: "ReactiveElectricPower"),
        "PowerProfile_Qn": Info(symbol: "Q− профиль", title: "Профиль мощности: реактивная, отдача", category: "ReactiveElectricPower"),
        // Напряжение, ток, частота
        "U": Info(symbol: "U", title: "Напряжение", category: "Voltage"),
        "UA": Info(symbol: "UA", title: "Напряжение, фаза A", category: "Voltage"),
        "UB": Info(symbol: "UB", title: "Напряжение, фаза B", category: "Voltage"),
        "UC": Info(symbol: "UC", title: "Напряжение, фаза C", category: "Voltage"),
        "I": Info(symbol: "I", title: "Ток", category: "ElectricCurrent"),
        "IA": Info(symbol: "IA", title: "Ток, фаза A", category: "ElectricCurrent"),
        "IB": Info(symbol: "IB", title: "Ток, фаза B", category: "ElectricCurrent"),
        "IC": Info(symbol: "IC", title: "Ток, фаза C", category: "ElectricCurrent"),
        "Frequency": Info(symbol: "f", title: "Частота", category: "Frequency"),
        "CosPhi": Info(symbol: "cos φ", title: "Коэффициент мощности", category: "PowerFactor"),
        "CosPhiA": Info(symbol: "cos φA", title: "Коэффициент мощности, фаза A", category: "PowerFactor"),
        "CosPhiB": Info(symbol: "cos φB", title: "Коэффициент мощности, фаза B", category: "PowerFactor"),
        "CosPhiC": Info(symbol: "cos φC", title: "Коэффициент мощности, фаза C", category: "PowerFactor"),
        "PhiUAB": Info(symbol: "φ UA–UB", title: "Угол между фазами A и B", category: "PhaseAngle"),
        "PhiUAC": Info(symbol: "φ UA–UC", title: "Угол между фазами A и C", category: "PhaseAngle"),
        "PhiUBC": Info(symbol: "φ UB–UC", title: "Угол между фазами B и C", category: "PhaseAngle"),
        "PhiUIA": Info(symbol: "φ UA–IA", title: "Угол между U и I, фаза A", category: "PhaseAngle"),
        "PhiUIB": Info(symbol: "φ UB–IB", title: "Угол между U и I, фаза B", category: "PhaseAngle"),
        "PhiUIC": Info(symbol: "φ UC–IC", title: "Угол между U и I, фаза C", category: "PhaseAngle")
    ]

    /// Единицы для категорий, которых нет в списке единиц сервера (электрические величины).
    private static let defaultUnits: [String: String] = [
        "ActiveElectricalEnergy": "кВт·ч",
        "ReactiveElectricalEnergy": "квар·ч",
        "ActiveElectricPower": "кВт",
        "ReactiveElectricPower": "квар",
        "ApparentElectricPower": "кВ·А",
        "Voltage": "В",
        "ElectricCurrent": "А",
        "Frequency": "Гц",
        "PhaseAngle": "°",
        "PowerFactor": ""
    ]

    /// Подписи единиц (Unit в swagger).
    private static let unitTitles: [String: String] = [
        "TechnicalAt": "кгс/см²",
        "CelsiusDegree": "°C",
        "Ton": "т",
        "CubicMeter": "м³",
        "GigaCalorie": "Гкал",
        "Kilowatt": "кВт",
        "Hour": "ч",
        "Day": "сут",
        "KilowattHour": "кВт·ч",
        "GigaJoule": "ГДж",
        "MegaPascal": "МПа",
        "Kilogram": "кг",
        "Watt": "Вт",
        "KiloPascal": "кПа",
        "KilowattHourHeat": "кВт·ч",
        "MegawattHour": "МВт·ч",
        "Litre": "л",
        "Bar": "бар",
        "TeraJoule": "ТДж",
        "Kiloton": "тыс. т",
        "KilovarHour": "квар·ч",
        "WattHour": "Вт·ч",
        "VarHour": "вар·ч",
        "MegaJoule": "МДж",
        "MegawattHourHeat": "МВт·ч",
        "WattHourHeat": "Вт·ч",
        "Joule": "Дж",
        "WattHeat": "Вт",
        "KilowattHeat": "кВт",
        "Var": "вар",
        "Kilovar": "квар",
        "MegaCalorie": "Мкал",
        "KiloCalorie": "ккал",
        "KiloJoule": "кДж",
        "Kelvin": "К",
        "KiloVoltAmper": "кВ·А",
        "Minute": "мин",
        "Second": "с",
        "VA": "В·А",
        "Volt": "В",
        "Amper": "А",
        "Degree": "°",
        "Herz": "Гц",
        "Meter": "м",
        "Ppm": "ppm",
        "Percent": "%",
        "KilogramPerCubicMeter": "кг/м³"
    ]
}
