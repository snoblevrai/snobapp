// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "snobapp",
    platforms: [.macOS(.v13)],
    targets: [
        // Pont C vers le framework privé MultitouchSupport (chargé à l'exécution via dlopen).
        .target(name: "CMultitouch"),
        // Accès SMC (AppleSMC) et limite de charge native (PowerUI.framework, privé).
        .target(
            name: "CSMC",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("Foundation")]
        ),
        .executableTarget(
            name: "snobapp",
            dependencies: ["CMultitouch", "CSMC"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("IOKit"),
                .linkedFramework("FinderSync"),
            ]
        ),
    ]
)
