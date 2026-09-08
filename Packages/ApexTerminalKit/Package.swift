// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ApexTerminalKit",
    // Required before any target may ship localized resources. The error messages these
    // modules produce are shown to the user verbatim, so they are translated here rather
    // than re-worded in the app — the app would have to know every failure mode to do it.
    defaultLocalization: "en",
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
        .library(name: "STVNC", targets: ["STVNC"]),
        .library(name: "STSFTP", targets: ["STSFTP"]),
        .library(name: "STFileProvider", targets: ["STFileProvider"]),
        .library(name: "STForwarding", targets: ["STForwarding"]),
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
            ],
            // The user sees these modules' error messages verbatim, so their strings are
            // translated here. Declaring the catalog explicitly is what makes SwiftPM
            // generate `Bundle.module` for the target — without it the symbol resolves to
            // some other module's and fails to compile.
            resources: [.process("Localizable.xcstrings")]
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
            ],
            // The user sees these modules' error messages verbatim, so their strings are
            // translated here. Declaring the catalog explicitly is what makes SwiftPM
            // generate `Bundle.module` for the target — without it the symbol resolves to
            // some other module's and fails to compile.
            resources: [.process("Localizable.xcstrings")]
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
                "STSFTP",
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
                // Raw libsodium, for chacha20-poly1305@openssh.com: the construction is
                // OpenSSH's own, not the RFC 8439 AEAD, so it needs the stream cipher and
                // the one-time authenticator separately rather than the sealed-box API.
                .product(name: "Clibsodium", package: "swift-sodium"),
            ],
            // The user sees these modules' error messages verbatim, so their strings are
            // translated here. Declaring the catalog explicitly is what makes SwiftPM
            // generate `Bundle.module` for the target — without it the symbol resolves to
            // some other module's and fails to compile.
            resources: [.process("Localizable.xcstrings")]
        ),
        .target(
            name: "STForwarding",
            dependencies: [
                "STCore",
                "STSSH",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "NIOSSH", package: "swift-nio-ssh-rsa"),
            ],
            // A refused port and a refused forward are both things the user reads, and
            // there is no app around this module to reword them.
            resources: [.process("Localizable.xcstrings")]
        ),
        .target(
            name: "STFileProvider",
            dependencies: [
                "STCore",
                "STSFTP",
                "STSSH",
                "STSecureStore",
                "STCloudflare",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            ],
            // Everything this module says reaches the user through the Files app, where
            // there is no app around it to reword anything — so it is translated here.
            resources: [.process("Localizable.xcstrings")]
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
            ],
            // A C program the VNC tests compile against LibVNCServer at run time; not a
            // source of this target.
            exclude: ["Fixtures"]
        ),
        .target(name: "STTerminal", dependencies: ["STCore"]),
        // SFTP version 3, over any ordered byte channel (D-041).
        .target(
            name: "STSFTP",
            dependencies: [
                "STCore",
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .testTarget(name: "STSFTPTests", dependencies: ["STSFTP", "STSSH", "STTestSupport"]),
        .testTarget(
            name: "STForwardingTests",
            dependencies: ["STForwarding", "STSSH", "STTestSupport", .product(name: "NIOPosix", package: "swift-nio")]
        ),
        .testTarget(
            name: "STFileProviderTests",
            dependencies: ["STFileProvider", "STSSH", "STSFTP", "STTestSupport"]
        ),
        // The RFB client (D-022). No dependency on the SSH module: it speaks over any
        // channel, and the app hands it a `direct-tcpip` one.
        .target(
            name: "STVNC",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ]
        ),
        .testTarget(name: "STCoreTests", dependencies: ["STCore"]),
        .testTarget(name: "STTerminalTests", dependencies: ["STTerminal", "STSSH", "STTestSupport"]),
        .testTarget(
            name: "STSSHTests",
            dependencies: [
                "STSSH",
                "STTestSupport",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh-rsa"),
            ]
        ),
        .testTarget(name: "STCloudflareTests", dependencies: ["STCloudflare", "STSSH", "STTerminal", "STTestSupport"]),
        .testTarget(
            name: "STVNCTests",
            dependencies: [
                "STVNC",
                "STTestSupport",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),
    ]
)
