import SwiftUI

// Экран входа: заголовок с названием приложения, адрес сервера, логин, пароль и кнопка «Войти».
// Вся логика — в LoginViewModel; здесь только внешний вид.
//
// Устроен как обычная форма iOS (Form): поля сгруппированы в «карточки», большая синяя кнопка
// на всю ширину. Так выглядят окна входа в приложениях Apple.
//
// Адрес сервера (решение владельца 2026-10-04): переключатель HTTPS/HTTP, имя сервера и справа
// в той же строке — порт (подставляется сам: 443 или 10000). Примеров-подсказок в поле нет:
// для знакомства есть ссылка «Демо-доступ» под кнопкой «Войти».
struct LoginView: View {
    @State private var model: LoginViewModel

    /// Какое поле сейчас активно (в нём мигает курсор) — чтобы кнопка «Далее»
    /// на клавиатуре переводила к следующему полю.
    @FocusState private var focusedField: Field?

    /// Верхний отступ формы — чтобы она стояла посередине экрана (считается по размерам прокрутки).
    @State private var topMargin: CGFloat = 0

    /// Наибольшая ширина формы. На iPad и Mac растянутые на весь экран поля неудобны и смотрятся пусто —
    /// форма стоит посередине, по бокам серый фон. На iPhone экран уже, ограничение не срабатывает.
    private static let maxFormWidth: CGFloat = 540

    /// Показывать ли пароль открытым текстом (кнопка с глазом справа от поля).
    @State private var isPasswordVisible = false

    private enum Field {
        case server, port, login, password
    }

    /// Ширина поля порта: хватает на «10000». @ScaledMetric — растёт вместе с размером шрифта
    /// (если в Настройках iPhone выбран крупный текст).
    @ScaledMetric private var portFieldWidth: CGFloat = 64

    init(session: AppSession) {
        // @State запоминает модель при первом показе экрана и дальше не пересоздаёт её.
        _model = State(initialValue: LoginViewModel(session: session))
    }

