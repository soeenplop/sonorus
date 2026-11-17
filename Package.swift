// swift-tools-version: 6.0
import PackageDescription

let modules: [(name: String, dependencies: [Target.Dependency])] = [
  ("Geometry", ["Contracts"])
]

let package = Package(
  name: "Sonorus",
  platforms: [.macOS(.v15)],
  products: [.executable(name: "Sonorus", targets: ["SonorusApp"])],
  targets: [
    .target(name: "Contracts"),
    .target(name: "TestSupport", dependencies: ["Contracts"], path: "Tests/Support"),
    .testTarget(name: "ContractsTests", dependencies: ["Contracts", "TestSupport"]),
    .executableTarget(
      name: "SonorusApp",
      dependencies: ["Contracts"] + modules.map { .byName(name: $0.name) },
      path: "Sources/App"),
  ]
    + modules.flatMap { module in
      [
        .target(name: module.name, dependencies: module.dependencies),
        .testTarget(
          name: "\(module.name)Tests",
          dependencies: [.byName(name: module.name), "Contracts", "TestSupport"]),
      ]
    }
)
