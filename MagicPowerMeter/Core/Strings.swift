import Foundation

enum Strings {
	enum Common {
		static let appName = "Magic Power Meter"
		static let unavailable = "—"
		static let base = "База"
		static let singleMeasurement = "Одиночный замер"
		static let comparisonMeasurement = "Сравнительный замер"
		static let sprintMeasurement = "Ежеспринтовый замер"
		static let mean = "Среднее"
		static let iteration = "Итерация"
		static let source = "Источник"
		static let incompleteResult = "Неполный результат"
		static let completeResult = "Полный результат"
		static let watts = "Вт"
		static let powerWatts = "Мощность, Вт"
		static let deltaWatts = "Δ к базе, Вт"
		static let deltaPercent = "Δ к базе, %"

		static func condition(_ number: Int) -> String { "Условие \(number)" }
	}

	enum Measurement {
		static let sprintScenarios = [
			"ВДНХ статика (авторизован)", "ВДНХ статика (неавторизован)",
			"ВДНХ динамика (авторизован)", "ВДНХ динамика (неавторизован)", "Сочи Дендрарий динамика"
		]
		static let invalidName = "Название замера не должно быть пустым."
		static let sensorSource = "ДАТЧИК"
		static let demoSource = "ДЕМО — СИНТЕТИЧЕСКИЕ ДАННЫЕ"
		static let invalidUTF8 = "Строка не является UTF-8"
		static let expectedReading = "Ожидается count;voltage_V;current_mA;power_W"
		static let invalidReading = "Некорректное или отрицательное показание"
		static let oversizedLine = "Строка длиннее 4096 байт"
		static let counterReset = "Счётчик датчика сброшен или повторён"
		static let timerFinished = "Таймер завершён"
		static let insufficientCoverage = "Недостаточное покрытие данными"
		static let readingTimeout = "Таймаут показаний"
		static let manuallyStopped = "Остановлено вручную — исключено из расчётов"
		static let finalizedEarly = "Сессия завершена досрочно — исключено из расчётов"
		static let invalidState = "Сначала остановите текущую итерацию или создайте новую сессию."
		static let invalidIteration = "Итерация недоступна или уже завершена."

		static func header(at elapsed: TimeInterval) -> String {
			"Заголовок / возможный reset датчика на \(Numeric.text(elapsed)) с"
		}

		static func invalidLine(at elapsed: TimeInterval, reason: String) -> String {
			"\(Numeric.text(elapsed)) с: \(reason)"
		}

		static func missingLines(_ count: UInt64) -> String { "Пропущены строки: \(count)" }

		static func gap(_ seconds: TimeInterval) -> String { "Разрыв данных: \(Numeric.text(seconds)) с" }
	}

	enum Export {
		static let result = "Результат"
		static let completeness = "Комплектность"
		static let recording = "Идёт запись"
		static let chooseFolder = "Выбрать папку"
		static let folderMessage = "Папка для CSV и исходных текстовых логов Magic Power Meter"
		static let folderSelected = "Папка выбрана. Запись будет подтверждена отдельно."

		static func powerHeader(_ condition: String) -> String { "\(condition), Вт" }
		static func deltaHeader(_ condition: String) -> String { "\(condition): Δ к базе, Вт" }
		static func percentHeader(_ condition: String) -> String { "\(condition): Δ к базе, %" }
		static func completeness(completed: Int, total: Int) -> String { "\(completed)/\(total)" }
		static func saved(paths: [String]) -> String { "Сохранено:\n" + paths.joined(separator: "\n") }

		static func failed(_ reason: String) -> String {
			"Не удалось сохранить файлы: \(reason). Данные остались в памяти; повторите экспорт."
		}

		static func csvGenerated(needsFolder: Bool) -> String {
			"CSV сформирован в памяти. " + (needsFolder ? "Выберите папку для сохранения на диск." : "")
		}
	}

	enum Connection {
		static let notConnected = "Не подключён"
		static let selectSource = "Выберите источник и подключитесь"
		static let disconnected = "Отключено"
		static let demoReady = "Демонстрация · не реальные измерения"
		static let sensorReady = "Данные датчика проверены · готов к измерению"
		static let failed = "Нет корректных данных / ошибка подключения"
		static let disconnectedAttempt = "Подключение отключено — исключено из расчётов"
		static let demoName = "Демонстрационный источник"
		static let noPorts = "Доступные serial-порты не найдены."
		static let unavailablePort = "Порт отключён или недоступен"
		static let parityNone = "Нет"
		static let parityEven = "Чётная"
		static let parityOdd = "Нечётная"
		static let lineLF = "LF / CRLF"
		static let lineCRLF = "CRLF"
		static let lineCR = "CR"

