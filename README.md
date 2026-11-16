# Magic Power Meter

Native macOS 14+ SwiftUI / Swift Charts application for Arduino + INA219 power measurements.
The interface is in Russian, with blue/cyan accents matching the app icon. Open `MagicPowerMeter.xcodeproj`
and run the `MagicPowerMeter` scheme on My Mac.
The theme button in the fixed top header, above the connection block, switches between light and dark appearance
for the whole interface, including port settings and alerts. Each launch starts dark;
the selection is kept only in memory and does not change measurements.

## Measuring

1. Close CoolTerm and other serial clients. Open port settings, select the real sensor
   or the explicitly labelled demo source, and connect.
2. Defaults: 9600 baud, 8N1, no flow control, LF/CRLF, 8-second valid-data timeout.
   The protocol is `count;voltage_V;current_mA;power_W`, with comma or dot decimals.
   Automatic selection probes each port until it receives a valid sensor reading.
   Connecting/preparing may reset Arduino and does not start the measurement.
3. Choose single or comparison mode, configure named conditions, individual iteration
   counts and a shared duration (default 180 seconds), then create a session.
4. Select an iteration, prepare the scenario on the phone manually and press Start.
   The monotonic timer stops at the configured duration. Stop aborts an attempt:
   it remains in raw logs but is excluded from all result calculations. Retry does
   not overwrite earlier attempts. Inspect previous attempts using the attempt buttons.
5. Finish the session to replace the graph with results and generate CSV in memory.
   Early finalization requires confirmation and marks the result incomplete.
   Completed sessions remain available in memory when starting a new session.

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
cells. Each iteration delta uses its corresponding base iteration. The last row averages
complete iteration means separately per condition; deltas are calculated from those means,
not from averaged percentages. A zero base has no percentage. Completeness and source
are repeated in every CSV row, so incomplete/demo results cannot lose their labels.

Raw `.txt` files contain the exact received bytes, not regenerated CSV. Associated JSON
identifies source, condition, iteration, attempt, inclusion in calculations, connection,
timestamps, raw chunk byte offsets and diagnostics. Demo filenames have a `DEMO-` prefix.
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
The appearance smoke test exercises the SwiftUI theme button's binding action and checks contrast.
Pass optional output-folder and built `.app` paths to capture the app's own hosted SwiftUI previews
for both themes (setup, chart, recording, results and port settings), without screen recording.
The preview process loads the compiled app icon from that bundle instead of its command-line executable icon.
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
