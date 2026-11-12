import SwiftUI
import Charts

enum MeterTheme {
	static let page = Color(hex: 0x121715)
	static let surface = Color(hex: 0x222b26)
	static let raised = Color(hex: 0x2b3630)
	static let field = Color(hex: 0x19211d)
	static let selection = Color(hex: 0x283f32)
	static let border = Color(hex: 0x3b4941)
	static let ink = Color(hex: 0xeaf1ec)
	static let muted = Color(hex: 0xabb8b0)
	static let mint = Color(hex: 0x76ddbc)
	static let warning = Color(hex: 0xefc38a)
	static let error = Color(hex: 0xf2b9a2)
}

extension Color {
	init(hex: UInt32) {
		self.init(red: Double((hex >> 16) & 255) / 255,
				  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
	}
}

extension View {
	func meterCard(background: Color = MeterTheme.surface) -> some View {
		padding(18)
			.background(background, in: RoundedRectangle(cornerRadius: 11))
			.overlay(RoundedRectangle(cornerRadius: 11).stroke(MeterTheme.border, lineWidth: 1))
	}
}

func clockText(_ value: TimeInterval) -> String {
	guard value.isFinite else { return "—" }
	let seconds = max(0, value.rounded(.towardZero))
	return String(format: "%02.0f:%02.0f", locale: Locale(identifier: "en_US_POSIX"),
				  (seconds / 60).rounded(.down), seconds.truncatingRemainder(dividingBy: 60))
}

struct ContentView: View {
	@Bindable var model: MeterModel
	@State private var showSettings = false
	@State private var confirmFinish = false

	var body: some View {
		@Bindable var model = model
		ScrollView {
			VStack(alignment: .leading, spacing: 22) {
				connection
				storage
				HStack {
					Picker("Режим", selection: $model.comparison) {
						Text("Одиночный").tag(false)
						Text("Сравнительный").tag(true)
					}
					.pickerStyle(.segmented)
					.frame(width: 290)
					.disabled(model.session != nil)
					Spacer()
					if model.demo || model.session?.source == .demo {
						Label("ДЕМО · синтетические данные", systemImage: "testtube.2")
							.font(.caption.bold()).foregroundStyle(MeterTheme.warning)
					}
				}
				if let error = model.error {
					message(error, color: MeterTheme.error, icon: "exclamationmark.triangle")
				}
				if let notice = model.notice {
					message(notice, color: MeterTheme.muted, icon: "info.circle")
				}
				if !model.history.isEmpty {
					HStack {
						Text("Другие замеры в памяти").foregroundStyle(MeterTheme.muted)
						Menu("Выбрать замер") {
							ForEach(model.history, id: \.id) { session in
								Button("\(session.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(session.source.rawValue) · \(session.completedIterations)/\(session.totalIterations)") {
									model.showHistory(session.id)
								}
							}
						}.disabled(model.recording)
					}
				}
				if let session = model.session {
					if session.source != (model.demo ? .demo : .serial) {
						message("Источник этой сессии: \(session.source.rawValue). Для продолжения выберите тот же источник в настройках порта.", color: MeterTheme.warning, icon: "exclamationmark.triangle")
					}
					sessionPlan(session)
					recorder(session)
				} else {
					setup
				}
				Text("Magic Power Meter · Arduino + INA219 · данные и прогресс хранятся в памяти до выхода из приложения")
					.font(.caption).foregroundStyle(MeterTheme.muted)
			}
			.padding(28)
			.frame(maxWidth: 1180)
			.frame(maxWidth: .infinity)
		}
		.background(MeterTheme.page)
		.foregroundStyle(MeterTheme.ink)
		.tint(MeterTheme.mint)
		.frame(minWidth: 920, minHeight: 760)
		.sheet(isPresented: $showSettings) { PortSettingsView(model: model) }
		.alert("Завершить замер досрочно?", isPresented: $confirmFinish) {
			Button("Продолжить измерения", role: .cancel) {}
			Button("Завершить с неполным результатом", role: .destructive) { model.finalize() }
		} message: {
			Text("Незавершённая попытка будет остановлена и исключена из расчётов. Сырые данные сохранятся в памяти. Результат и CSV получат отметку «Неполный результат».")
		}
	}

