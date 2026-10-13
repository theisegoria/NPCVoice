// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NPCVoice",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "NPCKit", targets: ["NPCKit"]),
        .library(name: "NPCMLX", targets: ["NPCMLX"]),
        .library(name: "NPCSpeech", targets: ["NPCSpeech"]),
        .library(name: "NPCVoiceSDK", targets: ["NPCVoiceSDK"]),
        .executable(name: "npcvoice", targets: ["npcvoice"]),
    ],
    dependencies: [
        // Vendored, pinned, local-path only (third_party/PROVENANCE.md).
        .package(path: "third_party/mlx-swift-lm"),
    ],
    targets: [
        // Portable C++23 dialogue core behind a C ABI (npc_core.h).
        .target(
            name: "NPCCore",
            path: "Sources/NPCCore",
            sources: ["src"],
            publicHeadersPath: "include",
            cxxSettings: [.headerSearchPath("include")]
        ),
        // Dependency-free byte-level BPE tokenizer (Qwen tokenizer.json).
        .target(name: "NPCTokenizer", path: "Sources/NPCTokenizer"),
        .testTarget(name: "NPCTokenizerTests", dependencies: ["NPCTokenizer"], path: "Tests/NPCTokenizerTests",
                    exclude: ["Fixtures"]),
        // Native speech: Kokoro-82M on Core ML (G2P lands with M2/M3).
        .target(name: "NPCSpeech", path: "Sources/NPCSpeech"),
        .testTarget(name: "NPCSpeechTests", dependencies: ["NPCSpeech"], path: "Tests/NPCSpeechTests",
                    exclude: ["Fixtures"]),
        // Public Swift API over the C ABI.
        .target(name: "NPCKit", dependencies: ["NPCCore"], path: "Sources/NPCKit"),
        // MLX open-weight backend (Qwen3.5-2B 4-bit, xgrammar-guided decoding).
        .target(name: "NPCMLX", dependencies: [
            "NPCKit", "NPCTokenizer",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
        ], path: "Sources/NPCMLX"),
        // C exports of the Swift backends and speech (npc_sdk.h).
        .target(name: "NPCVoiceSDK", dependencies: ["NPCCore", "NPCKit", "NPCMLX", "NPCSpeech"], path: "Sources/NPCVoiceSDK"),
        .executableTarget(name: "npc-c-sample", dependencies: ["NPCVoiceSDK"], path: "Samples/c-sample",
                          exclude: ["CMakeLists.txt"]),
        // The header-only C++ wrapper used by the Unreal and Godot integrations, tested against the library.
        .executableTarget(name: "npcvoice-cpp-tests", dependencies: ["NPCVoiceSDK"], path: "Integrations/cpp",
                          sources: ["test"], cxxSettings: [.headerSearchPath("include")]),
        .executableTarget(name: "npcvoice", dependencies: ["NPCKit", "NPCMLX", "NPCSpeech"], path: "Sources/npcvoice"),
        // C++ dialogue core tests, run with `swift run NPCCoreCppTests`.
        .executableTarget(name: "NPCCoreCppTests", dependencies: ["NPCCore"], path: "Tests/NPCCoreCppTests"),
        .testTarget(name: "NPCKitTests", dependencies: ["NPCKit", "NPCCore"], path: "Tests/NPCKitTests",
                    exclude: ["Fixtures"]),
        .testTarget(name: "NPCMLXTests", dependencies: ["NPCMLX", "NPCKit"], path: "Tests/NPCMLXTests"),
    ],
    cxxLanguageStandard: .cxx2b
)
