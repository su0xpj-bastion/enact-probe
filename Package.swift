// swift-tools-version:5.4
import PackageDescription

let package = Package(
    name: "enact-probe",
    platforms: [.macOS(.v11), .iOS(.v14)],
    products: [.library(name: "EnactProbe", targets: ["EnactProbe"])],
    targets: [
        .target(name: "EnactProbe"),
        .target(name: "EnactServer", dependencies: ["EnactProbe"]),
        .executableTarget(name: "enactd", dependencies: ["EnactServer"]),
        .executableTarget(name: "probe", dependencies: ["EnactProbe"]),
        .testTarget(name: "EnactProbeTests", dependencies: ["EnactProbe", "EnactServer"]),
    ]
)