	private var connection: some View {
		HStack(spacing: 14) {
			Image(systemName: "bolt.horizontal.circle.fill")
				.font(.system(size: 36)).foregroundStyle(MeterTheme.mint)
			VStack(alignment: .leading, spacing: 5) {
				Text("Текущий порт").font(.caption).foregroundStyle(MeterTheme.muted)
				Text(model.connectedPort).font(.system(.body, design: .monospaced)).textSelection(.enabled)
				Text(model.connectionStatus).font(.caption).foregroundStyle(MeterTheme.muted)
					.fixedSize(horizontal: false, vertical: true)
			}
			Spacer(minLength: 10)
			VStack(alignment: .trailing, spacing: 6) {
				Label(model.connected ? "Готов" : model.preparing ? "Подготовка" : "Не подключён",
					  systemImage: "circle.fill")
					.font(.caption).foregroundStyle(model.connected ? MeterTheme.mint : MeterTheme.warning)
				Text(model.demo ? "Демоисточник · 1 Гц" : model.settings.summary)
					.font(.caption2).foregroundStyle(MeterTheme.muted)
				HStack {
					Button("Настройки порта…") { showSettings = true }
					if model.connected || model.preparing {
						Button("Отключить") { model.disconnect() }
					} else {
						Button("Подключить") { model.connect() }
					}
				}.disabled(model.recording)
			}
		}
	}

	private var storage: some View {
		@Bindable var model = model
		return HStack(spacing: 14) {
			Toggle("Сохранять сырой лог (.txt)", isOn: $model.saveRaw)
				.toggleStyle(.checkbox)
			VStack(alignment: .leading, spacing: 3) {
				Text(model.folder?.path ?? "Папка не выбрана · логи пока только в памяти")
					.lineLimit(2).textSelection(.enabled)
				if model.pendingWrites > 0 { Text("Сохранение файлов…").foregroundStyle(MeterTheme.warning) }
			}.font(.caption).foregroundStyle(MeterTheme.muted)
			Spacer()
			Button("Выбрать папку…") { model.chooseFolder() }
				.disabled(model.recording || model.pendingWrites > 0)
		}.meterCard()
	}

	private var setup: some View {
		@Bindable var model = model
		return VStack(alignment: .leading, spacing: 16) {
			Text(model.comparison ? "Настройка сравнения" : "Новый одиночный замер")
				.font(.title2.weight(.semibold))
			Text(model.comparison ? "Одно базовое условие и варианты. Число итераций может различаться."
				 : "Подключитесь, задайте длительность и создайте замер. Отсчёт начнётся только после «Старт».")
				.foregroundStyle(MeterTheme.muted)
			VStack(alignment: .leading, spacing: 18) {
				if model.comparison {
					ForEach(Array(model.conditions.enumerated()), id: \.element.id) { index, condition in
						HStack(spacing: 12) {
							Text(index == 0 ? "База" : "Условие \(index)")
								.font(.caption).foregroundStyle(MeterTheme.muted).frame(width: 85, alignment: .leading)
							TextField("Название условия", text: $model.conditions[index].name)
							Stepper(value: $model.conditions[index].iterations, in: 1...50) {
								Text("\(model.conditions[index].iterations) ит.").monospacedDigit().frame(width: 55)
							}.frame(width: 105)
							Button(role: .destructive) { model.conditions.removeAll { $0.id == condition.id } } label: {
								Image(systemName: "minus.circle")
							}.disabled(index == 0 || model.conditions.count <= 2).buttonStyle(.borderless)
						}
					}
					Button("＋ Добавить условие") {
						model.conditions.append(Condition(name: "Условие \(model.conditions.count)", iterations: 3))
					}.disabled(model.conditions.count >= 12)
					Divider()
				}
				HStack {
					VStack(alignment: .leading, spacing: 5) {
						Text("Длительность одной итерации").fontWeight(.medium)
						Text("Одинаковая для всех условий · автоостановка")
							.font(.caption).foregroundStyle(MeterTheme.muted)
					}
					Spacer()
					durationFields
				}
				HStack {
					let total = model.comparison ? model.conditions.reduce(0) { $0 + $1.iterations } : 1
					Text("\(total) ит. · \(clockText(Double(total) * model.duration)) чистого времени")
						.font(.caption).foregroundStyle(MeterTheme.muted)
					Spacer()
					Button("Создать замер →") { model.createSession() }
						.buttonStyle(.borderedProminent).foregroundStyle(Color(hex: 0x0d2b20))
				}
			}.meterCard()
			Text("Условия и сценарий на iPhone меняются вручную. Между итерациями запись не идёт: выберите нужную и нажмите «Старт».")
				.font(.caption).foregroundStyle(MeterTheme.muted)
		}
	}

