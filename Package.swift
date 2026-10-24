// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Moppet",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Unified AI SDK for Swift (port of Vercel AI SDK): multi-vendor
        // providers, streaming, tool-calling agent loops.
        .package(url: "https://github.com/teunlao/swift-ai-sdk.git", from: "0.20.0"),
        // Markdown rendering for the AI chat transcript.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
        // Keychain wrapper for the AI API key.
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),
        // Launch at login (SMAppService) for the desktop pet.
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "Moppet",
            dependencies: [
                .product(name: "SwiftAISDK", package: "swift-ai-sdk"),
                .product(name: "OpenAIProvider", package: "swift-ai-sdk"),
                .product(name: "OpenAICompatibleProvider", package: "swift-ai-sdk"),
                .product(name: "AnthropicProvider", package: "swift-ai-sdk"),
                .product(name: "GoogleProvider", package: "swift-ai-sdk"),
                .product(name: "DeepSeekProvider", package: "swift-ai-sdk"),
                .product(name: "GroqProvider", package: "swift-ai-sdk"),
                .product(name: "MistralProvider", package: "swift-ai-sdk"),
                .product(name: "OpenResponsesProvider", package: "swift-ai-sdk"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "KeychainAccess", package: "KeychainAccess"),
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
            ],
            path: "Sources/Moppet",
            resources: [
                // 3D pet renderer assets (idle_loop.vrma comes from airi, MIT).
                .copy("Resources/pet"),
                // airi's emotion stickers (MIT) — chat avatar reacts to pet state.
                .copy("Resources/stickers"),
            ],
            // Pin OUR target to Swift 5 language mode explicitly. The code is
            // written for Swift 5 semantics (lock-guarded static state, no
            // actor annotations on the singletons); the tools-version alone
            // is not a guarantee once a toolchain or IDE setting flips the
            // mode. Dependencies keep their own declared modes.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
