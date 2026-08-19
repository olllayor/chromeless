// swift-tools-version:6.0
// Chromeless builds its .app via build.sh (plain swiftc, whole-module). This
// manifest exists so the deterministic core can be exercised by `swift test`
// and CI without touching that flow. It compiles the same sources in place as
// a library (everything except main.swift and tools/) plus a test target.
import PackageDescription

let package = Package(
    name: "Chromeless",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "ChromelessCore",
            path: ".",
            // main.swift (top-level boot) and tools/ are app-build-only; the
            // `sources` list already scopes the target to library code.
            sources: ["App", "Autofill", "Browser", "Core", "Data", "Security", "Settings"],
            swiftSettings: [
                // The app is built in Swift 5 mode by build.sh; keep the
                // library consistent so strict-concurrency doesn't reject the
                // existing singletons / mutable statics.
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("WebKit"),
                .linkedFramework("CoreLocation"),
            ]
        ),
        .testTarget(
            name: "ChromelessTests",
            dependencies: ["ChromelessCore"],
            path: "Tests/ChromelessTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
