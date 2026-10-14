// swift-tools-version: 6.2
import PackageDescription

// museo kit: everything that talks to the museo ring.
//
// MuseoCore is bluetooth and the ring's protocol (Treaty): connect, stream, sync, decode.
// MuseoKit is what an app uses: setup with iOS's accessory sheet, one status for screens,
// finished recordings handed over safely, ring events, and firmware updates.
//
// Apps import MuseoKit only. It re-exports MuseoCore's public types (RingBLEManager,
// CompletedCapture, RingFile). What could retire a ring copy without a save, or take a
// capture before MuseoKit hands it over, is `package`: only MuseoKit can call it.

let package = Package(
    name: "MuseoKit",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "MuseoKit", targets: ["MuseoKit"]),
    ],
    dependencies: [
        // Firmware updates over MCUboot / SMP.
        .package(url: "https://github.com/NordicSemiconductor/IOS-nRF-Connect-Device-Manager", exact: "1.14.6"),
    ],
    targets: [
        // Compiled exactly as the original ring kit was: Swift 5 mode, no default actor.
        .target(
            name: "MuseoCore",
            path: "Sources/MuseoCore",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // Written for the app's rules: main actor by default, approachable concurrency.
        .target(
            name: "MuseoKit",
            dependencies: [
                "MuseoCore",
                .product(name: "iOSMcuManagerLibrary", package: "IOS-nRF-Connect-Device-Manager"),
            ],
            path: "Sources/MuseoKit",
            resources: [
                .copy("Resources/MuseRing.zip"),
                .process("Resources/Media.xcassets"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
                .enableUpcomingFeature("DisableOutwardActorInference"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
    ]
)
