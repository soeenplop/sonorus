// swift-tools-version: 6.0
import PackageDescription

// Standalone M0 rendering spike. Deliberately not part of
// the root Sonorus package; nothing here is production code.
let tools = [
  "WindowDump", "FocusProbe", "VariantA", "VariantB", "VariantC", "BlurBench",
  "TestWindows",
]

let package = Package(
  name: "RenderingSpike",
  platforms: [.macOS(.v15)],
  products: tools.map { .executable(name: $0, targets: [$0]) },
  targets: [.target(name: "SpikeKit")]
    + tools.map { .executableTarget(name: $0, dependencies: ["SpikeKit"]) }
    + [.testTarget(name: "SpikeKitTests", dependencies: ["SpikeKit"])]
)