		static func summary(baud: Int, dataBits: Int, parity: String, stopBits: Int) -> String {
			"\(baud) бод · \(dataBits)\(parity)\(stopBits) · без flow control"
		}

		static func description(port: String, settings: String) -> String { "\(port) · \(settings)" }
		static func excluded(_ reason: String) -> String { reason + " — исключено из расчётов" }
		static func discoveryFailed(_ status: Int32) -> String { "Не удалось получить список serial-портов: IOKit \(status)" }

		static func preparing(_ path: String) -> String {
			"Подготовка \(path) · ожидаем корректные данные, возможен reset Arduino"
		}

		static func portError(path: String, reason: String) -> String { "\(path): \(reason)" }

		static func exclusiveAccessFailed(_ reason: String) -> String {
			"не удалось получить исключительный доступ: \(reason)"
		}

		static func attributesFailed(_ reason: String) -> String { "tcgetattr: \(reason)" }
		static func configurationFailed(_ reason: String) -> String { "настройка порта: \(reason)" }
		static func readFailed(_ reason: String) -> String { "Ошибка чтения: \(reason)" }

		static func connectionFailed(_ details: String) -> String {
			"Подключение не установлено.\n\(details)\nПроверьте кабель, питание и закройте CoolTerm."
		}

		static func timeout(_ seconds: Int) -> String { "За \(seconds) с не получены корректные показания датчика" }

		static func reconnect(path: String, reason: String) -> String {
			"\(path): \(reason). Переподключите порт; автоматическая подмена не выполнялась."
		}
	}

	enum Model {
		static let noIteration = "Итерация не выбрана"
		static let existingSession = "Сначала завершите текущую сессию и нажмите «Новый замер»."
		static let invalidDuration = "Укажите ненулевую длительность; секунды должны быть от 0 до 59."
		static let invalidConditions = "Задайте имена условий и от 1 до 50 итераций для каждого."
		static let activity = "Запись показаний Magic Power Meter"
		static let iterationFinished = "Итерация завершена. Подготовьте следующий сценарий на телефоне и нажмите «Старт»."
		static let retryUnavailable = "Для перезамера выберите записанную итерацию сравнительного или ежеспринтового замера и подключите исходный источник."
		static let retryFinished = "Перезамер завершён. Таблица, графики и CSV обновлены."
		static let allIterationsRecorded = "Все итерации записаны. Нажмите «Завершить замер»."

		static func selectedIteration(condition: String, number: Int) -> String { "\(condition) · итерация \(number)" }
		static func incompleteAttempt(_ reason: String) -> String { "Неполная попытка исключена из расчётов. \(reason)" }
		static func previousResultKept(_ reason: String) -> String {
			"Перезамер не завершён: предыдущий полный результат сохранён. \(reason)"
		}
	}

