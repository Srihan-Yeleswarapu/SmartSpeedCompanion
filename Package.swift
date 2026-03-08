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
        // Firebase is managed via project.yml / XcodeGen for the iOS app target.
        // Do not add SPM dependencies here — this manifest is not used for the app build.
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
