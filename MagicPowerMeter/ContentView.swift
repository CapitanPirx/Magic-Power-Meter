import AppKit
import SwiftUI
import Charts

func clockText(_ value: TimeInterval) -> String {
	guard value.isFinite else { return Strings.Common.unavailable }
	let total = max(0, value.rounded(.towardZero))
	let minutes = (total / 60).rounded(.down)
	guard minutes < Double(Int.max) else { return Strings.Common.unavailable }
	let seconds = Int(total.truncatingRemainder(dividingBy: 60))
	return "\(Int(minutes)):\(seconds < 10 ? "0" : "")\(seconds)"
}

enum ResultsTab {
	case table, charts
}

struct ContentView: View {
	@Bindable var model: MeterModel
	@Binding var colorScheme: ColorScheme
	@Environment(\.meterPalette) private var palette
	@State private var showSettings = false
	@State private var showEasterEgg = false
	@State private var confirmFinish = false
	@State var resultsTab: ResultsTab = .table

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Spacer()
				ThemeToggle(colorScheme: $colorScheme)
			}
			.padding(.horizontal, 28).padding(.top, 16)
			.frame(maxWidth: 1180).frame(maxWidth: .infinity)
			page
		}
		.background(palette.page)
		.foregroundStyle(palette.ink)
		.tint(palette.accent)
		.frame(minWidth: 920, minHeight: 760)
		.sheet(isPresented: $showSettings) {
			PortSettingsView(model: model).meterAppearance(colorScheme)
		}
		.alert(Strings.UI.finishEarly, isPresented: $confirmFinish) {
			Button(Strings.UI.continueMeasuring, role: .cancel) {}
			Button(Strings.UI.finishIncomplete, role: .destructive) { model.finalize() }
		} message: {
			Text(Strings.UI.finishWarning)
		}
	}

	private var page: some View {
		@Bindable var model = model
		return ScrollView {
			VStack(alignment: .leading, spacing: 22) {
				connection
				storage
				HStack {
					Picker(Strings.UI.mode, selection: $model.mode) {
						ForEach(MeasurementMode.allCases, id: \.self) { mode in
							Text(Strings.UI.modeTitle(mode)).tag(mode)
						}
					}
					.pickerStyle(.segmented)
					.frame(width: 470)
					.disabled(model.session != nil)
					Spacer()
					if model.demo || model.session?.source == .demo {
						Label(Strings.UI.demoBadge, systemImage: "testtube.2")
							.font(.caption.bold()).foregroundStyle(palette.warning)
					}
				}
				if let error = model.error {
					message(error, color: palette.error, icon: "exclamationmark.triangle")
				}
				if let notice = model.notice {
					message(notice, color: palette.muted, icon: "info.circle")
				}
				if !model.history.isEmpty {
					HStack {
						Text(Strings.UI.history).foregroundStyle(palette.muted)
						Menu(Strings.UI.chooseMeasurement) {
							ForEach(model.history, id: \.id) { session in
								Button(Strings.UI.namedHistory(name: session.name, mode: session.mode, details:
									Strings.UI.history(date: session.createdAt, source: session.source, completed: session.completedIterations, total: session.totalIterations))) {
									model.showHistory(session.id)
								}
							}
						}.disabled(model.recording)
					}
				}
				if let session = model.session {
					if session.source != (model.demo ? .demo : .serial) {
						message(Strings.UI.wrongSource(session.source), color: palette.warning, icon: "exclamationmark.triangle")
					}
					sessionPlan(session)
					recorder(session)
				} else {
					setup
				}
				Text(Strings.UI.footer)
					.font(.caption).foregroundStyle(palette.muted)
			}
			.padding(28)
			.frame(maxWidth: 1180)
			.frame(maxWidth: .infinity)
		}
	}

	private var connection: some View {
		HStack(spacing: 14) {
			Image(nsImage: NSApplication.shared.applicationIconImage)
				.renderingMode(.original).resizable().scaledToFit()
				.frame(width: 88, height: 88)
				.contentShape(Rectangle())
				.onTapGesture(count: 3) { showEasterEgg = true }
				.accessibilityHidden(true)
				.alert(Strings.UI.easterEggTitle, isPresented: $showEasterEgg) {
					Button(Strings.UI.ok, role: .cancel) {}
				} message: {
					Text(Strings.UI.easterEggMessage)
				}
			VStack(alignment: .leading, spacing: 5) {
				Text(Strings.UI.currentPort).font(.caption).foregroundStyle(palette.muted)
				Text(model.connectedPort).font(.system(.body, design: .monospaced)).textSelection(.enabled)
				Text(model.connectionStatus).font(.caption).foregroundStyle(palette.muted)
					.fixedSize(horizontal: false, vertical: true)
			}
			Spacer(minLength: 10)
			VStack(alignment: .trailing, spacing: 6) {
				Label(model.connected ? Strings.UI.ready : model.preparing ? Strings.UI.preparing : Strings.Connection.notConnected,
					  systemImage: "circle.fill")
					.font(.caption).foregroundStyle(model.connected ? palette.accent : palette.warning)
				Text(model.demo ? Strings.UI.demoFrequency : model.settings.summary)
					.font(.caption2).foregroundStyle(palette.muted)
				HStack {
					Button(Strings.UI.portSettings) { showSettings = true }
					if model.connected || model.preparing {
						Button(Strings.UI.disconnect) { model.disconnect() }
					} else {
						Button(Strings.UI.connect) { model.connect() }
					}
				}.disabled(model.recording)
			}
		}
	}

	private var storage: some View {
		@Bindable var model = model
		return HStack(spacing: 14) {
			Toggle(Strings.UI.saveRaw, isOn: $model.saveRaw)
				.toggleStyle(.checkbox)
			VStack(alignment: .leading, spacing: 3) {
				Text(model.folder?.path ?? Strings.UI.noFolder)
					.lineLimit(2).textSelection(.enabled)
				if model.pendingWrites > 0 { Text(Strings.UI.saving).foregroundStyle(palette.warning) }
			}.font(.caption).foregroundStyle(palette.muted)
			Spacer()
			Button(Strings.UI.chooseFolder) { model.chooseFolder() }
				.disabled(model.recording || model.pendingWrites > 0)
		}.meterCard()
	}

	private var setup: some View {
		@Bindable var model = model
		return VStack(alignment: .leading, spacing: 16) {
			Text(model.mode == .comparison ? Strings.UI.comparisonSetup : model.mode.title)
				.font(.title2.weight(.semibold))
			Text(model.mode == .sprint ? Strings.UI.sprintHelp : model.mode == .comparison ? Strings.UI.comparisonHelp
				 : Strings.UI.singleHelp)
				.foregroundStyle(palette.muted)
			VStack(alignment: .leading, spacing: 18) {
				if model.mode == .comparison {
					ForEach(Array(model.conditions.enumerated()), id: \.element.id) { index, condition in
						HStack(spacing: 12) {
							Text(index == 0 ? Strings.Common.base : Strings.Common.condition(index))
								.font(.caption).foregroundStyle(palette.muted).frame(width: 85, alignment: .leading)
							TextField(Strings.UI.conditionName, text: $model.conditions[index].name)
							Stepper(value: $model.conditions[index].iterations, in: 1...50) {
								Text(Strings.UI.iterations(model.conditions[index].iterations)).monospacedDigit().frame(width: 55)
							}.frame(width: 105)
							Button(role: .destructive) { model.conditions.removeAll { $0.id == condition.id } } label: {
								Image(systemName: "minus.circle")
							}.disabled(index == 0 || model.conditions.count <= 2).buttonStyle(.borderless)
						}
					}
					Button(Strings.UI.addCondition) {
						model.conditions.append(Condition(name: Strings.Common.condition(model.conditions.count), iterations: 3))
					}.disabled(model.conditions.count >= 12)
					Divider()
				} else if model.mode == .sprint {
					ForEach($model.sprintConditions) { $condition in
						HStack {
							TextField(Strings.UI.locationName, text: $condition.name)
								.textFieldStyle(.roundedBorder)
							Stepper(value: $condition.iterations, in: 1...50) {
								Text(Strings.UI.iterations(condition.iterations)).monospacedDigit().frame(width: 55)
							}.frame(width: 105)
							Button(role: .destructive) {
								let id = condition.id
								model.sprintConditions.removeAll { $0.id == id }
							} label: {
								Image(systemName: "minus.circle")
							}
							.disabled(model.sprintConditions.count <= 1)
							.buttonStyle(.borderless)
							.accessibilityLabel(Strings.UI.removeLocation)
						}
					}
					Button(Strings.UI.addLocation) {
						model.sprintConditions.append(Condition(name: Strings.UI.newLocation, iterations: 3))
					}
					Divider()
				}
				HStack {
					VStack(alignment: .leading, spacing: 5) {
						Text(Strings.UI.iterationDuration).fontWeight(.medium)
						Text(Strings.UI.sharedDuration)
							.font(.caption).foregroundStyle(palette.muted)
					}
					Spacer()
					durationFields
				}
				HStack {
					let total = model.plannedConditions.reduce(0) { $0 + $1.iterations }
					Text(Strings.UI.plannedTime(iterations: total, time: clockText(Double(total) * model.duration)))
						.font(.caption).foregroundStyle(palette.muted)
					Spacer()
					Button(Strings.UI.createSession) { model.createSession() }
						.buttonStyle(MeterPrimaryButtonStyle())
				}
			}.meterCard()
			Text(Strings.UI.manualScenarios)
				.font(.caption).foregroundStyle(palette.muted)
		}
	}

	private var durationFields: some View {
		@Bindable var model = model
		return HStack(spacing: 8) {
			TextField(Strings.UI.minutesPlaceholder, value: $model.minutes, format: .number.grouping(.never))
				.frame(width: 58).accessibilityLabel(Strings.UI.minutesAccessibility)
			Text(Strings.UI.minutesUnit)
			TextField(Strings.UI.secondsPlaceholder, value: $model.seconds, format: .number.grouping(.never))
				.frame(width: 48).accessibilityLabel(Strings.UI.secondsAccessibility)
			Text(Strings.UI.secondsUnit)
		}.textFieldStyle(.roundedBorder)
	}

	private func sessionPlan(_ session: MeasurementSession) -> some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack {
				VStack(alignment: .leading, spacing: 5) {
					SessionNameView(model: model)
					Text(session.mode.title).font(.caption).foregroundStyle(palette.muted)
					Text(Strings.UI.sessionHelp)
						.font(.caption).foregroundStyle(palette.muted)
				}
				Spacer()
				if session.finalized {
					Text(session.incomplete ? Strings.Common.incompleteResult : Strings.UI.finished)
						.foregroundStyle(session.incomplete ? palette.warning : palette.accent)
					Button(Strings.UI.newMeasurement) { model.newSession() }
				}
			}
			VStack(alignment: .leading, spacing: 14) {
				HStack {
					Text(Strings.UI.progress)
					Spacer()
					Text(Strings.UI.progress(completed: session.completedIterations, total: session.totalIterations)).monospacedDigit()
				}.font(.caption)
				ProgressView(value: Double(session.completedIterations), total: Double(max(1, session.totalIterations)))
					.progressViewStyle(MeterProgressStyle())
				ForEach(Array(session.conditions.enumerated()), id: \.element.id) { index, condition in
					HStack(alignment: .top) {
						VStack(alignment: .leading, spacing: 4) {
							Text(condition.name).fontWeight(.medium)
							if session.mode == .comparison {
								Text(index == 0 ? Strings.UI.baseCondition : Strings.UI.comparisonToBase)
									.font(.caption2).foregroundStyle(palette.muted)
							}
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
			}.meterCard()
		}
	}

	private func iterationButton(_ key: IterationKey, session: MeasurementSession) -> some View {
		let attempt = session.latest(key)
		let complete = session.completed(key) != nil
		let active = session.active?.key == key
		let selected = model.selected == key
		let color = complete ? palette.accent : attempt != nil ? palette.warning : palette.muted
		return Button {
			model.select(key)
		} label: {
			Text(Strings.UI.iteration(number: key.number, complete: complete && !active, active: active, attempted: attempt != nil))
				.font(.system(.caption, design: .monospaced).weight(.medium))
				.padding(.horizontal, 12).padding(.vertical, 8)
				.background(selected ? palette.selection : palette.field, in: RoundedRectangle(cornerRadius: 6))
				.overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? palette.accent : palette.border))
				.foregroundStyle(color)
		}.buttonStyle(.plain).disabled(model.recording)
	}

	private func recorder(_ session: MeasurementSession) -> some View {
		let attempt = model.viewedAttempt
		return VStack(alignment: .leading, spacing: 18) {
			HStack {
				Text(model.selectedName).font(.headline)
				Spacer()
				if session.mode != .single, let selected = model.selected, session.latest(selected) != nil {
					Button(Strings.UI.remeasure) { model.retry() }
						.disabled(!model.canRetry).help(Strings.UI.retryHelp)
				}
				if !session.finalized {
					Button(Strings.UI.nextIteration) { model.nextIteration() }.disabled(model.recording)
				}
			}
			if !session.finalized {
				if let target = model.startTarget, target != model.selected {
					Text(Strings.UI.startTarget(condition: session.conditions.first { $0.id == target.conditionID }?.name ?? "",
											   number: target.number))
						.font(.caption).foregroundStyle(palette.accent)
				}
				HStack(spacing: 14) {
					Button(Strings.UI.start) { model.start() }
						.buttonStyle(MeterPrimaryButtonStyle())
						.disabled(!model.canStart).keyboardShortcut(.return, modifiers: [])
					Button(Strings.UI.stop) { model.stop() }.disabled(!model.recording)
					Spacer()
					Text(Strings.UI.autoStop(clockText(session.duration))).monospacedDigit()
						.foregroundStyle(palette.muted)
				}.controlSize(.large).meterCard()
			}
			if let selected = model.selected {
				let attempts = session.attempts.filter { $0.key == selected }
				if attempts.count > 1 {
					HStack {
						Text(Strings.UI.attempts).foregroundStyle(palette.muted)
						ForEach(attempts) { item in
							Button(Strings.UI.attempt(number: item.number, complete: item.complete)) {
								model.selectedAttemptID = item.id
							}.disabled(model.recording)
						}
					}.font(.caption)
				}
			}
			if let attempt, !model.recording {
				Text(attempt.includedInCalculations ? Strings.UI.includedAttempt
					 : attempt.complete ? Strings.UI.supersededAttempt : Strings.UI.excludedAttempt)
					.font(.caption).foregroundStyle(attempt.includedInCalculations ? palette.muted : palette.warning)
			}
			HStack(spacing: 20) {
				metric(title: model.recording ? Strings.UI.currentPower : Strings.UI.lastPower,
					   value: attempt?.samples.last?.reading.power,
					   subtitle: model.recording ? Strings.UI.lastSample : Strings.UI.stoppedSample,
					   highlighted: false)
				metric(title: Strings.UI.meanPower, value: attempt?.mean,
					   subtitle: Strings.UI.meanHelp(preliminary: attempt?.complete == false),
					   highlighted: true)
			}
			VStack(spacing: 8) {
				HStack {
					Text(Strings.UI.elapsed).foregroundStyle(palette.muted)
					Spacer()
					Text(Strings.UI.elapsedTime(clockText(attempt?.elapsed ?? 0), target: clockText(session.duration)))
						.font(.system(size: 18, weight: .medium, design: .monospaced))
				}
				ProgressView(value: min(attempt?.elapsed ?? 0, session.duration), total: session.duration)
					.progressViewStyle(MeterProgressStyle())
				HStack {
					Text(model.recording ? Strings.UI.recording : attempt?.stopReason ?? Strings.UI.readyToStart)
					Spacer()
					if model.recording {
						Text(Strings.UI.remaining(clockText(max(0, session.duration - (attempt?.elapsed ?? 0)))))
					}
				}.font(.caption).foregroundStyle(model.recording ? palette.accent : palette.muted)
			}
			if session.finalized {
				Picker(Strings.UI.resultView, selection: $resultsTab) {
					Text(Strings.UI.tableTab).tag(ResultsTab.table)
					Text(Strings.UI.chartsTab).tag(ResultsTab.charts)
				}.pickerStyle(.segmented).frame(width: 300)
				if resultsTab == .table {
					ResultsView(session: session)
				} else {
					Picker(Strings.Common.iteration, selection: Binding(get: { model.selected }, set: { key in
						if let key { model.select(key) }
					})) {
						ForEach(session.iterationKeys, id: \.self) { key in
							Text(Strings.Model.selectedIteration(condition: session.conditions.first { $0.id == key.conditionID }?.name ?? "",
																number: key.number)).tag(Optional(key))
						}
					}
					if attempt == nil { Text(Strings.UI.noAttempt).foregroundStyle(palette.muted) }
					powerChart(attempt, session: session)
				}
			} else {
				powerChart(attempt, session: session)
			}
			HStack {
				Text(Strings.UI.diagnostics(samples: attempt?.samples.count ?? 0, frequency: Numeric.text(attempt?.frequency),
										   missing: String(format: "%.0f", attempt?.missingReadings ?? 0.0), warnings: attempt?.warnings.count ?? 0))
					.font(.caption).foregroundStyle(palette.muted)
				Spacer()
				if session.finalized {
					Button(Strings.UI.saveCSV) { model.exportResult() }
				}
				Button(Strings.UI.iterationLogs) { model.exportLogs(selectedOnly: true) }
					.disabled(attempt == nil)
				Button(Strings.UI.allLogs) { model.exportLogs() }.disabled(session.attempts.isEmpty)
			}.disabled(model.recording || model.pendingWrites > 0)
			if let attempt, !attempt.warnings.isEmpty {
				DisclosureGroup(Strings.UI.diagnostics) {
					Text(attempt.warnings.joined(separator: "\n"))
						.font(.caption.monospaced()).foregroundStyle(palette.warning)
						.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
				}
			}
			if !session.finalized {
				HStack {
					Text(Strings.UI.stopHelp)
						.font(.caption).foregroundStyle(palette.muted)
					Spacer()
					Button(Strings.UI.finish) {
						if session.incomplete || model.recording { confirmFinish = true } else { model.finalize() }
					}.controlSize(.large)
				}
			}
		}
	}

	private func metric(title: String, value: Double?, subtitle: String, highlighted: Bool) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title).font(.caption).foregroundStyle(palette.muted)
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Text(Numeric.text(value)).font(.system(size: 43, weight: .medium, design: .rounded)).monospacedDigit()
				Text(Strings.Common.watts).font(.title3).foregroundStyle(palette.muted)
			}
			Text(subtitle).font(.caption2).foregroundStyle(palette.muted)
				.lineLimit(2).frame(height: 28, alignment: .top)
		}.frame(maxWidth: .infinity, alignment: .leading)
			.meterCard(background: highlighted ? palette.selection : palette.surface)
	}

	private func powerChart(_ attempt: MeasurementAttempt?, session: MeasurementSession) -> some View {
		VStack(alignment: .leading, spacing: 16) {
			HStack {
				Text(Strings.UI.powerChart).font(.headline)
				Spacer()
				Text(Strings.UI.chartRange).font(.caption).foregroundStyle(palette.muted)
			}
			Chart(attempt?.samples ?? []) { sample in
				AreaMark(x: .value(Strings.UI.timeAxis, sample.elapsed), yStart: .value(Strings.UI.zeroAxis, 0), yEnd: .value(Strings.Common.watts, sample.reading.power))
					.foregroundStyle(palette.accent.opacity(0.10))
				LineMark(x: .value(Strings.UI.timeAxis, sample.elapsed), y: .value(Strings.Common.watts, sample.reading.power))
					.foregroundStyle(palette.accent).lineStyle(StrokeStyle(lineWidth: 2))
				PointMark(x: .value(Strings.UI.timeAxis, sample.elapsed), y: .value(Strings.Common.watts, sample.reading.power))
					.foregroundStyle(palette.accent).symbolSize(9)
			}
			.chartYScale(domain: 0...15)
			.chartXScale(domain: 0...session.duration)
			.chartYAxis {
				AxisMarks(position: .leading, values: [0, 3, 6, 9, 12, 15]) {
					AxisGridLine().foregroundStyle(palette.border)
					AxisValueLabel().foregroundStyle(palette.muted)
				}
			}
			.chartXAxis {
				AxisMarks(values: .automatic(desiredCount: 6)) { value in
					AxisGridLine().foregroundStyle(palette.border)
					AxisValueLabel { if let seconds = value.as(Double.self) { Text(clockText(seconds)) } }
						.foregroundStyle(palette.muted)
				}
			}
			.chartPlotStyle { $0.clipped() }
			.frame(height: 260)
			HStack {
				Label(Strings.Common.powerWatts, systemImage: "waveform.path").foregroundStyle(palette.accent)
				Spacer()
				Text(Strings.UI.timeLegend).foregroundStyle(palette.muted)
			}.font(.caption)
			if let samples = attempt?.samples, samples.contains(where: { $0.reading.power > 15 }) {
				Text(Strings.UI.aboveChart)
					.font(.caption).foregroundStyle(palette.warning)
			}
		}.meterCard()
	}

	private func message(_ text: String, color: Color, icon: String) -> some View {
		Label(text, systemImage: icon).font(.caption)
			.foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading)
			.textSelection(.enabled).meterCard(background: color.opacity(0.08))
	}
}

