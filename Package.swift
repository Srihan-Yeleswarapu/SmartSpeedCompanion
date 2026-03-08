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
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "10.0.0")
    ],
    targets: [
        .target(
            name: "SmartSpeedCompanion",
            dependencies: [
                .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseDatabase", package: "firebase-ios-sdk")
            ],
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
