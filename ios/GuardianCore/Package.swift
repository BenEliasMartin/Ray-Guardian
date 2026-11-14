// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "GuardianCore", platforms: [.iOS(.v17), .macOS(.v13)], products: [.library(name: "GuardianCore", targets: ["GuardianCore"])], targets: [.target(name: "GuardianCore"), .executableTarget(name: "GuardianCoreChecks", dependencies: ["GuardianCore"]), .testTarget(name: "GuardianCoreTests", dependencies: ["GuardianCore"])])
