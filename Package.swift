// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiscoBreak",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DiscoBreak",
            path: "Sources/DiscoBreak",
            // Everything in this app lives on the main thread by construction
            // (AppKit windows + Core Animation). Swift 5 language mode keeps the
            // concurrency checker from demanding actor annotations on every call.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
