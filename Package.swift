// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Sayvia", platforms: [.macOS(.v14)], products: [.executable(name: "Sayvia", targets: ["Sayvia"])], targets: [.systemLibrary(name: "CSQLite"), .executableTarget(name: "Sayvia", dependencies: ["CSQLite"], resources: [.process("Resources")])], swiftLanguageModes: [.v5])
