// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MagicPowerMeter",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PowerMeterCore", targets: ["PowerMeterCore"])],
    targets: [
        .target(name: "PowerMeterCore", path: "MagicPowerMeter/Core"),
        .testTarget(name: "PowerMeterCoreTests", dependencies: ["PowerMeterCore"], path: "Tests")
    ]
)
