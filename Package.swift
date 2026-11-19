// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Luma", platforms: [.macOS(.v14)], products: [.executable(name: "Velun", targets: ["Luma"])], targets: [.target(name: "CMPV", cSettings: [.unsafeFlags(["-I/opt/homebrew/include"])], linkerSettings: [.linkedLibrary("mpv"), .linkedFramework("OpenGL"), .unsafeFlags(["-L/opt/homebrew/lib", "-Xlinker", "-rpath", "-Xlinker", "/opt/homebrew/lib"])]), .executableTarget(name: "Luma", dependencies: ["CMPV"], resources: [.copy("Resources")]), .testTarget(name: "LumaTests", dependencies: ["Luma"])])
