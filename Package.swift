// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DockBar",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "DockBar", targets: ["DockBar"])
    ],
    targets: [
        .executableTarget(
            name: "DockBar",
            path: "Sources/DockBar"
        ),
        .testTarget(
            name: "DockBarTests",
            dependencies: ["DockBar"],
            path: "Tests/DockBarTests",
            swiftSettings: [
                .unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ])
            ]
        )
    ]
)