	enum UI {
		static let aboutApp = "О приложении Magic Power Meter"
		static let githubDocumentation = "Документация на GitHub"
		static let arduinoSketchHelp = "Для передачи корректных данных с датчика на Arduino нужно использовать скетч PowerConsumption.ino."
		static let arduinoDocumentation = "Инструкция и скетч PowerConsumption.ino"
		static let easterEggTitle = "Древняя Магия"
		static let easterEggMessage = "Здравствуй, мой любопытный друг! Это прекрасное приложение было создано адептом ордена Древней Магии, которого зовут Павел Маташнёв. Если тебе нравится приложение, можешь кинуть ему спасибок :3"
		static let ok = "ОК"
		static let lightTheme = "Светлая тема"
		static let darkTheme = "Тёмная тема"
		static let switchToLightTheme = "Переключить на светлую тему"
		static let switchToDarkTheme = "Переключить на тёмную тему"
		static let mode = "Режим"
		static let singleMode = "Одиночный"
		static let comparisonMode = "Сравнительный"
		static let sprintMode = "Ежеспринтовый"
		static let sprintHelp = "Пять независимых сценариев по три итерации. Средняя мощность каждого сценария — без базы и дельт."
		static let renameMeasurement = "Переименовать"
		static let measurementName = "Название замера"
		static let saveName = "Сохранить название"
		static let remeasure = "Перезамер"
		static let retryHelp = "Подготовьте сценарий на телефоне. Прежний полный результат сохранится до успешного завершения новой попытки."
		static let tableTab = "Таблица"
		static let chartsTab = "Графики"
		static let resultView = "Представление результата"
		static let includedAttempt = "Эта попытка учитывается в результате."
		static let supersededAttempt = "Архивная полная попытка — заменена успешным перезамером и не учитывается."
		static let excludedAttempt = "Неполная попытка — не учитывается в результате."
		static let noAttempt = "Эта итерация ещё не записана."
		static let independentResultsHelp = "Среднее каждого сценария рассчитано независимо по его полным итерациям. Неполные и заменённые попытки не учитываются. «—» означает отсутствие полного результата."
		static let demoBadge = "ДЕМО · синтетические данные"
		static let history = "Другие замеры в памяти"
		static let chooseMeasurement = "Выбрать замер"
		static let footer = "Magic Power Meter · Arduino + INA219 · Древняя Магия сохраняет данные и прогресс до выхода из приложения"
		static let finishEarly = "Завершить замер досрочно?"
		static let continueMeasuring = "Продолжить измерения"
		static let finishIncomplete = "Завершить с неполным результатом"
		static let finishWarning = "Незавершённая попытка будет остановлена и исключена из расчётов. Сырые данные сохранятся в памяти. Результат и CSV получат отметку «Неполный результат»."
		static let currentPort = "Текущий порт"
		static let ready = "Готов"
		static let preparing = "Подготовка"
		static let demoFrequency = "Демоисточник · 1 Гц"
		static let portSettings = "Настройки порта…"
		static let disconnect = "Отключить"
		static let connect = "Подключить"
		static let saveRaw = "Сохранять сырой лог (.txt)"
		static let noFolder = "Папка не выбрана · логи пока только в памяти"
		static let saving = "Сохранение файлов…"
		static let chooseFolder = "Выбрать папку…"
		static let comparisonSetup = "Настройка сравнения"
		static let singleSetup = "Новый одиночный замер"
		static let comparisonHelp = "Одно базовое условие и варианты. Число итераций может различаться."
		static let singleHelp = "Подключитесь, задайте длительность и создайте замер. Отсчёт начнётся только после «Старт»."
		static let conditionName = "Название условия"
		static let addCondition = "＋ Добавить условие"
		static let iterationDuration = "Длительность одной итерации"
		static let sharedDuration = "Одинаковая для всех условий · автоостановка"
		static let createSession = "Создать замер →"
		static let manualScenarios = "Сценарий на iPhone меняется вручную. Подготовьте следующий сценарий и нажмите «Старт». Между итерациями запись не идёт."
		static let minutesPlaceholder = "Мин"
		static let minutesAccessibility = "Минуты"
		static let minutesUnit = "мин"
		static let secondsPlaceholder = "Сек"
		static let secondsAccessibility = "Секунды"
		static let secondsUnit = "сек"
		static let sessionHelp = "Все итерации — в одной сессии, без отдельных файлов"
		static let finished = "Замер завершён"
		static let newMeasurement = "Новый замер"
		static let progress = "Общий прогресс"
		static let baseCondition = "Базовое условие"
		static let comparisonToBase = "Сравнение с базой"
		static let nextIteration = "Следующая итерация →"
		static let start = "▶ Старт"
		static let stop = "■ Стоп"
		static let attempts = "Попытки"
		static let currentPower = "Текущая мощность"
		static let lastPower = "Последняя мощность"
		static let lastSample = "Последний полученный отсчёт"
		static let stoppedSample = "Последнее значение · обновление остановлено"
		static let meanPower = "Средняя мощность"
		static let elapsed = "Прошло"
		static let recording = "● Запись"
		static let readyToStart = "Готово к старту"
		static let saveCSV = "Сохранить CSV…"
		static let iterationLogs = "Логи итерации…"
		static let allLogs = "Все логи…"
		static let diagnostics = "Диагностика: пропуски, повреждённые строки, reset"
		static let stopHelp = "«Стоп» завершает попытку без учёта в расчётах. «Завершить замер» формирует итог всей сессии."
		static let finish = "Завершить замер"
		static let powerChart = "Потребляемая мощность"
		static let chartRange = "Шкала 0–15 Вт"
		static let timeAxis = "Время"
		static let zeroAxis = "Ноль"
		static let timeLegend = "Время, мин:сек"
		static let aboveChart = "Есть значения выше 15 Вт: они сохранены и учтены в среднем, но находятся за шкалой графика."
		static let results = "Результаты замера"
		static let noBase = "Нет полной базы: дельты не рассчитаны."
		static let resultsHelp = "Неполные попытки исключены. «Среднее» — среднее полных итераций каждого условия. Δ строки — к базе той же итерации; итоговая Δ — из средних. «—» означает отсутствие пары; при нулевой базе процент не определён."
		static let serialSettings = "Настройки считывания порта"
		static let realSensor = "Реальный датчик"
		static let demoOption = "ДЕМО (синтетические данные)"
		static let port = "Порт"
		static let automaticPort = "Авто — первый с корректными данными"
		static let refreshPorts = "Обновить список портов"
		static let baud = "Скорость"
		static let dataBits = "Биты данных"
		static let parity = "Чётность"
		static let stopBits = "Стоп-биты"
		static let lineEnding = "Конец строки"
		static let serialHelp = "Без flow control. Открытие порта может перезапустить Arduino. Подготовка и проверка данных не входят в измеряемое время. При автовыборе каждый порт проверяется до таймаута; ручной порт не подменяется."
		static let preview = "Исходные данные появятся после подключения…"
		static let cancel = "Отмена"
		static let applyConnection = "Применить и подключиться"

