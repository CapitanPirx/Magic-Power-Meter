# Magic Power Meter

Native macOS 14+ SwiftUI / Swift Charts application for Arduino + INA219 power measurements.
The interface is in Russian, with blue/cyan accents matching the app icon. Open `MagicPowerMeter.xcodeproj`
and run the `MagicPowerMeter` scheme on My Mac.
The theme button in the fixed top header, above the connection block, switches between light and dark appearance
for the whole interface, including port settings and alerts. Each launch starts dark;
the selection is kept only in memory and does not change measurements.

## Arduino: скетч и подготовка

[Скачать исходный скетч PowerConsumption.ino](docs/arduino/PowerConsumption/PowerConsumption.ino)
для Arduino и датчика INA219, измеряющего напряжение и ток. Скетч передаёт эти
показания и вычисленную мощность приложению через serial; исходник сохранён без изменений.

1. В Arduino IDE через Library Manager установите **Adafruit INA219** и предложенные
   менеджером зависимости. `Wire` входит в стандартный комплект платформы Arduino.
2. Сохраните файл в каталог `PowerConsumption` и откройте `PowerConsumption.ino`
   в Arduino IDE: имя каталога должно совпадать с именем скетча.
   Выберите подходящие плату и порт, затем загрузите скетч.
3. Закройте Serial Monitor и другие serial-клиенты перед подключением приложения.
   В приложении выберите порт и параметры **9600 бод, 8N1, без управления потоком**.
   `Serial.println` отправляет CRLF; настройки окончания строки LF или CRLF подходят.

Точная модель платы не указана. Скетч использует `dtostrf`, привычную для AVR;
её доступность зависит от платформы, поэтому совместимость со всеми Arduino не гарантируется.

Ожидаемый вывод — заголовок и строки `count;voltage_V;current_mA;power_W`:

```text
count;voltage_V;current_mA;power_W
1;5,00;840,00;4,200
```

Напряжение — в В, ток — в мА, мощность — в Вт. Вспомогательная функция скетча
выводит десятичную запятую; приложение принимает и запятую, и точку.
Счётчик должен помещаться в `UInt64`, показания — быть конечными и неотрицательными.
Отрицательные показания не принимаются; скетч их не скрывает и не обнуляет.
В самом скетче счётчик имеет тип `int`: непрерывная работа ограничена его переполнением
на выбранной плате. Переподключение приложения не обязательно сбрасывает счётчик прошивки.

`delay(1000)` даёт примерно один отсчёт в секунду с учётом времени измерения и вывода,
а не гарантированные 180 отсчётов за 180 секунд.
Если `ina219.begin()` не удаётся, скетч выводит `ERROR` и останавливает измерения:
датчик не обнаружен или неисправен. Это не показание; приложение не подтвердит
корректные данные и завершит ожидание по таймауту (по умолчанию 8 секунд).

## Measuring

1. Close CoolTerm and other serial clients. Open port settings, select the real sensor
   or the explicitly labelled demo source, and connect.
2. Defaults: 9600 baud, 8N1, no flow control, LF/CRLF, 8-second valid-data timeout.
   The protocol is `count;voltage_V;current_mA;power_W`, with comma or dot decimals.
   Automatic selection probes each port until it receives a valid sensor reading.
   Connecting/preparing may reset Arduino and does not start the measurement.
3. Choose single, comparison or sprint mode and a shared duration (default 180 seconds).
   Comparison has editable named conditions and individual iteration counts. Sprint is a
   fixed, independent 5×3 template: ВДНХ статика (авторизован), ВДНХ статика (неавторизован),
   ВДНХ динамика (авторизован), ВДНХ динамика (неавторизован), Сочи Дендрарий динамика.
   Create a session; use «Переименовать» beside its title to edit the session name.
   Empty/whitespace-only names are rejected. Names and modes remain in in-memory history;
   renaming does not change session IDs or export filenames.
4. Select an iteration, prepare the scenario on the phone manually and press Start.
   After an iteration completes, Start selects the next unfinished slot in plan order
   and starts it in one press. An explicitly selected unfinished slot takes priority.
   Recording never advances without pressing Start; all slots complete disables Start.
   All elapsed/remaining/planned durations use `m:ss` (for example `0:09`, `3:00`).
   The monotonic timer stops at the configured duration. Stop aborts an attempt:
   it remains in raw logs but is excluded from all result calculations.
   In comparison and sprint modes select a recorded slot and use «Перезамер» to remeasure it.
   The previous full result remains included until a new full attempt succeeds; only then
   does the new attempt replace it in means, progress, tables, graphs and CSV. An aborted,
   timed-out or failed replacement keeps the previous result. All old attempts and exact
   raw bytes remain available using the attempt buttons, with explicit inclusion status.
