// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BetterTerminal",
    platforms: [.macOS(.v14)],
    dependencies: [
        // MIT. Pinned to a release tag; bump deliberately.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.0"),
    ],
    targets: [
        // Shell integration, PTY session, splitter, bubble screens. No UI imports.
        .target(name: "BTCore", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "BetterTerminal",
                          dependencies: ["BTCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        // Runs real zsh through Session + Splitter headless and prints what each bubble would show.
        .executableTarget(name: "bt-selftest", dependencies: ["BTCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "BTCoreTests", dependencies: ["BTCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