	private var durationFields: some View {
		@Bindable var model = model
		return HStack(spacing: 8) {
			TextField("Мин", value: $model.minutes, format: .number.grouping(.never))
				.frame(width: 58).accessibilityLabel("Минуты")
			Text("мин")
			TextField("Сек", value: $model.seconds, format: .number.grouping(.never))
				.frame(width: 48).accessibilityLabel("Секунды")
			Text("сек")
		}.textFieldStyle(.roundedBorder)
	}

	private func sessionPlan(_ session: MeasurementSession) -> some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack {
				VStack(alignment: .leading, spacing: 5) {
					Text(session.conditions.count == 1 ? "Одиночный замер" : "Сравнительный замер")
						.font(.title2.weight(.semibold))
					Text("Все итерации — в одной сессии, без отдельных файлов")
						.font(.caption).foregroundStyle(MeterTheme.muted)
				}
				Spacer()
				if session.finalized {
					Text(session.incomplete ? "Неполный результат" : "Замер завершён")
						.foregroundStyle(session.incomplete ? MeterTheme.warning : MeterTheme.mint)
					Button("Новый замер") { model.newSession() }
				}
			}
			VStack(alignment: .leading, spacing: 14) {
				HStack {
					Text("Общий прогресс")
					Spacer()
					Text("\(session.completedIterations) / \(session.totalIterations) полных").monospacedDigit()
				}.font(.caption)
				ProgressView(value: Double(session.completedIterations), total: Double(max(1, session.totalIterations)))
				ForEach(Array(session.conditions.enumerated()), id: \.element.id) { index, condition in
					HStack(alignment: .top) {
						VStack(alignment: .leading, spacing: 4) {
							Text(condition.name).fontWeight(.medium)
							Text(index == 0 ? "Базовое условие" : "Сравнение с базой")
								.font(.caption2).foregroundStyle(MeterTheme.muted)
						}.frame(width: 190, alignment: .leading)
						ScrollView(.horizontal) {
							HStack {
								ForEach(1...condition.iterations, id: \.self) { number in
									iterationButton(IterationKey(conditionID: condition.id, number: number), session: session)
								}
							}.padding(2)
						}
					}
				}
				Text("✓ Полная · ● Записывается · ! Неполная · номер — ещё не начата")
					.font(.caption2).foregroundStyle(MeterTheme.muted)
			}.meterCard()
		}
	}

	private func iterationButton(_ key: IterationKey, session: MeasurementSession) -> some View {
		let attempt = session.latest(key)
		let complete = session.completed(key) != nil
		let active = session.active?.key == key
		let selected = model.selected == key
		let color = complete ? MeterTheme.mint : attempt != nil ? MeterTheme.warning : MeterTheme.muted
		return Button {
			model.select(key)
		} label: {
			Text("\(complete ? "✓ " : active ? "● " : attempt != nil ? "! " : "")\(key.number)")
				.font(.system(.caption, design: .monospaced).weight(.medium))
				.padding(.horizontal, 12).padding(.vertical, 8)
				.background(selected ? MeterTheme.selection : MeterTheme.field, in: RoundedRectangle(cornerRadius: 6))
				.overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? MeterTheme.mint : MeterTheme.border))
				.foregroundStyle(color)
		}.buttonStyle(.plain).disabled(model.recording)
	}

	private func recorder(_ session: MeasurementSession) -> some View {
		let attempt = model.viewedAttempt
		return VStack(alignment: .leading, spacing: 18) {
			HStack {
				Text(model.selectedName).font(.headline)
				Spacer()
				if !session.finalized {
					Button("Следующая итерация →") { model.nextIteration() }.disabled(model.recording)
				}
			}
			if !session.finalized {
				HStack(spacing: 14) {
					Button("▶ Старт") { model.start() }
						.buttonStyle(.borderedProminent).foregroundStyle(Color(hex: 0x0d2b20))
						.disabled(!model.canStart).keyboardShortcut(.return, modifiers: [])
					Button("■ Стоп") { model.stop() }.disabled(!model.recording)
					Spacer()
					Text("Автостоп через \(clockText(session.duration))").monospacedDigit()
						.foregroundStyle(MeterTheme.muted)
				}.controlSize(.large).meterCard()
			}
			if let selected = model.selected {
				let attempts = session.attempts.filter { $0.key == selected }
				if attempts.count > 1 {
					HStack {
						Text("Попытки").foregroundStyle(MeterTheme.muted)
						ForEach(attempts) { item in
							Button("\(item.number) · \(item.complete ? "полная" : "неполная")") {
								model.selectedAttemptID = item.id
							}.disabled(model.recording)
						}
					}.font(.caption)
				}
			}
			HStack(spacing: 20) {
				metric(title: model.recording ? "Текущая мощность" : "Последняя мощность",
					   value: attempt?.samples.last?.reading.power,
					   subtitle: model.recording ? "Последний полученный отсчёт" : "Последнее значение · обновление остановлено",
					   highlighted: false)
				metric(title: "Средняя мощность", value: attempt?.mean,
					   subtitle: "По валидным отсчётам выбранной попытки" + (attempt?.complete == false ? " · предварительно" : ""),
					   highlighted: true)
			}
			VStack(spacing: 8) {
				HStack {
					Text("Прошло").foregroundStyle(MeterTheme.muted)
					Spacer()
					Text("\(clockText(attempt?.elapsed ?? 0)) / \(clockText(session.duration))")
						.font(.system(size: 18, weight: .medium, design: .monospaced))
				}
				ProgressView(value: min(attempt?.elapsed ?? 0, session.duration), total: session.duration)
				HStack {
					Text(model.recording ? "● Запись" : attempt?.stopReason ?? "Готово к старту")
					Spacer()
					if model.recording {
						Text("Осталось \(clockText(max(0, session.duration - (attempt?.elapsed ?? 0))))")
					}
				}.font(.caption).foregroundStyle(model.recording ? MeterTheme.mint : MeterTheme.muted)
			}
			if session.finalized { ResultsView(session: session) } else { powerChart(attempt, session: session) }
			HStack {
				Text("\(attempt?.samples.count ?? 0) отсчётов · \(Numeric.text(attempt?.frequency)) Гц · пропусков: \(String(format: "%.0f", attempt?.missingReadings ?? 0)) · \(attempt?.warnings.count ?? 0) предупреждений")
					.font(.caption).foregroundStyle(MeterTheme.muted)
				Spacer()
				if session.finalized {
					Button("Сохранить CSV…") { model.exportResult() }
				}
				Button("Логи итерации…") { model.exportLogs(selectedOnly: true) }
					.disabled(attempt == nil)
				Button("Все логи…") { model.exportLogs() }.disabled(session.attempts.isEmpty)
			}.disabled(model.recording || model.pendingWrites > 0)
			if let attempt, !attempt.warnings.isEmpty {
				DisclosureGroup("Диагностика: пропуски, повреждённые строки, reset") {
					Text(attempt.warnings.joined(separator: "\n"))
						.font(.caption.monospaced()).foregroundStyle(MeterTheme.warning)
						.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
				}
			}
			if !session.finalized {
				HStack {
					Text("«Стоп» завершает попытку без учёта в расчётах. «Завершить замер» формирует итог всей сессии.")
						.font(.caption).foregroundStyle(MeterTheme.muted)
					Spacer()
					Button("Завершить замер") {
						if session.incomplete || model.recording { confirmFinish = true } else { model.finalize() }
					}.controlSize(.large)
				}
			}
		}
	}

	private func metric(title: String, value: Double?, subtitle: String, highlighted: Bool) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title).font(.caption).foregroundStyle(MeterTheme.muted)
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Text(Numeric.text(value)).font(.system(size: 43, weight: .medium, design: .rounded)).monospacedDigit()
				Text("Вт").font(.title3).foregroundStyle(MeterTheme.muted)
			}
			Text(subtitle).font(.caption2).foregroundStyle(MeterTheme.muted)
				.lineLimit(2).frame(height: 28, alignment: .top)
		}.frame(maxWidth: .infinity, alignment: .leading)
			.meterCard(background: highlighted ? MeterTheme.selection : MeterTheme.surface)
	}

	private func powerChart(_ attempt: MeasurementAttempt?, session: MeasurementSession) -> some View {
		VStack(alignment: .leading, spacing: 16) {
			HStack {
				Text("Потребляемая мощность").font(.headline)
				Spacer()
				Text("Шкала 0–15 Вт").font(.caption).foregroundStyle(MeterTheme.muted)
			}
			Chart(attempt?.samples ?? []) { sample in
				AreaMark(x: .value("Время", sample.elapsed), yStart: .value("Ноль", 0), yEnd: .value("Вт", sample.reading.power))
					.foregroundStyle(MeterTheme.mint.opacity(0.10))
				LineMark(x: .value("Время", sample.elapsed), y: .value("Вт", sample.reading.power))
					.foregroundStyle(MeterTheme.mint).lineStyle(StrokeStyle(lineWidth: 2))
				PointMark(x: .value("Время", sample.elapsed), y: .value("Вт", sample.reading.power))
					.foregroundStyle(MeterTheme.mint).symbolSize(9)
			}
			.chartYScale(domain: 0...15)
			.chartXScale(domain: 0...session.duration)
			.chartYAxis {
				AxisMarks(position: .leading, values: [0, 3, 6, 9, 12, 15]) {
					AxisGridLine().foregroundStyle(MeterTheme.border)
					AxisValueLabel()
				}
			}
			.chartXAxis {
				AxisMarks(values: .automatic(desiredCount: 6)) { value in
					AxisGridLine().foregroundStyle(MeterTheme.border)
					AxisValueLabel { if let seconds = value.as(Double.self) { Text(clockText(seconds)) } }
				}
			}
			.chartPlotStyle { $0.clipped() }
			.frame(height: 260)
			HStack {
				Label("Мощность, Вт", systemImage: "waveform.path").foregroundStyle(MeterTheme.mint)
				Spacer()
				Text("Время, мин:сек").foregroundStyle(MeterTheme.muted)
			}.font(.caption)
			if let samples = attempt?.samples, samples.contains(where: { $0.reading.power > 15 }) {
				Text("Есть значения выше 15 Вт: они сохранены и учтены в среднем, но находятся за шкалой графика.")
					.font(.caption).foregroundStyle(MeterTheme.warning)
			}
		}.meterCard()
	}

	private func message(_ text: String, color: Color, icon: String) -> some View {
		Label(text, systemImage: icon).font(.caption)
			.foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading)
			.textSelection(.enabled).meterCard(background: color.opacity(0.08))
	}
}

