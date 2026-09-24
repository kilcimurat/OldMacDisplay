// swift-tools-version:5.9
import PackageDescription

// The Shared module is the lowest common denominator of the project: it is linked
// into BOTH the Host (Apple Silicon, modern macOS) and the Receiver (2013 Intel
// iMac, macOS Catalina 10.15). Its deployment target is therefore pinned to 10.15
// and it must not use any API newer than that without an @available guard.
//
// It is also deliberately free of Swift Concurrency (async/await/actors). Swift
// concurrency back-deploys to 10.15 only by weakly linking and embedding
// libswift_Concurrency.dylib into the app bundle; avoiding it entirely keeps the
// Catalina binary self-contained. Shared uses callbacks + DispatchQueue instead.
let package = Package(
    name: "OldMacDisplayShared",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "OldMacDisplayShared", targets: ["OldMacDisplayShared"])
    ],
    targets: [
        .target(name: "OldMacDisplayShared"),
        .testTarget(name: "OldMacDisplaySharedTests", dependencies: ["OldMacDisplayShared"])
    ]
)
