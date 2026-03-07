// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SmartSpeedCompanion",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "SmartSpeedCompanion", targets: ["SmartSpeedCompanion"]),
    ],
    dependencies: [
        // Add dependencies here if needed, e.g. .package(url: "...", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "SmartSpeedCompanion",
            path: "SmartSpeedCompanion",
            exclude: ["Info.plist", "Resources/Entitlements/SmartSpeedCompanion.entitlements"]
        ),
        .testTarget(
            name: "SmartSpeedCompanionTests",
            dependencies: ["SmartSpeedCompanion"],
            path: "SmartSpeedCompanionTests"
        ),
    ]
)