5. Finish the session to open «Таблица» / «Графики» tabs and generate CSV in memory.
   The graphs tab lets you select every scenario/iteration, including incomplete or
   unrecorded slots (clearly labelled), with the original 0–15 W and session-time scales.
   Early finalization requires confirmation and marks the result incomplete.
   Remeasurement also works after finalization: when the attempt stops, the session returns
   to finalized state and its table, graphs and in-memory CSV refresh. Automatic exports
   use the updated snapshot if a folder is selected. Completed sessions remain available
   in memory when starting a new session. Single mode has no explicit remeasurement action.

The graph always uses 0-15 W; values above the graph range remain in the data and mean.
Malformed lines, count gaps, resets and timing gaps are reported. Empty runs and runs
without sufficient start/end coverage or with gaps exceeding the timeout cannot be
completed. A short gap or malformed line is a warning, not an interpolated or zero sample.
Elapsed times use a continuous monotonic clock (including system sleep); actual wall
timestamps and delayed-stop detection times are recorded separately. Recording disables
idle system sleep. A manual stop received after the deadline honors the completed window.

## Exports and privacy

Choose a folder through the native folder picker. Data remains in memory until a
successful write is confirmed. The raw-log checkbox saves all attempts after stopping;
finalization automatically saves CSV if a folder is selected. Export buttons allow retry.
Nothing is persisted across application restarts unless exported.

CSV uses UTF-8 BOM, semicolons, comma decimals, quoted condition names and blank missing
cells. In comparison mode each iteration delta uses its corresponding base iteration. The last row averages
complete iteration means separately per condition; deltas are calculated from those means,
not from averaged percentages. A zero base has no percentage. Completeness and source
are repeated in every CSV row, so incomplete/demo results cannot lose their labels.
Sprint UI and CSV contain independent scenario means, without a base or delta columns.

Raw `.txt` files contain the exact received bytes, not regenerated CSV. Associated JSON
identifies source, condition, iteration, attempt, inclusion in calculations, connection,
timestamps, raw chunk byte offsets and diagnostics. Demo filenames have a `DEMO-` prefix.
`complete` describes an attempt's coverage; `included_in_calculations` is true only for
the current successful result of its slot, not for superseded full attempts.
The app remains sandboxed with serial-device and user-selected-folder write entitlements;
it has no network capability and no external dependencies.

## Development

```sh
swift test
swiftc -parse-as-library MagicPowerMeter/Core/*.swift MagicPowerMeter/SerialTransport.swift \
  IntegrationTests/DesktopSmoke.swift -o .build/desktop-smoke
.build/desktop-smoke
swiftc -parse-as-library MagicPowerMeter/Core/*.swift MagicPowerMeter/MeterAppearance.swift \
  MagicPowerMeter/ContentView.swift IntegrationTests/AppearanceSmoke.swift -o .build/appearance-smoke
.build/appearance-smoke
xcodebuild -project MagicPowerMeter.xcodeproj -scheme MagicPowerMeter \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGN_IDENTITY=- build
```

Core tests run independently of the UI with Swift Package Manager. A desktop integration
smoke test uses a POSIX pseudoterminal and the explicit demo source (no sensor is opened).
The appearance smoke test exercises the SwiftUI theme button's binding action, checks contrast
and verifies the production duration formatter, including invalid/large inputs.
Pass optional output-folder and built `.app` paths to capture the app's own hosted SwiftUI previews
for both themes (setup, next Start, recording, result tabs, rename, remeasurement, sprint
and port settings), without screen recording.
The preview process loads the compiled app icon from that bundle instead of its command-line executable icon.
Each captured view also checks its own process's unified log for Foundation format-argument mismatches;
these diagnostics are not reliably visible in stderr.
Means stream values without intermediate arrays or cached statistics, retaining the
original incremental calculation order. Raw-log writes reuse a date formatter within
each export, never across concurrent exports. Regression tests pin floating-point results,
iteration inclusion and exact CSV/raw-log metadata bytes.
User-facing Russian text lives in `MagicPowerMeter/Core/Strings.swift`: typed constants
and parameterized functions, not localization keys. Protocol markers, JSON keys, paths
and SF Symbol identifiers stay with their owning code. Test expectations remain independent
literal values. SwiftPM and the synchronized Xcode source group include the file automatically.
`Core/MeterModel.swift` owns measurement flow and observable presentation state, depending
on `SensorTransport` and `MeasurementExporting` rather than serial or file implementations.
`SerialTransport` owns POSIX/IOKit work; `FileMeasurementExporter` serializes immutable
session/folder requests and propagates original errors. `ExportFolder` owns selection
and security-scoped access. `MyApp.swift` composes the production services and native
folder picker. The core has no AppKit/SwiftUI dependency; model tests use fake services
to exercise connection generations, pending exports, snapshots, retries and cancellation.
Hardware validation
requires the actual Arduino/INA219 device; demo validation does not establish hardware
compatibility. Automatic iPhone scenarios, XCUITest and CI orchestration are outside this MVP.
