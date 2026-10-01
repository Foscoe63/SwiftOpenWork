import Foundation
import SwiftOpenWorkEngine
import SwiftOpenWorkLocalInference

/// Hands the engine the in-process MLX engine and local-server launcher. The engine module does
/// not link MLX, so the app — which links both — connects them. Safe to call more than once.
enum LocalInferenceWiring {
    static func install() {
        LocalInferenceRegistry.register(engine: NativeMLXService.shared, serverLauncher: LocalMLXEngine.shared)
        EmbedderRegistry.register(MLXEmbeddingService.shared)
    }
}
