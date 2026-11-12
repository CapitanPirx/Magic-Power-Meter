import XCTest
@testable import PowerMeterCore

final class StringsTests: XCTestCase {
	func testParameterizedResourcesKeepLiteralOutput() {
		XCTAssertEqual(Strings.Common.condition(2), "Условие 2")
		XCTAssertEqual(Strings.Measurement.header(at: 1.25), "Заголовок / возможный reset датчика на 1,250 с")
		XCTAssertEqual(Strings.Measurement.invalidLine(at: 2, reason: "bad"), "2,000 с: bad")
		XCTAssertEqual(Strings.Measurement.missingLines(4), "Пропущены строки: 4")
		XCTAssertEqual(Strings.Measurement.gap(3.5), "Разрыв данных: 3,500 с")
		XCTAssertEqual(Strings.Export.powerHeader("A; B"), "A; B, Вт")
		XCTAssertEqual(Strings.Export.deltaHeader("A"), "A: Δ к базе, Вт")
		XCTAssertEqual(Strings.Export.percentHeader("A"), "A: Δ к базе, %")
		XCTAssertEqual(Strings.Export.completeness(completed: 1, total: 3), "1/3")
		XCTAssertEqual(Strings.Export.saved(paths: ["/a", "/b"]), "Сохранено:\n/a\n/b")
		XCTAssertEqual(Strings.Export.failed("bad"), "Не удалось сохранить файлы: bad. Данные остались в памяти; повторите экспорт.")
		XCTAssertEqual(Strings.Export.csvGenerated(needsFolder: false), "CSV сформирован в памяти. ")
		XCTAssertEqual(Strings.Connection.summary(baud: 19200, dataBits: 7, parity: "E", stopBits: 2),
					   "19200 бод · 7E2 · без flow control")
		XCTAssertEqual(Strings.Connection.description(port: "/dev/x", settings: "8N1"), "/dev/x · 8N1")
		XCTAssertEqual(Strings.Connection.excluded("bad"), "bad — исключено из расчётов")
		XCTAssertEqual(Strings.Connection.discoveryFailed(-1), "Не удалось получить список serial-портов: IOKit -1")
		XCTAssertEqual(Strings.Connection.preparing("/dev/x"), "Подготовка /dev/x · ожидаем корректные данные, возможен reset Arduino")
		XCTAssertEqual(Strings.Connection.portError(path: "/x", reason: "bad"), "/x: bad")
		XCTAssertEqual(Strings.Connection.exclusiveAccessFailed("bad"), "не удалось получить исключительный доступ: bad")
		XCTAssertEqual(Strings.Connection.attributesFailed("bad"), "tcgetattr: bad")
		XCTAssertEqual(Strings.Connection.configurationFailed("bad"), "настройка порта: bad")
		XCTAssertEqual(Strings.Connection.readFailed("bad"), "Ошибка чтения: bad")
		XCTAssertEqual(Strings.Connection.connectionFailed("bad"), "Подключение не установлено.\nbad\nПроверьте кабель, питание и закройте CoolTerm.")
		XCTAssertEqual(Strings.Connection.timeout(8), "За 8 с не получены корректные показания датчика")
		XCTAssertEqual(Strings.Connection.reconnect(path: "/x", reason: "bad"), "/x: bad. Переподключите порт; автоматическая подмена не выполнялась.")
		XCTAssertEqual(Strings.Model.selectedIteration(condition: "A", number: 2), "A · итерация 2")
		XCTAssertEqual(Strings.Model.incompleteAttempt("bad"), "Неполная попытка исключена из расчётов. bad")
	}

	func testParameterizedUIResourcesKeepLiteralOutput() {
		XCTAssertEqual(Strings.UI.wrongSource(.serial), "Источник этой сессии: ДАТЧИК. Для продолжения выберите тот же источник в настройках порта.")
		XCTAssertEqual(Strings.UI.iterations(3), "3 ит.")
		XCTAssertEqual(Strings.UI.plannedTime(iterations: 3, time: "09:00"), "3 ит. · 09:00 чистого времени")
		XCTAssertEqual(Strings.UI.progress(completed: 1, total: 3), "1 / 3 полных")
		XCTAssertEqual(Strings.UI.iteration(number: 2, complete: true, active: true, attempted: true), "✓ 2")
		XCTAssertEqual(Strings.UI.iteration(number: 2, complete: false, active: true, attempted: true), "● 2")
		XCTAssertEqual(Strings.UI.iteration(number: 2, complete: false, active: false, attempted: true), "! 2")
		XCTAssertEqual(Strings.UI.iteration(number: 2, complete: false, active: false, attempted: false), "2")
		XCTAssertEqual(Strings.UI.autoStop("03:00"), "Автостоп через 03:00")
		XCTAssertEqual(Strings.UI.attempt(number: 1, complete: true), "1 · полная")
		XCTAssertEqual(Strings.UI.attempt(number: 2, complete: false), "2 · неполная")
		XCTAssertEqual(Strings.UI.meanHelp(preliminary: true), "По валидным отсчётам выбранной попытки · предварительно")
		XCTAssertEqual(Strings.UI.meanHelp(preliminary: false), "По валидным отсчётам выбранной попытки")
		XCTAssertEqual(Strings.UI.elapsedTime("00:01", target: "03:00"), "00:01 / 03:00")
		XCTAssertEqual(Strings.UI.remaining("02:59"), "Осталось 02:59")
		XCTAssertEqual(Strings.UI.diagnostics(samples: 3, frequency: "1,000", missing: "2", warnings: 1),
					   "3 отсчётов · 1,000 Гц · пропусков: 2 · 1 предупреждений")
		XCTAssertEqual(Strings.UI.results(incomplete: true, completed: 1, total: 3), "Неполный результат · 1 / 3 полных итераций")
		XCTAssertEqual(Strings.UI.results(incomplete: false, completed: 3, total: 3), "Полный результат · 3 / 3 полных итераций")
		XCTAssertEqual(Strings.UI.conditionProgress(name: "A", completed: 1, total: 3), "A: 1 / 3")
		XCTAssertEqual(Strings.UI.requiredSource(.demo), "Для продолжения этой сессии требуется источник: ДЕМО — СИНТЕТИЧЕСКИЕ ДАННЫЕ. Данные другого источника в неё не записываются.")
		XCTAssertEqual(Strings.UI.requiredSource(nil), "Для продолжения этой сессии требуется источник: . Данные другого источника в неё не записываются.")
		XCTAssertEqual(Strings.UI.unavailablePort("/x"), "/x (недоступен)")
		XCTAssertEqual(Strings.UI.timeout(8), "Таймаут: 8 с")
	}
}