struct ResultsView: View {
	let session: MeasurementSession
	private let width: CGFloat = 110

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("Результаты замера").font(.title2.weight(.semibold))
			Text("\(session.incomplete ? "Неполный результат" : "Полный результат") · \(session.completedIterations) / \(session.totalIterations) полных итераций")
				.foregroundStyle(session.incomplete ? MeterTheme.warning : MeterTheme.mint)
			ForEach(session.conditions) { condition in
				let count = session.attempts.filter { $0.complete && $0.key.conditionID == condition.id }.count
				Text("\(condition.name): \(count) / \(condition.iterations)")
					.font(.caption).foregroundStyle(MeterTheme.muted)
			}
			if let base = session.conditions.first, session.mean(conditionID: base.id) == nil {
				Label("Нет полной базы: дельты не рассчитаны.", systemImage: "exclamationmark.triangle")
					.foregroundStyle(MeterTheme.warning)
			}
			ScrollView(.horizontal) {
				VStack(spacing: 1) {
					HStack(spacing: 1) {
						cell("Итерация", width: width, leading: true).background(MeterTheme.raised)
						ForEach(Array(session.conditions.enumerated()), id: \.element.id) { index, condition in
							VStack(spacing: 8) {
								Text(condition.name).fontWeight(.semibold).lineLimit(3)
								HStack(spacing: 0) {
									Text("Мощность, Вт").frame(width: width)
									if index > 0 {
										Text("Δ к базе, Вт").frame(width: width)
										Text("Δ к базе, %").frame(width: width)
									}
								}.font(.caption2)
							}.padding(.vertical, 12).frame(width: index == 0 ? width : width * 3 + 2)
								.background(MeterTheme.raised)
						}
					}
					ForEach(MeasurementExport.rows(session)) { row in
						HStack(spacing: 1) {
							cell(row.label, width: width, leading: true)
							ForEach(Array(row.values.enumerated()), id: \.offset) { index, value in
								cell(Numeric.text(value), width: width)
								if index > 0 {
									let base = row.values.first ?? nil
									let delta = Numeric.delta(value, base: base)
									cell(Numeric.text(delta), width: width, color: deltaColor(delta))
									cell(Numeric.text(Numeric.percent(value, base: base)), width: width, color: deltaColor(delta))
								}
							}
						}
						.fontWeight(row.label == "Среднее" ? .semibold : .regular)
						.background(row.label == "Среднее" ? MeterTheme.selection : MeterTheme.field)
					}
				}.background(MeterTheme.border)
			}
			Text("Неполные попытки исключены. «Среднее» — среднее полных итераций каждого условия. Δ строки — к базе той же итерации; итоговая Δ — из средних. «—» означает отсутствие пары; при нулевой базе процент не определён.")
				.font(.caption).foregroundStyle(MeterTheme.muted)
		}.meterCard()
	}

	private func cell(_ text: String, width: CGFloat, leading: Bool = false,
					  color: Color = MeterTheme.ink) -> some View {
		Text(text).font(.system(size: 12)).monospacedDigit().foregroundStyle(color)
			.padding(.horizontal, 10).frame(width: width, height: 40, alignment: leading ? .leading : .trailing)
	}

	private func deltaColor(_ value: Double?) -> Color {
		guard let value else { return MeterTheme.muted }
		return value > 0 ? MeterTheme.warning : value < 0 ? MeterTheme.mint : MeterTheme.ink
	}
}