struct SessionNameView: View {
	@Bindable var model: MeterModel
	@Environment(\.meterPalette) private var palette
	@State var editing = false
	@State private var draft = ""

	var body: some View {
		HStack {
			if editing {
				TextField(Strings.UI.measurementName, text: $draft)
					.textFieldStyle(.roundedBorder)
					.onSubmit { save() }
				Button(Strings.UI.saveName) { save() }
				Button(Strings.UI.cancel) { editing = false }
			} else {
				Text(model.session?.name ?? "").font(.title2.weight(.semibold))
				Button(Strings.UI.renameMeasurement) {
					draft = model.session?.name ?? ""
					editing = true
				}
			}
		}
		.foregroundStyle(palette.ink)
		.disabled(model.recording)
		.onAppear { draft = model.session?.name ?? "" }
	}

	private func save() {
		if model.renameSession(draft) { editing = false }
	}
}

struct ResultsView: View {
	let session: MeasurementSession
	@Environment(\.meterPalette) private var palette
	private var width: CGFloat { session.mode == .sprint ? 160 : 110 }

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(Strings.UI.results).font(.title2.weight(.semibold))
			Text(Strings.UI.results(incomplete: session.incomplete, completed: session.completedIterations, total: session.totalIterations))
				.foregroundStyle(session.incomplete ? palette.warning : palette.accent)
			ForEach(session.conditions) { condition in
				let count = session.includedAttempts.filter { $0.key.conditionID == condition.id }.count
				Text(Strings.UI.conditionProgress(name: condition.name, completed: count, total: condition.iterations))
					.font(.caption).foregroundStyle(palette.muted)
			}
			if session.mode == .comparison, let base = session.conditions.first, session.mean(conditionID: base.id) == nil {
				Label(Strings.UI.noBase, systemImage: "exclamationmark.triangle")
					.foregroundStyle(palette.warning)
			}
			ScrollView(.horizontal) {
				VStack(spacing: 1) {
					HStack(spacing: 1) {
						cell(Strings.Common.iteration, width: width, leading: true).background(palette.raised)
						ForEach(Array(session.conditions.enumerated()), id: \.element.id) { index, condition in
							VStack(spacing: 8) {
								Text(condition.name).fontWeight(.semibold).lineLimit(3)
								HStack(spacing: 0) {
									Text(Strings.Common.powerWatts).frame(width: width)
									if session.mode == .comparison && index > 0 {
										Text(Strings.Common.deltaWatts).frame(width: width)
										Text(Strings.Common.deltaPercent).frame(width: width)
									}
								}.font(.caption2)
							}.padding(.vertical, 12).frame(width: session.mode != .comparison || index == 0 ? width : width * 3 + 2)
								.background(palette.raised)
						}
					}
					ForEach(MeasurementExport.rows(session)) { row in
						HStack(spacing: 1) {
							cell(row.label, width: width, leading: true)
							ForEach(Array(row.values.enumerated()), id: \.offset) { index, value in
								cell(Numeric.text(value), width: width)
								if session.mode == .comparison && index > 0 {
									let base = row.values.first ?? nil
									let delta = Numeric.delta(value, base: base)
									cell(Numeric.text(delta), width: width, color: deltaColor(delta))
									cell(Numeric.text(Numeric.percent(value, base: base)), width: width, color: deltaColor(delta))
								}
							}
						}
						.fontWeight(row.label == Strings.Common.mean ? .semibold : .regular)
						.background(row.label == Strings.Common.mean ? palette.selection : palette.field)
					}
				}.background(palette.border)
			}
			Text(session.mode == .comparison ? Strings.UI.resultsHelp : Strings.UI.independentResultsHelp)
				.font(.caption).foregroundStyle(palette.muted)
		}.meterCard()
	}

	private func cell(_ text: String, width: CGFloat, leading: Bool = false,
					  color: Color? = nil) -> some View {
		Text(text).font(.system(size: 12)).monospacedDigit().foregroundStyle(color ?? palette.ink)
			.padding(.horizontal, 10).frame(width: width, height: 40, alignment: leading ? .leading : .trailing)
	}

	private func deltaColor(_ value: Double?) -> Color {
		guard let value else { return palette.muted }
		return value > 0 ? palette.warning : value < 0 ? palette.accent : palette.ink
	}
}