    var body: some View {
        Form {
            headerSection
            serverSection
            accountSection
            buttonSection
        }
        // Уменьшенные отступы между блоками и сверху — чтобы поля и кнопка «Войти»
        // помещались над открытой клавиатурой даже на iPhone 16e.
        .listSectionSpacing(.compact)
        // Форма короче экрана — ставим её посередине, а не прижимаем к верху (как экраны входа Apple):
        // верхний отступ = половина свободного места. Свободное место узнаём из размеров прокрутки
        // (onScrollGeometryChange, iOS 18). С открытой клавиатурой места нет — отступ сам станет 0.
        .contentMargins(.top, topMargin, for: .scrollContent)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            // Сколько места осталось под формой при нынешнем отступе.
            geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
                - geometry.contentSize.height
        } action: { _, freeSpace in
            // Свободное место «как если бы отступа не было» = freeSpace + topMargin; сверху — половина.
            let newMargin = max(0, (freeSpace + topMargin) / 2)
            if abs(newMargin - topMargin) > 1 {
                topMargin = newMargin
            }
        }
        // Внизу экрана — короткое пояснение о конфиденциальности. Пока открыта клавиатура, прячем:
        // иначе оно поднимется над клавиатурой и отнимет место у полей.
        .safeAreaInset(edge: .bottom) {
            if focusedField == nil {
                privacyNote
            }
        }
        // Клавиатура убирается, если потянуть форму вниз (как в «Настройках» iPhone).
        // Сразу при открытии клавиатуру не показываем — пусть пользователь сначала увидит форму.
        .scrollDismissesKeyboard(.interactively)
        // На широком экране (iPad, Mac) форма — не шире maxFormWidth, посередине; поля по бокам —
        // того же серого цвета, что фон формы. Обычная рамка, как у карточек (readableWidth).
        .frame(maxWidth: Self.maxFormWidth)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
        // Вход не удался (неверный пароль, сервер недоступен…) — вибрация «ошибка».
        // На «Сессия истекла» при открытии экрана вибрации нет: текст есть с самого начала, он не менялся.
        .sensoryFeedback(.error, trigger: model.errorMessage) { _, newMessage in
            newMessage != nil
        }
        // Курсор ушёл из полей «Сервер» и «Порт» — проверяем, отвечает ли сервер.
        .onChange(of: focusedField) { oldField, newField in
            if isAddressField(oldField) && !isAddressField(newField) {
                model.serverFieldDidLoseFocus()
            }
        }
        .onChange(of: model.hostText) {
            model.hostTextDidChange()
        }
        .onChange(of: model.portText) {
            model.portTextDidChange()
        }
        .onChange(of: model.useHTTPS) {
            model.protocolDidChange()
            // Переключили протокол, не заходя в поля, — сразу проверяем сервер по новому адресу.
            if !isAddressField(focusedField) {
                model.serverFieldDidLoseFocus()
            }
        }
        .onChange(of: model.enteredAddress) {
            model.addressDidChange()
        }
    }

    // MARK: - Разделы формы

    /// Название приложения и строка о том, куда входим, — без фона, прямо на сером фоне формы.
    /// Без значка (решение владельца 2026-10-04): так над открытой клавиатурой остаётся место
    /// для всех полей и кнопки.
    private var headerSection: some View {
        Section {
            VStack(spacing: 6) {
                Text(appName)
                    .font(.title.bold())
                Text("Войдите с учётной записью вашего сервера ЛЭРС УЧЁТ.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .listRowBackground(Color.clear)
    }

    // Заголовков у блоков нет («Сервер», «Учётная запись»): что это за поля, понятно по значкам
    // и серым подсказкам в них, а без заголовков поля и кнопка помещаются над клавиатурой.
    private var serverSection: some View {
        Section {
            // Стандартный переключатель iOS из двух сегментов (как «День/Неделя» в Календаре).
            Picker("Протокол", selection: $model.useHTTPS) {
                Text("HTTPS").tag(true)
                Text("HTTP").tag(false)
            }
            .pickerStyle(.segmented)

            Label {
                HStack {
                    TextField("Сервер", text: $model.hostText)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .server)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .login }

                    // Тонкая вертикальная черта между именем сервера и портом.
                    Divider()

                    TextField("Порт", text: $model.portText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .port)
                        .frame(width: portFieldWidth)
                        .accessibilityLabel("Порт")
                }
            } icon: {
                fieldIcon("server.rack")
            }
        } footer: {
            serverFooter
        }
        .disabled(model.isLoggingIn)
    }

    /// Под адресом сервера: ошибка в адресе, результат проверки сервера и предупреждение про http.
    /// Если всё в порядке и сервер ещё не проверяли — пусто.
    @ViewBuilder
    private var serverFooter: some View {
        if model.isAddressErrorVisible, let serverError = model.serverErrorMessage {
            Text(serverError)
                .foregroundStyle(.red)
        } else if model.serverCheck != .notChecked || !model.useHTTPS {
            VStack(alignment: .leading, spacing: 6) {
                serverCheckStatus
                if !model.useHTTPS {
                    Label("Соединение не шифруется: логин, пароль и данные передаются открытым текстом.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// Результат проверки сервера: зелёный кружок и версия, красный кружок и причина,
    /// или «Проверка сервера…», пока ждём ответа.
    @ViewBuilder
    private var serverCheckStatus: some View {
        switch model.serverCheck {
        case .notChecked:
            EmptyView()
        case .checking:
            Label {
                Text("Проверка сервера…")
            } icon: {
                ProgressView()
                    .controlSize(.mini)
            }
        case .available(let version):
            Label {
                Text(version.isEmpty ? "Сервер доступен" : "Сервер доступен, версия \(version)")
            } icon: {
                statusDot(.green)
            }
        case .unavailable(let message):
            if ConnectionProblemNotice.visibleProblem(showsServerUnreachable: false) != nil {
                // Причина известна (нет интернета, белые списки) — говорим о ней вместо общей ошибки.
                ConnectionProblemNotice(showsServerUnreachable: false)
            } else {
                Label {
                    Text(message)
                        // Разрешаем тексту переноситься на сколько угодно строк, а не обрезаться «…».
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    statusDot(.red)
                }
            }
        }
        // Проверка сервера ещё ждёт ответа, но причина молчания уже понятна.
        if model.serverCheck == .checking {
            ConnectionProblemNotice(showsServerUnreachable: false)
        }
    }

    /// Круглый цветной индикатор, как «лампочка» состояния.
    private func statusDot(_ color: Color) -> some View {
        Image(systemName: "circle.fill")
            .foregroundStyle(color)
            .imageScale(.small)
            .accessibilityHidden(true)
    }

    private var accountSection: some View {
        Section {
            Label {
                TextField("Логин", text: $model.login)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .login)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
            } icon: {
                fieldIcon("person")
            }

            Label {
                HStack {
                    passwordField
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { logIn() }

                    // Кнопка «глаз»: показать или скрыть пароль.
                    Button {
                        isPasswordVisible.toggle()
                        // При переключении поле пароля заменяется другим — возвращаем в него курсор.
                        focusedField = .password
                    } label: {
                        Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    // borderless — чтобы нажималась только кнопка, а не вся строка формы.
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isPasswordVisible ? "Скрыть пароль" : "Показать пароль")
                }
            } icon: {
                fieldIcon("lock")
            }
        } footer: {
            if let loginError = model.loginErrorMessage {
                Text(loginError)
                    .foregroundStyle(.red)
            }
        }
        .disabled(model.isLoggingIn)
    }

    /// Поле пароля: со скрытыми символами (SecureField) или открытое (TextField).
    @ViewBuilder
    private var passwordField: some View {
        if isPasswordVisible {
            TextField("Пароль", text: $model.password)
        } else {
            SecureField("Пароль", text: $model.password)
        }
    }

    /// Кнопка «Войти» на всю ширину, под ней — «Демо-доступ», а во время входа — «Отмена».
    private var buttonSection: some View {
        Section {
            VStack(spacing: 12) {
                Button {
                    logIn()
                } label: {
                    HStack(spacing: 8) {
                        if model.isLoggingIn {
                            ProgressView()
                                .tint(.white)
                                // Кнопке ниже задан размер .large, и крутилка унаследовала бы его —
                                // она выше строки текста и раздувала бы кнопку при начале входа.
                                // Обычный размер крутилки помещается в высоту текста.
                                .controlSize(.regular)
                        }
                        Text(loginButtonTitle)
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                // Пока не всё заполнено — кнопка серая. Во время входа остаётся синей,
                // но повторно не нажимается (иначе ушёл бы второй запрос).
                .disabled(!model.canLogIn && !model.isLoggingIn)
                .allowsHitTesting(!model.isLoggingIn)

                // Под кнопкой всегда ровно одна строка одинакового размера: «Демо-доступ»,
                // а во время входа на её месте — «Отмена». Так высота формы не меняется
                // и кнопка «Войти» не сдвигается, когда начинается вход.
                if model.isLoggingIn {
                    Button("Отмена") {
                        model.cancelLogIn()
                    }
                    .font(.footnote)
                    .buttonStyle(.borderless)
                } else {
                    // Небольшая ссылка: заполняет адрес, логин и пароль демо-сервера.
                    Button("Демо-доступ") {
                        focusedField = nil
                        model.fillDemoAccess()
                    }
                    .font(.footnote)
                    .buttonStyle(.borderless)
                }
            }
            // Строка без белой «карточки» и без отступов — кнопка лежит прямо на фоне формы.
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } footer: {
            buttonFooter
        }
    }

    /// Надпись на кнопке. Что происходит во время входа, пишем прямо на ней,
    /// а не отдельной строкой: лишняя строка сдвигала бы кнопку.
    private var loginButtonTitle: String {
        if !model.isLoggingIn {
            return "Войти"
        }
        return model.isWaitingForNetwork ? "Ждём сеть…" : "Вход…"
    }

    /// Под кнопкой: ошибка последней попытки входа.
    @ViewBuilder
    private var buttonFooter: some View {
        if model.isLoggingIn {
            // Вход ещё ждёт ответа, но причина молчания сервера уже понятна.
            ConnectionProblemNotice(showsServerUnreachable: false)
        } else if model.errorMessage != nil && ConnectionProblemNotice.visibleProblem(showsServerUnreachable: false) != nil {
            ConnectionProblemNotice(showsServerUnreachable: false)
        } else if let errorMessage = model.errorMessage {
            Label(errorMessage, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    /// Пояснение внизу экрана: что приложение делает с паролем и данными, и ссылка на политику
    /// конфиденциальности (её Apple хочет видеть и в самом приложении). Ссылка в тексте —
    /// обычная разметка Markdown, SwiftUI делает её нажимаемой.
    private var privacyNote: some View {
        VStack(spacing: 6) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Приложение не сохраняет пароль, а данные передаются только на указанный сервер. [Политика конфиденциальности](https://stklb.ru/openluch/privacy/)")
                .multilineTextAlignment(.center)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 32)
        .padding(.bottom, 8)
        // На широком экране — не шире формы, посередине.
        .frame(maxWidth: Self.maxFormWidth)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Вспомогательное

    /// Поле — часть адреса сервера (имя или порт)?
    private func isAddressField(_ field: Field?) -> Bool {
        return field == .server || field == .port
    }

    private func logIn() {
        focusedField = nil
        model.logIn()
    }

    /// Серый значок слева от поля ввода.
    private func fieldIcon(_ systemName: String) -> some View {
        // Именно Color.secondary (серый), а не .secondary («бледнее основного цвета»): на iOS 18
        // основной цвет значков в форме — синий, и .secondary давал светло-синий (проверено 2026-10-04).
        Image(systemName: systemName)
            .foregroundStyle(Color.secondary)
    }

    /// Название приложения с главного экрана iPhone (сейчас «OpenLuch»).
    /// Берём из настроек сборки, чтобы при переименовании не править здесь.
    private var appName: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "OpenLuch"
    }
}

#Preview {
    LoginView(session: AppSession())
}