		static func history(date: Date, source: MeasurementSource, completed: Int, total: Int) -> String {
			"\(date.formatted(date: .abbreviated, time: .shortened)) · \(source.rawValue) · \(completed)/\(total)"
		}

		static func namedHistory(name: String, mode: MeasurementMode, details: String) -> String {
			"\(name) · \(mode.title) · \(details)"
		}

		static func modeTitle(_ mode: MeasurementMode) -> String {
			switch mode {
			case .single: return singleMode
			case .comparison: return comparisonMode
			case .sprint: return sprintMode
			}
		}

		static func startTarget(condition: String, number: Int) -> String {
			"По нажатию «Старт»: \(Model.selectedIteration(condition: condition, number: number))"
		}

		static func wrongSource(_ source: MeasurementSource) -> String {
			"Источник этой сессии: \(source.rawValue). Для продолжения выберите тот же источник в настройках порта."
		}

		static func iterations(_ count: Int) -> String { "\(count) ит." }
		static func plannedTime(iterations: Int, time: String) -> String { "\(iterations) ит. · \(time) чистого времени" }
		static func progress(completed: Int, total: Int) -> String { "\(completed) / \(total) полных" }

		static func iteration(number: Int, complete: Bool, active: Bool, attempted: Bool) -> String {
			"\(complete ? "✓ " : active ? "● " : attempted ? "! " : "")\(number)"
		}

		static func autoStop(_ time: String) -> String { "Автостоп через \(time)" }
		static func attempt(number: Int, complete: Bool) -> String { "\(number) · \(complete ? "полная" : "неполная")" }

		static func meanHelp(preliminary: Bool) -> String {
			"По валидным отсчётам выбранной попытки" + (preliminary ? " · предварительно" : "")
		}

		static func elapsedTime(_ elapsed: String, target: String) -> String { "\(elapsed) / \(target)" }
		static func remaining(_ time: String) -> String { "Осталось \(time)" }

		static func diagnostics(samples: Int, frequency: String, missing: String, warnings: Int) -> String {
			"\(samples) отсчётов · \(frequency) Гц · пропусков: \(missing) · \(warnings) предупреждений"
		}

		static func results(incomplete: Bool, completed: Int, total: Int) -> String {
			"\(incomplete ? Common.incompleteResult : Common.completeResult) · \(completed) / \(total) полных итераций"
		}

		static func conditionProgress(name: String, completed: Int, total: Int) -> String { "\(name): \(completed) / \(total)" }

		static func requiredSource(_ source: MeasurementSource?) -> String {
			"Для продолжения этой сессии требуется источник: \(source?.rawValue ?? ""). Данные другого источника в неё не записываются."
		}

		static func unavailablePort(_ path: String) -> String { "\(path) (недоступен)" }
		static func timeout(_ seconds: Int) -> String { "Таймаут: \(seconds) с" }
	}
}