struct PortSettingsView: View {
	@Bindable var model: MeterModel
	@Environment(\.meterPalette) private var palette
	@Environment(\.dismiss) private var dismiss
	@State private var draft = SerialSettings()
	@State private var demo = false

	var body: some View {
		VStack(alignment: .leading, spacing: 18) {
			Text(Strings.UI.serialSettings).font(.title2.weight(.semibold))
			Picker(Strings.Common.source, selection: $demo) {
				Text(Strings.UI.realSensor).tag(false)
				Text(Strings.UI.demoOption).tag(true)
			}
			if model.session?.finalized == false {
				Text(Strings.UI.requiredSource(model.session?.source))
					.font(.caption).foregroundStyle(palette.muted)
			}
			Group {
				HStack {
					Picker(Strings.UI.port, selection: $draft.port) {
						Text(Strings.UI.automaticPort).tag("")
						ForEach(model.ports, id: \.self) { Text($0).tag($0) }
						if !draft.port.isEmpty && !model.ports.contains(draft.port) {
							Text(Strings.UI.unavailablePort(draft.port)).tag(draft.port)
						}
					}
					Button { model.refreshPorts() } label: { Image(systemName: "arrow.clockwise") }
						.accessibilityLabel(Strings.UI.refreshPorts)
				}
				Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 14) {
					GridRow {
						Picker(Strings.UI.baud, selection: $draft.baud) {
							ForEach([9600, 19200, 38400, 57600, 115200], id: \.self) { Text("\($0)").tag($0) }
						}
						Picker(Strings.UI.dataBits, selection: $draft.dataBits) {
							Text(String(7)).tag(7)
							Text(String(8)).tag(8)
						}
					}
					GridRow {
						Picker(Strings.UI.parity, selection: $draft.parity) {
							ForEach(SerialParity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
						}
						Picker(Strings.UI.stopBits, selection: $draft.stopBits) {
							Text(String(1)).tag(1)
							Text(String(2)).tag(2)
						}
					}
					GridRow {
						Picker(Strings.UI.lineEnding, selection: $draft.ending) {
							ForEach(LineEnding.allCases, id: \.self) { Text($0.rawValue).tag($0) }
						}
						Stepper(Strings.UI.timeout(Int(draft.timeout)), value: $draft.timeout, in: 3...30, step: 1)
					}
				}
				Text(Strings.UI.serialHelp)
					.font(.caption).foregroundStyle(palette.muted)
			}.disabled(demo)
			VStack(alignment: .leading, spacing: 6) {
				Text(Strings.UI.arduinoSketchHelp)
					.font(.caption).foregroundStyle(palette.muted)
					.fixedSize(horizontal: false, vertical: true)
				Link(Strings.UI.arduinoDocumentation, destination: Documentation.arduino)
					.foregroundStyle(palette.accent)
			}
			Text(model.connectionStatus).font(.caption).foregroundStyle(palette.muted)
			ScrollView {
				Text(model.preview.isEmpty ? Strings.UI.preview : model.preview)
					.font(.system(size: 11, design: .monospaced))
					.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
			}.frame(height: 120).padding(10).background(palette.field, in: RoundedRectangle(cornerRadius: 6))
			HStack {
				Button(Strings.UI.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
				Spacer()
				Button(Strings.UI.applyConnection) {
					model.disconnect()
					model.settings = draft
					model.demo = demo
					model.connect()
					dismiss()
				}.buttonStyle(MeterPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
			}
		}
		.padding(24).frame(width: 620)
		.background(palette.page).foregroundStyle(palette.ink)
		.onAppear { draft = model.settings; demo = model.demo; model.refreshPorts() }
	}
}
