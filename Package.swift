// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SwiftOpenWork",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "SwiftOpenWork",
            targets: ["SwiftOpenWork"]
        ),
        // What the Xcode app links: every module in one dynamic library. See project.yml.
        .library(
            name: "SwiftOpenWorkKit",
            type: .dynamic,
            targets: [
                "SwiftOpenWorkCore",
                "SwiftOpenWorkStorage",
                "SwiftOpenWorkLocalInference",
                "SwiftOpenWorkEngine",
            ]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.4")),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
        // Not imported directly: declared only to cap the version. swift-collections 1.7 needs a
        // newer standard library (BorrowingIteratorProtocol, Iterable) than the current toolchain.
        .package(url: "https://github.com/apple/swift-collections.git", .upToNextMinor(from: "1.6.0")),
    ],
    targets: [
        // Models and small utilities: no dependencies on the rest of the app.
        .target(
            name: "SwiftOpenWorkCore",
            path: "Sources/SwiftOpenWorkCore"
        ),
        // Settings, sessions and credentials on disk and in the Keychain.
        .target(
            name: "SwiftOpenWorkStorage",
            dependencies: ["SwiftOpenWorkCore"],
            path: "Sources/SwiftOpenWorkStorage"
        ),
        // The in-process MLX engine and model discovery. Everything that links MLX, Hugging Face
        // or Transformers lives here, so code that does not need them does not compile them.
        .target(
            name: "SwiftOpenWorkLocalInference",
            dependencies: [
                "SwiftOpenWorkCore",
                "SwiftOpenWorkStorage",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                // Vision checkpoints need their own factory; LLMModelFactory builds a text-only
                // pipeline that silently drops images. See NativeMLXService.loadContainer…
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                // Small encoder models for semantic code search.
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/SwiftOpenWorkLocalInference",
            cxxSettings: [
                .unsafeFlags(["-std=c++17", "-Wno-c++17-extensions"])
            ]
        ),
        // The agent loop, tools, providers, MCP, language servers, preview and automations. It
        // reaches the running app only through `EngineHost`, and the MLX engine only through
        // `LocalInferenceRegistry` — it does not link MLX.
        .target(
            name: "SwiftOpenWorkEngine",
            dependencies: [
                "SwiftOpenWorkCore",
                "SwiftOpenWorkStorage",
                .product(name: "Yams", package: "yams"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources/SwiftOpenWorkEngine"
        ),
        .executableTarget(
            name: "SwiftOpenWork",
            dependencies: [
                "SwiftOpenWorkCore",
                "SwiftOpenWorkStorage",
                "SwiftOpenWorkLocalInference",
                "SwiftOpenWorkEngine",
            ],
            path: "Sources/SwiftOpenWork",
            resources: [
                .process("../../Resources")
            ],
            cxxSettings: [
                .unsafeFlags(["-std=c++17", "-Wno-c++17-extensions"])
            ]
        ),
        // Tests that need only the engine and what it depends on. No app, no MLX: building these
        // compiles neither the SwiftUI layer nor the MLX packages.
        .testTarget(
            name: "SwiftOpenWorkEngineTests",
            dependencies: [
                "SwiftOpenWorkCore",
                "SwiftOpenWorkStorage",
                "SwiftOpenWorkEngine",
            ]
        ),
        // Tests of the app, its state and views, and the MLX engine.
        .testTarget(
            name: "SwiftOpenWorkTests",
            dependencies: [
                "SwiftOpenWorkCore",
                "SwiftOpenWorkStorage",
                "SwiftOpenWorkLocalInference",
                "SwiftOpenWorkEngine",
                .target(name: "SwiftOpenWork")
            ]
        )
    ],
    // Every target, tests included, compiles in the Swift 6 language mode.
    swiftLanguageModes: [.v6]
)
