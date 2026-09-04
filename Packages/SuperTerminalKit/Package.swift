// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SuperTerminalKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "STCore", targets: ["STCore"]),
        .library(name: "STSecureStore", targets: ["STSecureStore"]),
        .library(name: "STCloudflare", targets: ["STCloudflare"]),
        .library(name: "STSSH", targets: ["STSSH"]),
        .library(name: "STTerminal", targets: ["STTerminal"]),
        .library(name: "STTestSupport", targets: ["STTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.90.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.34.0"),
        // Vendored so RSA can be added; see DECISIONS.md D-007 and
        // Packages/swift-nio-ssh-rsa/README.md for the maintenance obligation.
        .package(path: "../swift-nio-ssh-rsa"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.24.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.15.0"),
        .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.11.0"),
    ],
    targets: [
        .target(
            name: "STCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .target(
            name: "STSecureStore",
            dependencies: ["STCore"]
        ),
        .target(
            name: "STCloudflare",
            dependencies: [
                "STCore",
                "STSecureStore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "Sodium", package: "swift-sodium"),
            ]
        ),
        .target(
            name: "CBcryptPBKDF",
            // Vendored OpenBSD bcrypt_pbkdf + Blowfish; see THIRD_PARTY_NOTICES.md.
            cSettings: [.headerSearchPath("include")]
        ),
        .target(
            name: "STSSH",
            dependencies: [
                "STCore",
                "STSecureStore",
                "STCloudflare",
                "CBcryptPBKDF",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh-rsa"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "STTestSupport",
            dependencies: [
                "STCore",
                "STCloudflare",
                "STSSH",
                "STTerminal",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "Sodium", package: "swift-sodium"),
            ]
        ),
        .target(name: "STTerminal", dependencies: ["STCore"]),
        .testTarget(name: "STCoreTests", dependencies: ["STCore"]),
        .testTarget(name: "STTerminalTests", dependencies: ["STTerminal", "STSSH", "STTestSupport"]),
        .testTarget(name: "STSSHTests", dependencies: ["STSSH", "STTestSupport"]),
        .testTarget(name: "STCloudflareTests", dependencies: ["STCloudflare", "STSSH", "STTerminal", "STTestSupport"]),
    ]
)
