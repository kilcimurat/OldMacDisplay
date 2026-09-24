// swift-tools-version:5.9
import PackageDescription

// ONE app, both roles.
//
// The whole binary is pinned to macOS 10.15 and built universal (arm64 +
// x86_64) so the same .app runs on the M2 Max and on the 2013 Intel iMac.
//
// That forces three rules on the Host half of the code:
//   1. every modern API sits behind @available(macOS 13, *)
//   2. ScreenCaptureKit is weak-linked — it does not exist on Catalina, and a
//      strong link would stop the app launching there
//   3. no Swift Concurrency anywhere; async/await would drag in
//      libswift_Concurrency.dylib, which Catalina does not ship
//
// Scripts/verify-catalina.sh enforces all three against the built binary.
let package = Package(
    name: "OldMacDisplay",
    platforms: [.macOS(.v10_15)],
    products: [
        .executable(name: "OldMacDisplay", targets: ["OldMacDisplay"])
    ],
    dependencies: [
        .package(path: "../Shared")
    ],
    targets: [
        .target(name: "OMDPrivateDisplay"),
        .executableTarget(
            name: "OldMacDisplay",
            dependencies: [
                .product(name: "OldMacDisplayShared", package: "Shared"),
                "OMDPrivateDisplay"
            ],
            linkerSettings: [
                // Post-Catalina frameworks must be weak so dyld tolerates their
                // absence on the iMac.
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "ScreenCaptureKit"])
            ]
        )
    ]
)
