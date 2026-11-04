// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "KeyBridge", platforms: [.macOS(.v13)],
    products: [.executable(name: "KeyBridgeApp", targets: ["KeyBridgeApp"]),
               .executable(name: "KeyBridgeAgent", targets: ["KeyBridgeAgent"]),
               .executable(name: "KeyBridgeControl", targets: ["KeyBridgeControl"]),
               .executable(name: "KeyBridgeConfigure", targets: ["KeyBridgeConfigure"])],
    targets: [.target(name: "KeyBridgeCore"),
              .executableTarget(name: "KeyBridgeApp", dependencies: ["KeyBridgeCore"]),
              .executableTarget(name: "KeyBridgeAgent", dependencies: ["KeyBridgeCore"]),
              .executableTarget(name: "KeyBridgeControl", dependencies: ["KeyBridgeCore"]),
              .executableTarget(name: "KeyBridgeConfigure", dependencies: ["KeyBridgeCore"]),
              .testTarget(name: "KeyBridgeCoreTests", dependencies: ["KeyBridgeCore"]),
              .testTarget(name: "KeyBridgeAppTests", dependencies: ["KeyBridgeApp"])],
    swiftLanguageVersions: [.v5])
