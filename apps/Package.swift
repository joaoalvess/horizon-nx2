// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Horizon",
    platforms: [.macOS(.v15), .tvOS(.v18)],
    products: [
        .library(name: "HorizonLink", targets: ["HorizonLink"]),
        .library(name: "HorizonPlayer", targets: ["HorizonPlayer"]),
        .library(name: "HubKit", targets: ["HubKit"]),
        .executable(name: "horizon-receiver", targets: ["horizon-receiver"]),
        .executable(name: "horizon-fakestream", targets: ["horizon-fakestream"]),
    ],
    targets: [
        .target(name: "HorizonLink"),
        .target(name: "HorizonPlayer", dependencies: ["HorizonLink"]),
        .target(name: "HubKit", dependencies: ["HorizonLink"]),
        .executableTarget(name: "horizon-receiver", dependencies: ["HorizonLink", "HorizonPlayer"]),
        .executableTarget(name: "horizon-fakestream", dependencies: ["HorizonLink"]),
        .testTarget(name: "HorizonLinkTests", dependencies: ["HorizonLink"]),
        .testTarget(name: "HorizonPlayerTests", dependencies: ["HorizonPlayer", "HorizonLink"]),
        .testTarget(name: "HubKitTests", dependencies: ["HubKit"]),
    ]
)
