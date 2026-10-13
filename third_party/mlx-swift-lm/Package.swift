// swift-tools-version: 6.2
// NPCVoice: trimmed from upstream 3.32.3 (kept verbatim as Package.swift.upstream).
// Keeps MLXLMCommon, MLXLLM, MLXCXGrammar, MLXGuidedGeneration and MLXFoundationModels;
// drops VLM, embedders, rerankers, helpers, the Hugging Face macros (swift-syntax) and
// tests. Dependencies are local paths (pins in third_party/PINS-mlx.txt).

import PackageDescription

let package = Package(
    name: "mlx-swift-lm",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "MLXLLM", targets: ["MLXLLM"]),
        .library(name: "MLXLMCommon", targets: ["MLXLMCommon"]),
        .library(name: "MLXFoundationModels", targets: ["MLXFoundationModels"]),
        .library(name: "MLXGuidedGeneration", targets: ["MLXGuidedGeneration"]),
    ],
    traits: [
        .trait(
            name: "FoundationModelsIntegration",
            description:
                "Enables the MLXLanguageModel adapter for Apple's FoundationModels framework."
        ),
        .default(enabledTraits: ["FoundationModelsIntegration"]),
    ],
    dependencies: [
        .package(path: "../mlx-swift"),
    ],
    targets: [
        .target(
            name: "MLXLLM",
            dependencies: [
                "MLXLMCommon",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXOptimizers", package: "mlx-swift"),
            ],
            path: "Libraries/MLXLLM",
            exclude: ["README.md"]
        ),
        .target(
            name: "MLXLMCommon",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXOptimizers", package: "mlx-swift"),
            ],
            path: "Libraries/MLXLMCommon",
            exclude: ["README.md"]
        ),
        // C++ bridge for xgrammar (vendored upstream C++17 source plus shim.cc).
        .target(
            name: "MLXCXGrammar",
            path: "Libraries/MLXCXGrammar",
            exclude: ["xgrammar/cpp/grammar_functor.cc"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("xgrammar/include"),
                .headerSearchPath("xgrammar/cpp"),
                .headerSearchPath("xgrammar/3rdparty/picojson"),
                .headerSearchPath("xgrammar/3rdparty/dlpack/include"),
                .define("XGRAMMAR_ENABLE_CPPTRACE", to: "0"),
                .define("XGRAMMAR_ENABLE_INTERNAL_CHECK", to: "0"),
                .define("xgrammar", to: "mlx_xgrammar"),
                .define("picojson", to: "mlx_picojson"),
                .unsafeFlags(["-w"], .when(platforms: [.macOS, .iOS, .visionOS, .tvOS])),
            ],
            linkerSettings: [
                .linkedLibrary("c++", .when(platforms: [.macOS, .iOS, .visionOS, .tvOS]))
            ]
        ),
        .target(
            name: "MLXGuidedGeneration",
            dependencies: [
                "MLXLMCommon",
                "MLXCXGrammar",
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Libraries/MLXGuidedGeneration"
        ),
        .target(
            name: "MLXFoundationModels",
            dependencies: [
                "MLXLMCommon",
                .target(
                    name: "MLXGuidedGeneration",
                    condition: .when(traits: ["FoundationModelsIntegration"])
                ),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ],
            path: "Libraries/MLXFoundationModels"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
