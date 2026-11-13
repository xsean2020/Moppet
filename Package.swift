// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Moppet",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Unified AI SDK for Swift (port of Vercel AI SDK): multi-vendor
        // providers, streaming, tool-calling agent loops.
        // Vendored（Apache-2.0，源 Vendor/swift-ai-sdk）：0.20.0 在
        // Swift 6.0/6.1（Xcode 16.x / Intel Mac）编译报 Sendable 跨界错
        // （ConvertAsyncIteratorToReadableStream.swift），上游无修复 tag，
        // 本地补丁见该文件内注释；上游发布修复版后可换回远程依赖。
        .package(path: "Vendor/swift-ai-sdk"),
        // Markdown rendering for the AI chat transcript.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
        // Keychain wrapper for the AI API key.
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),
        // Launch at login (SMAppService) for the desktop pet.
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern.git", from: "1.1.0"),
        // Swift-native VRM parser + RealityKit renderer. The RealityKit
        // product is gated to macOS 15 by its own @available annotations;
        // MatePet keeps a WKWebView fallback for macOS 14.
        .package(url: "https://github.com/tattn/VRMKit.git", from: "0.11.0"),
    ],
    targets: [
        // Desktop-pet avatar engine, kept independent of the app's Brain /
        // cleaning / network modules. macOS 15+ uses RealityKit/VRMRealityKit;
        // macOS 14 falls back to WKWebView + three-vrm. Moppet only feeds it
        // `PetBus` state and user intent.
        .target(
            name: "MatePet",
            dependencies: [
                .product(name: "VRMKit", package: "VRMKit"),
                .product(name: "VRMRealityKit", package: "VRMKit"),
            ],
            path: "Sources/MatePet",
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Moppet",
            dependencies: [
                .target(name: "MatePet"),
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
                // airi's emotion stickers (MIT) — chat avatar reacts to pet state.
                .copy("Resources/stickers"),
                // Brand icon for the sidebar / title bar (full app icon).
                .process("Resources/brand.png"),
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