struct PortSettingsView: View {
	@Bindable var model: MeterModel
	@Environment(\.dismiss) private var dismiss
	@State private var draft = SerialSettings()
	@State private var demo = false

	var body: some View {
		VStack(alignment: .leading, spacing: 18) {
			Text("Настройки считывания порта").font(.title2.weight(.semibold))
			Picker("Источник", selection: $demo) {
				Text("Реальный датчик").tag(false)
				Text("ДЕМО (синтетические данные)").tag(true)
			}
			if model.session?.finalized == false {
				Text("Для продолжения этой сессии требуется источник: \(model.session?.source.rawValue ?? ""). Данные другого источника в неё не записываются.")
					.font(.caption).foregroundStyle(MeterTheme.muted)
			}
			Group {
				HStack {
					Picker("Порт", selection: $draft.port) {
						Text("Авто — первый с корректными данными").tag("")
						ForEach(model.ports, id: \.self) { Text($0).tag($0) }
						if !draft.port.isEmpty && !model.ports.contains(draft.port) {
							Text("\(draft.port) (недоступен)").tag(draft.port)
						}
					}
					Button { model.refreshPorts() } label: { Image(systemName: "arrow.clockwise") }
						.accessibilityLabel("Обновить список портов")
				}
				Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 14) {
					GridRow {
						Picker("Скорость", selection: $draft.baud) {
							ForEach([9600, 19200, 38400, 57600, 115200], id: \.self) { Text("\($0)").tag($0) }
						}
						Picker("Биты данных", selection: $draft.dataBits) {
							Text("7").tag(7)
							Text("8").tag(8)
						}
					}
					GridRow {
						Picker("Чётность", selection: $draft.parity) {
							ForEach(SerialParity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
						}
						Picker("Стоп-биты", selection: $draft.stopBits) {
							Text("1").tag(1)
							Text("2").tag(2)
						}
					}
					GridRow {
						Picker("Конец строки", selection: $draft.ending) {
							ForEach(LineEnding.allCases, id: \.self) { Text($0.rawValue).tag($0) }
						}
						Stepper("Таймаут: \(Int(draft.timeout)) с", value: $draft.timeout, in: 3...30, step: 1)
					}
				}
				Text("Без flow control. Открытие порта может перезапустить Arduino. Подготовка и проверка данных не входят в измеряемое время. При автовыборе каждый порт проверяется до таймаута; ручной порт не подменяется.")
					.font(.caption).foregroundStyle(MeterTheme.muted)
			}.disabled(demo)
			Text(model.connectionStatus).font(.caption).foregroundStyle(MeterTheme.muted)
			ScrollView {
				Text(model.preview.isEmpty ? "Исходные данные появятся после подключения…" : model.preview)
					.font(.system(size: 11, design: .monospaced))
					.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
			}.frame(height: 120).padding(10).background(MeterTheme.field, in: RoundedRectangle(cornerRadius: 6))
			HStack {
				Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
				Spacer()
				Button("Применить и подключиться") {
					model.disconnect()
					model.settings = draft
					model.demo = demo
					model.connect()
					dismiss()
				}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
			}
		}
		.padding(24).frame(width: 620)
		.background(MeterTheme.page).foregroundStyle(MeterTheme.ink)
		.onAppear { draft = model.settings; demo = model.demo; model.refreshPorts() }
	}
}
