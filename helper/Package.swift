// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "corebluetoothd",
    platforms: [
        .macOS(.v11)
    ],
    targets: [
        .executableTarget(
            name: "corebluetoothd",
            path: "Sources/corebluetoothd"
        )
    ]
)
