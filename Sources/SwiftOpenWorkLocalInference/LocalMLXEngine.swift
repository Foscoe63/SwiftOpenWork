import Foundation
import SwiftOpenWorkCore

/// Discovers, validates, and runs local Apple Silicon MLX models directly on-device.
/// Parity with Osaurus / GrizzyClaw local MLX scanners and Hugging Face hub caches.
public final class LocalMLXEngine: @unchecked Sendable {
    public static let shared = LocalMLXEngine()

    public static var physicalRAMGB: Double { MLXMemoryBudget.physicalRAMGB }

    public static var freeRAMGB: Double {
        let hostPort = mach_host_self()
        let size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStats = vm_statistics64()
        var mutableSize = size
        
        let kerr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &mutableSize)
            }
        }
        
        if kerr == KERN_SUCCESS {
            // `vm_kernel_page_size` is a mutable C global, which Swift 6 will not read from
            // nonisolated code; `getpagesize()` returns the same value.
            let pageSize = UInt64(getpagesize())
            let freeBytes = (UInt64(vmStats.free_count) + UInt64(vmStats.inactive_count)) * pageSize
            return Double(freeBytes) / (1024 * 1024 * 1024)
        }
        return physicalRAMGB * 0.45 // Fallback estimate
    }

    /// Size of the weight files in a model directory, in decimal GB. nil when there are none.
    public static func weightsSizeGB(in directory: URL) -> Double? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let bytes = files.filter { $0.pathExtension == "safetensors" }.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return bytes > 0 ? Double(bytes) / 1_000_000_000 : nil
    }

    public static var totalStorageGB: Double {
        let home = NSHomeDirectory()
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: home),
           let totalBytes = attrs[.systemSize] as? NSNumber {
            return totalBytes.doubleValue / (1024 * 1024 * 1024)
        }
        return 1000.0
    }

    public static var freeStorageGB: Double {
        let home = NSHomeDirectory()
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: home),
           let freeBytes = attrs[.systemFreeSize] as? NSNumber {
            return freeBytes.doubleValue / (1024 * 1024 * 1024)
        }
        return 500.0
    }

    public static func clampedBudgetRatio(_ ratio: Double) -> Double {
        MLXMemoryBudget.clampedBudgetRatio(ratio)
    }

    /// Whether a model's own `config.json` describes an image pathway.
    ///
    /// Structural, not nominal: a vision tower, an image token, or a nested text config (which
    /// is how multimodal checkpoints separate the language half) all mean the checkpoint can
    /// take pixels, whatever its `model_type` happens to be called.
    /// The context window a checkpoint's `config.json` declares.
    ///
    /// Multimodal checkpoints keep their language model's settings under `text_config` —
    /// Ornith-1.5, Qwen3.6 and Qwen3.8 all declare 262,144 there and nothing at the top level. Only
    /// the top level was read, so they were listed at the 131,072 fallback: half their real window,
    /// which the context meter then measured against.
    public static func declaredContextWindow(config: [String: Any]) -> Int? {
        let keys = ["max_position_embeddings", "max_seq_len", "max_sequence_length", "n_positions"]
        func read(_ dict: [String: Any]) -> Int? {
            for key in keys {
                if let value = dict[key] as? Int, value > 0 { return value }
            }
            return nil
        }
        if let top = read(config) { return top }
        for nested in ["text_config", "llm_config", "language_config"] {
            if let dict = config[nested] as? [String: Any], let value = read(dict) { return value }
        }
        return nil
    }

    public static func declaresVisionSupport(config: [String: Any]) -> Bool {
        if config["vision_config"] != nil { return true }
        if config["image_token_id"] != nil { return true }
        if config["image_token_index"] != nil { return true }
        // Names remain a fallback for checkpoints that declare nothing structural. One list for
        // both `architectures` and `model_type`, so the two cannot drift apart — which is how
        // `LlavaForConditionalGeneration` slipped past an architecture check that looked only
        // for "vision" and "vl".
        let nameMarkers = ["vl", "vision", "pixtral", "mllama", "llava", "idefics", "imagetext", "gemma4"]
        var names: [String] = []
        if let architectures = config["architectures"] as? [String] { names += architectures }
        if let mt = config["model_type"] as? String { names.append(mt) }
        for name in names.map({ $0.lowercased() }) {
            if nameMarkers.contains(where: { name.contains($0) }) { return true }
        }
        return false
    }

    public static func assessCompatibility(
        requiredRAMGB: Double,
        budgetRatio: Double = AppSettings.default.mlxGpuMemoryBudgetRatio
    ) -> ModelCompatibility {
        MLXMemoryBudget.assessCompatibility(requiredRAMGB: requiredRAMGB, budgetRatio: budgetRatio)
    }

    /// Curated presets of recommended MLX models matching Osaurus and GrizzyClaw.
    ///
    /// Every id here is a real Hugging Face repo, checked with `Scripts/check-curated-models.sh`.
    /// Five of these used to 401 — the app offered downloads that could not succeed and reported
    /// an opaque `HTTPClientError` when they failed. Run that script after editing this list.
    public static let curatedModels: [LocalMLXModel] = [
        LocalMLXModel(
            id: "mlx-community/Ornith-1.5-35B-A3B-8bit",
            name: "Ornith 1.5 35B A3B 8bit",
            description: "High-precision 35B MoE (~3B active) hybrid reasoning model. Exceptional coding, tool use, and 256K context.",
            sizeBytes: 40_500_000_000,
            parameterCount: "35B",
            quantization: "8-bit",
            modelType: "qwen3_5_moe",
            contextWindow: 262_144,
            useCase: .reasoning,
            compatibility: assessCompatibility(requiredRAMGB: 43.9),
            estimatedRAMGB: 43.9,
            tags: ["Recommended", "MoE", "Tool Use", "256K Context"],
            isTopPick: true
        ),
        LocalMLXModel(
            id: "mlx-community/Qwen3-Coder-Next-5bit",
            name: "Qwen3 Coder Next MLX 5bit",
            description: "Advanced coding next-gen model with multi-agent orchestration and fill-in-the-middle support.",
            sizeBytes: 58_800_000_000,
            parameterCount: "48B",
            quantization: "5-bit",
            modelType: "qwen3_coder",
            contextWindow: 131_072,
            useCase: .coding,
            compatibility: assessCompatibility(requiredRAMGB: 63.8),
            estimatedRAMGB: 63.8,
            tags: ["Coding", "131K Context", "Top Coder"],
            isTopPick: true
        ),
        LocalMLXModel(
            id: "andosen/Qwen3-Coder-Next-REAP-48B-A3B-mlx-8Bit",
            name: "Qwen3 Coder Next REAP 48B A3B mlx 8Bit",
            description: "Frontier coding model with MoE sparse execution and deep tool invocation proficiency.",
            sizeBytes: 55_730_000_000,
            parameterCount: "48B",
            quantization: "8-bit",
            modelType: "qwen3_coder",
            contextWindow: 131_072,
            useCase: .coding,
            compatibility: assessCompatibility(requiredRAMGB: 60.4),
            estimatedRAMGB: 60.4,
            tags: ["Coding", "MoE", "8-bit"],
            isTopPick: true
        ),
        LocalMLXModel(
            id: "mlx-community/Qwen3.6-35B-A3B-8bit",
            name: "Qwen3.6 35B A3B 8bit",
            description: "Flagship hybrid dense/MoE intelligence with multilingual knowledge and swift token generation.",
            sizeBytes: 39_550_000_000,
            parameterCount: "35B",
            quantization: "8-bit",
            modelType: "qwen3",
            contextWindow: 131_072,
            useCase: .general,
            compatibility: assessCompatibility(requiredRAMGB: 42.9),
            estimatedRAMGB: 42.9,
            tags: ["General", "Fast", "MoE"],
            isTopPick: true
        ),
        LocalMLXModel(
            id: "mlx-community/Qwen3.8-27B-8bit",
            name: "Qwen3.8 27B 8bit",
            description: "High-capability reasoning and general-purpose intelligence balanced for 32GB+ Apple Silicon.",
            sizeBytes: 30_690_000_000,
            parameterCount: "27B",
            quantization: "8-bit",
            modelType: "qwen3",
            contextWindow: 131_072,
            useCase: .general,
            compatibility: assessCompatibility(requiredRAMGB: 33.3),
            estimatedRAMGB: 33.3,
            tags: ["General", "Balanced"],
            isTopPick: false
        ),
        LocalMLXModel(
            id: "ornith-ai/Ornith-1.5-35B-A3B-MLX-4bit",
            name: "Ornith 1.5 35B A3B 4bit",
            description: "Fast 35B MoE (~3B active) reasoning model. Low memory footprint with strong instruction following and tool use.",
            sizeBytes: 19_800_000_000,
            parameterCount: "35B",
            quantization: "4-bit",
            modelType: "qwen3_5_moe",
            contextWindow: 262_144,
            useCase: .reasoning,
            compatibility: assessCompatibility(requiredRAMGB: 21.0),
            estimatedRAMGB: 21.0,
            tags: ["MoE", "Fast", "256K Context"],
            isTopPick: true
        ),
        LocalMLXModel(
            id: "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit",
            name: "Qwen 2.5 Coder 32B (4-bit)",
            description: "State-of-the-art open-source code generation, repository analysis, and refactoring model. 128K context.",
            sizeBytes: 18_500_000_000,
            parameterCount: "32B",
            quantization: "4-bit",
            modelType: "qwen2",
            contextWindow: 131_072,
            useCase: .coding,
            compatibility: assessCompatibility(requiredRAMGB: 20.0),
            estimatedRAMGB: 20.0,
            tags: ["Coding", "128K Context", "Top Coder"],
            isTopPick: true
        ),
        LocalMLXModel(
            id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            name: "Qwen 2.5 Coder 7B (4-bit)",
            description: "Lightweight and fast coding assistant. Fits on all Macs with 8 GB or 16 GB RAM.",
            sizeBytes: 4_400_000_000,
            parameterCount: "7B",
            quantization: "4-bit",
            modelType: "qwen2",
            contextWindow: 131_072,
            useCase: .coding,
            compatibility: assessCompatibility(requiredRAMGB: 5.5),
            estimatedRAMGB: 5.5,
            tags: ["Coding", "Fast", "Low RAM"],
            isTopPick: true
        ),
        LocalMLXModel(
            id: "mlx-community/gemma-4-e4b-it-4bit",
            name: "Gemma 4 E4B (4-bit)",
            description: "Google's lightweight multimodal edge model with native vision and speech capabilities.",
            sizeBytes: 3_200_000_000,
            parameterCount: "4B",
            quantization: "4-bit",
            modelType: "gemma4",
            contextWindow: 131_072,
            isVLM: true,
            useCase: .vision,
            compatibility: assessCompatibility(requiredRAMGB: 4.5),
            estimatedRAMGB: 4.5,
            tags: ["Vision", "Google", "Low RAM"],
            isTopPick: true
        ),
        LocalMLXModel(
            id: "mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit",
            name: "DeepSeek R1 Distill 14B (4-bit)",
            description: "Reasoning and chain-of-thought powerhouse distilled from DeepSeek-R1 into Qwen architecture.",
            sizeBytes: 8_900_000_000,
            parameterCount: "14B",
            quantization: "4-bit",
            modelType: "qwen2",
            contextWindow: 131_072,
            useCase: .reasoning,
            compatibility: assessCompatibility(requiredRAMGB: 10.5),
            estimatedRAMGB: 10.5,
            tags: ["Reasoning", "Chain of Thought"],
            isTopPick: true
        ),
        LocalMLXModel(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            name: "Llama 3.2 3B (4-bit)",
            description: "Meta's ultra-compact edge model. Instant response times, ideal for local formatting and fast chats.",
            sizeBytes: 2_100_000_000,
            parameterCount: "3B",
            quantization: "4-bit",
            modelType: "llama",
            contextWindow: 131_072,
            useCase: .fast,
            compatibility: assessCompatibility(requiredRAMGB: 3.0),
            estimatedRAMGB: 3.0,
            tags: ["Meta", "Ultra Fast", "Low RAM"],
            isTopPick: true
        ),
        LocalMLXModel(
            id: "mlx-community/Mistral-Small-24B-Instruct-2501-4bit",
            name: "Mistral Small 24B (4-bit)",
            description: "Mistral's powerful 24B dense model. Excellent reasoning, function calling, and structured JSON output.",
            sizeBytes: 14_200_000_000,
            parameterCount: "24B",
            quantization: "4-bit",
            modelType: "mistral",
            contextWindow: 32_768,
            useCase: .general,
            compatibility: assessCompatibility(requiredRAMGB: 16.0),
            estimatedRAMGB: 16.0,
            tags: ["Mistral", "Tool Use"],
            isTopPick: false
        ),
        LocalMLXModel(
            id: "mlx-community/Codestral-22B-v0.1-4bit",
            name: "Codestral 22B (4-bit)",
            description: "Mistral's dedicated code generation and fill-in-the-middle model supporting 80+ programming languages.",
            sizeBytes: 13_100_000_000,
            parameterCount: "22B",
            quantization: "4-bit",
            modelType: "mistral",
            contextWindow: 32_768,
            useCase: .coding,
            compatibility: assessCompatibility(requiredRAMGB: 15.0),
            estimatedRAMGB: 15.0,
            tags: ["Coding", "Mistral", "FIM"],
            isTopPick: false
        ),
        LocalMLXModel(
            id: "mlx-community/SmolLM2-1.7B-Instruct",
            name: "SmolLM2 1.7B",
            description: "Ultra-compact Hugging Face sub-2B model. Blazing fast inference with near-zero memory footprint.",
            // mlx-community publishes this unquantised; there is no 4-bit build under that org,
            // and the entry used to claim one at 1.1GB.
            sizeBytes: 3_430_000_000,
            parameterCount: "1.7B",
            quantization: "fp16",
            modelType: "llama",
            contextWindow: 8_192,
            useCase: .fast,
            compatibility: assessCompatibility(requiredRAMGB: 4.5),
            estimatedRAMGB: 4.5,
            tags: ["Ultra Fast", "Sub-2B", "Low RAM"],
            isTopPick: false
        )
    ]

    private init() {}

    /// Mounted volumes, plus `/Volumes` itself for the common case where nothing is mounted.
    ///
    /// `mountedVolumeURLs` skips volumes the user has hidden from the browser, so `/Volumes` is
    /// also listed directly and walked one level down.
    public static func mountedVolumes() -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        func add(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard !result.contains(where: { $0.standardizedFileURL == standardized }) else { return }
            result.append(standardized)
        }
        for volume in fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [] {
            add(volume)
        }
        let volumesRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        for entry in (try? fm.contentsOfDirectory(at: volumesRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [] {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
                add(entry)
            }
        }
        return result
    }

    /// Shared roots where SwiftOpenWork looks for installed MLX weights.
    public static func knownMLXSearchRoots(settings: AppSettings? = nil) -> [URL] {
        var roots: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default

        func appendIfExists(_ url: URL) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if !roots.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                    roots.append(url)
                }
            }
        }

        let appMlx = AppIdentity.homeDataDirectory.appendingPathComponent("mlx_models", isDirectory: true)
        try? fm.createDirectory(at: appMlx, withIntermediateDirectories: true)
        roots.append(appMlx)

        if let settings, !settings.customMLXModelsDirectory.isEmpty {
            let expanded = (settings.customMLXModelsDirectory as NSString).expandingTildeInPath
            appendIfExists(URL(fileURLWithPath: expanded, isDirectory: true))
        }

        // Model libraries on attached volumes.
        //
        // This used to name `/Volumes/Storage/Models` literally, which is not where this — or any
        // other — machine keeps its weights. The real library here is `/Volumes/Models/Models`, so
        // every lookup missed a complete 35GB checkpoint sitting on disk and the chat turn fell
        // through to re-downloading it from Hugging Face. Sweep the mounted volumes for the usual
        // library folder names instead of asserting one path.
        for volume in mountedVolumes() {
            for name in ["Models", "models"] {
                let library = volume.appendingPathComponent(name, isDirectory: true)
                appendIfExists(library)
                // `/Volumes/Models/Models`: a volume named for its contents holds the library one
                // level down, so the useful root is the child, not the mount point.
                appendIfExists(library.appendingPathComponent(name, isDirectory: true))
            }
        }

        appendIfExists(home.appendingPathComponent(".grizzyclaw/mlx_models", isDirectory: true))
        appendIfExists(home.appendingPathComponent("Library/Application Support/GrizzyClaw/mlx_models", isDirectory: true))
        // The settings toggle for this existed but nothing read it, so turning LM Studio discovery
        // off still listed its models. Matches the Hugging Face guard below: nil settings means
        // "no preference expressed", which scans.
        if settings?.scanLMStudioModels != false {
            appendIfExists(home.appendingPathComponent(".lmstudio/models", isDirectory: true))
            appendIfExists(home.appendingPathComponent(".cache/lm-studio/models", isDirectory: true))
            appendIfExists(home.appendingPathComponent("Library/Application Support/LM Studio/models", isDirectory: true))
        }

        if settings?.scanHuggingFaceCache != false {
            appendIfExists(home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true))
            if let settings, !settings.customHFCachePath.isEmpty {
                let customHf = URL(fileURLWithPath: (settings.customHFCachePath as NSString).expandingTildeInPath, isDirectory: true)
                appendIfExists(customHf)
            }
        }

        return roots
    }

    /// Resolve an on-disk directory for a model id (`org/name`) under known MLX roots.
    ///
    /// `roots` exists so a caller can state exactly where to look. Production passes nil and gets
    /// `knownMLXSearchRoots`; a test passes its own directory and is then unaffected by whatever
    /// model library happens to be attached to the machine running it — which is not a
    /// hypothetical, since the name matching below deliberately returns nil when two roots offer
    /// the same model, and a real library made that the outcome for a fixture that should match.
    public func resolveLocalModelDirectory(
        modelId: String,
        settings: AppSettings? = nil,
        roots explicitRoots: [URL]? = nil
    ) -> URL? {
        let roots = explicitRoots ?? Self.knownMLXSearchRoots(settings: settings)
        let sanitizedId = modelId.replacingOccurrences(of: "/", with: "--")
        let hubFolder = "models--" + sanitizedId

        for base in roots {
            let candidates = [
                base.appendingPathComponent(modelId),
                base.appendingPathComponent(sanitizedId),
                base.appendingPathComponent("models").appendingPathComponent(modelId),
                base.appendingPathComponent("models").appendingPathComponent(sanitizedId),
                base.appendingPathComponent("hub").appendingPathComponent(hubFolder)
            ]
            for candidate in candidates {
                if Self.isModelDirectoryComplete(candidate) {
                    return candidate
                }
                // HF hub layout: models--org--name/snapshots/<rev>
                let snapshots = candidate.appendingPathComponent("snapshots")
                if let snaps = try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil),
                   let complete = snaps.first(where: { Self.isModelDirectoryComplete($0) }) {
                    return complete
                }
            }

            let snapshotDir = base.appendingPathComponent(hubFolder).appendingPathComponent("snapshots")
            if let snaps = try? FileManager.default.contentsOfDirectory(at: snapshotDir, includingPropertiesForKeys: nil),
               let complete = snaps.first(where: { Self.isModelDirectoryComplete($0) }) {
                return complete
            }
        }

        // Nothing at an exact path. The same weights are routinely re-published under a different
        // org (mlx-community/X vs andosen/X), and a settings value may carry a bare slug with no
        // org at all — both resolve to nil above even though the model is on disk. Fall back to
        // matching the model *name*, and only when exactly one candidate matches, so a request for
        // an 8-bit build never silently loads a 4-bit one.
        return resolveByName(modelId: modelId, roots: roots)
    }

    /// Compare model names ignoring org, case, and separator style.
    public static func normalizedModelName(_ id: String) -> String {
        let name = id.split(separator: "/").last.map(String.init) ?? id
        return name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func resolveByName(modelId: String, roots: [URL]) -> URL? {
        let wanted = Self.normalizedModelName(modelId)
        guard wanted.count >= 4 else { return nil }

        var exact: [URL] = []
        var prefixed: [URL] = []
        for root in roots {
            var installed: [String: LocalMLXModel] = [:]
            scanDirectoryRecursively(root: root, current: root, depth: 0, results: &installed)
            for (repoId, model) in installed {
                guard let dir = model.localDirectory.map({ URL(fileURLWithPath: $0) }) else { continue }
                let candidate = Self.normalizedModelName(repoId)
                if candidate == wanted {
                    exact.append(dir)
                } else if candidate.hasPrefix(wanted) || wanted.hasPrefix(candidate) {
                    prefixed.append(dir)
                }
            }
        }
        if exact.count == 1 { return exact[0] }
        if exact.isEmpty, prefixed.count == 1 { return prefixed[0] }
        return nil
    }

    /// Same completeness rules as the in-process loader: config.json + all weight shards present.
    public static func isModelDirectoryComplete(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) else { return false }

        func nonEmptyFileExists(_ path: String) -> Bool {
            guard let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int else { return false }
            return size > 0
        }

        let indexURL = dir.appendingPathComponent("model.safetensors.index.json")
        if fm.fileExists(atPath: indexURL.path) {
            guard let data = try? Data(contentsOf: indexURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let weightMap = json["weight_map"] as? [String: String] else {
                return false
            }
            let requiredShards = Set(weightMap.values)
            guard !requiredShards.isEmpty else { return false }
            return requiredShards.allSatisfy { nonEmptyFileExists(dir.appendingPathComponent($0).path) }
        }

        guard let contents = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        let weightFiles = contents.filter { $0.hasSuffix(".safetensors") }
        guard !weightFiles.isEmpty else { return false }
        return weightFiles.allSatisfy { nonEmptyFileExists(dir.appendingPathComponent($0).path) }
    }

    /// Validates an MLX model directory on disk.
    public func validateModelFolder(directory: URL) -> MLXModelFolderValidation {
        let configURL = directory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return .missingConfig
        }
        guard let data = try? Data(contentsOf: configURL) else {
            return .unreadableConfig
        }
        if let prefix = String(data: data.prefix(128), encoding: .utf8), prefix.hasPrefix("version https://git-lfs") {
            return .gitLFSPointer
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .invalidJSON
        }
        guard let modelType = object["model_type"] as? String, !modelType.isEmpty else {
            return .missingModelType
        }
        return .ok(modelType: modelType)
    }

    /// Scans all configured locations (custom paths, attached model volumes, Hugging Face cache,
    /// LM Studio, GrizzyClaw). `roots` overrides that list; see `resolveLocalModelDirectory`.
    public func scanInstalledModels(settings: AppSettings, roots: [URL]? = nil) -> [LocalMLXModel] {
        let directoriesToScan = roots ?? Self.knownMLXSearchRoots(settings: settings)

        var foundInstalled: [String: LocalMLXModel] = [:]

        for root in directoriesToScan {
            scanDirectoryRecursively(root: root, current: root, depth: 0, results: &foundInstalled)
        }

        // Merge with curated catalog
        var finalCatalog: [LocalMLXModel] = []
        for curated in Self.curatedModels {
            // Match on id first, then on name: the same weights under a different org are the
            // same model, and listing both — one of them claiming to need a 48GB download —
            // is worse than useless.
            let matchKey = foundInstalled[curated.id] != nil
                ? curated.id
                : foundInstalled.first {
                    Self.normalizedModelName($0.key) == Self.normalizedModelName(curated.id)
                }?.key
            if let matchKey, let installed = foundInstalled[matchKey] {
                let merged = LocalMLXModel(
                    id: curated.id,
                    name: curated.name,
                    description: curated.description,
                    sizeBytes: installed.sizeBytes ?? curated.sizeBytes,
                    parameterCount: curated.parameterCount,
                    quantization: curated.quantization,
                    modelType: installed.modelType ?? curated.modelType,
                    contextWindow: curated.contextWindow,
                    isDownloaded: true,
                    localDirectory: installed.localDirectory,
                    // The checkpoint on disk outranks the catalog. `curated.isVLM` is editorial
                    // metadata typed by hand, and Ornith's entry omits it — so it defaulted to
                    // false and overwrote the value just read from the model's own
                    // `config.json`, which carries a `vision_config`. Detection was fixed and
                    // then discarded one struct later: the model captured a screenshot and was
                    // told it could not look at it.
                    isVLM: installed.isVLM || curated.isVLM,
                    useCase: curated.useCase,
                    compatibility: curated.compatibility,
                    estimatedRAMGB: curated.estimatedRAMGB,
                    tags: curated.tags,
                    isTopPick: curated.isTopPick,
                    releasedAt: curated.releasedAt,
                    downloadCount: curated.downloadCount
                )
                finalCatalog.append(merged)
                foundInstalled.removeValue(forKey: matchKey)
            } else {
                finalCatalog.append(curated)
            }
        }

        // Add any additional discovered models from disk
        for (_, remaining) in foundInstalled {
            finalCatalog.append(remaining)
        }

        // Re-judge every verdict against the ratio the user set.
        //
        // Both sources upstream of here are built without settings — the curated catalog is a
        // `static`, and `buildModel` runs inside a recursive directory walk — so both carry a
        // verdict measured against the shipped default. This is the one place that has the user's
        // ratio and knows the list is about to be displayed, and `appState.localMLXModels` (fed
        // only from here) is what both the Local Models page and the MLX settings page render.
        let budgetRatio = settings.mlxGpuMemoryBudgetRatio
        return finalCatalog.map { $0.judged(atBudgetRatio: budgetRatio) }
    }

    private func scanDirectoryRecursively(root: URL, current: URL, depth: Int, results: inout [String: LocalMLXModel]) {
        guard depth < 6 else { return }
        let validation = validateModelFolder(directory: current)
        // Require real weight shards — config.json alone (incomplete download) is not enough.
        if validation.isLoadable && Self.isModelDirectoryComplete(current) {
            let repoId = deriveRepoId(root: root, modelDir: current)
            if results[repoId] == nil {
                results[repoId] = buildModel(repoId: repoId, directory: current)
            }
            return
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for item in contents {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                // Skip huge non-MLX trees (gturbo installers, blob stores, etc.)
                let name = item.lastPathComponent.lowercased()
                if name.hasSuffix(".gturbo") || name == "blobs" || name == "xet" || name == "manifests" {
                    continue
                }
                scanDirectoryRecursively(root: root, current: item, depth: depth + 1, results: &results)
            }
        }
    }

    private func deriveRepoId(root: URL, modelDir: URL) -> String {
        let name = modelDir.lastPathComponent
        if name.hasPrefix("models--") {
            let stripped = String(name.dropFirst(8))
            let parts = stripped.components(separatedBy: "--")
            if parts.count >= 2 {
                return "\(parts[0])/\(parts.dropFirst().joined(separator: "-"))"
            }
        }
        let parentName = modelDir.deletingLastPathComponent().lastPathComponent
        if !parentName.isEmpty && parentName != root.lastPathComponent && parentName != "models" && parentName != "snapshots" {
            return "\(parentName)/\(name)"
        }
        return name
    }

    private func buildModel(repoId: String, directory: URL) -> LocalMLXModel {
        var sizeBytes: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    sizeBytes += Int64(size)
                }
            }
        }

        var modelType = "mlx"
        var isVLM = false
        var contextWindow: Int? = 131_072

        let configURL = directory.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let mt = json["model_type"] as? String {
                modelType = mt
            }
            // Ask the config what it *has*, not what it is called.
            //
            // This used to match `model_type` against "vl", "vision", "pixtral", "mllama",
            // "gemma4" — a list of names, which fails the moment an architecture arrives that is
            // multimodal without saying so. Ornith reports `qwen3_5_moe` and carries a
            // `vision_config`, an `image_token_id` and a `text_config`: a vision model this
            // check called blind, so every screenshot sent to it would have been refused as
            // unviewable by the model that could actually have read it.
            isVLM = Self.declaresVisionSupport(config: json)
            if let declared = Self.declaredContextWindow(config: json) {
                contextWindow = declared
            }
        }

        let cleanName = repoId.split(separator: "/").last.map(String.init) ?? repoId
        let ramEstimate = sizeBytes > 0 ? (Double(sizeBytes) / (1024 * 1024 * 1024)) * 1.15 : 6.0
        let comp = Self.assessCompatibility(requiredRAMGB: ramEstimate)

        return LocalMLXModel(
            id: repoId,
            name: cleanName,
            description: "Locally installed MLX model at \(directory.lastPathComponent).",
            sizeBytes: sizeBytes > 0 ? sizeBytes : nil,
            parameterCount: extractParams(from: repoId),
            quantization: extractQuant(from: repoId),
            modelType: modelType,
            contextWindow: contextWindow,
            isDownloaded: true,
            localDirectory: directory.path,
            isVLM: isVLM,
            useCase: isVLM ? .vision : .general,
            compatibility: comp,
            estimatedRAMGB: ramEstimate,
            tags: ["Installed", "Local MLX"],
            isTopPick: false
        )
    }

    private func extractParams(from id: String) -> String? {
        let pattern = #"(?i)\b(\d+(?:\.\d+)?)\s*b\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(id.startIndex..., in: id)
        if let match = regex.firstMatch(in: id, range: range),
           let matchRange = Range(match.range, in: id) {
            return String(id[matchRange]).uppercased()
        }
        return nil
    }

    private func extractQuant(from id: String) -> String? {
        LocalMLXModel.quantizationLabel(fromId: id)
    }

    /// Download a model's weights so a chat turn can load them.
    ///
    /// Previously this shelled out to `huggingface-cli` — a Python tool that is not installed on a
    /// stock Mac, so the Download button failed outright here — and wrote to
    /// `~/.swiftopenwork/mlx_models/<org>--<repo>/`, a *different* directory from the one the chat
    /// loader's own download used. Two mechanisms, two destinations, one of them non-functional.
    /// There is now one: the in-process Hugging Face client, writing to the hub cache that
    /// `resolveLocalModelDirectory` already searches.
    public func pullModel(repoId: String, onProgress: @Sendable @escaping (Double, String) -> Void) async throws {
        try await NativeMLXService.shared.download(modelId: repoId, onProgress: onProgress)
    }

    /// Removes a downloaded model from disk.
    public func deleteModel(model: LocalMLXModel) throws {
        if let dir = model.localDirectory, FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.removeItem(atPath: dir)
        }
    }

    // MARK: - Daemon Server Lifecycle
    /// Guards the two below. Two turns can reach `ensureServerRunning` at once; without the lock
    /// both passed the `isServerStarting` check and each launched a server.
    private let serverLock = NSLock()
    private var serverProcess: Process? = nil
    private var isServerStarting: Bool = false

    /// Checks if a local MLX server is reachable on a specific host and port.
    public func isServerRunning(host: String = "127.0.0.1", port: Int = 8000) async -> Bool {
        let endpoint = (port == 11434) ? "http://\(host):\(port)/api/tags" : "http://\(host):\(port)/v1/models"
        guard let url = URL(string: endpoint) else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.0
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse {
                return (200...499).contains(http.statusCode)
            }
        } catch {}
        return false
    }

    /// Automatically starts or connects to the local Apple Silicon MLX inference server.
    /// Checks ports 8000 (oMLX/standard), 1337 (Osaurus), 11434 (Ollama), 1234 (LM Studio), 8080 (vMLX), and 5243 (GrizzyClaw).
    /// If none are running, auto-spawns standard `mlx_lm.server`, `omlx`, or `python3 -m mlx_lm.server`.
    public func ensureServerRunning(modelId: String? = nil, settings: AppSettings? = nil) async -> (success: Bool, message: String, activePort: Int) {
        // 1. First probe if any compatible MLX / local server is already running
        let probePorts = [8000, 1337, 11434, 1234, 8080, 5243]
        for p in probePorts {
            if await isServerRunning(port: p) {
                return (true, "Local inference server active on port \(p)", p)
            }
        }

        let claimed: Bool = serverLock.withLock {
            if isServerStarting { return false }
            isServerStarting = true
            return true
        }
        guard claimed else {
            // Wait up to 15 seconds for start in progress
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                for p in probePorts {
                    if await isServerRunning(port: p) {
                        return (true, "MLX server started successfully on port \(p)", p)
                    }
                }
            }
            return (false, "MLX server startup in progress...", 8000)
        }

        defer { serverLock.withLock { isServerStarting = false } }

        // Find binary or Python mlx-lm module
        let targetModel = modelId ?? "mlx-community/Qwen3.6-35B-A3B-8bit"
        
        // Comprehensive path search for Python/Homebrew/Conda/MLX environments
        let launchCommands = [
            "/opt/homebrew/bin/omlx serve --port 8000 --host 127.0.0.1 --hf-cache",
            "/usr/local/bin/omlx serve --port 8000 --host 127.0.0.1 --hf-cache",
            "omlx serve --port 8000 --host 127.0.0.1 --hf-cache",
            "/opt/homebrew/bin/mlx_lm.server --model '\(targetModel)' --port 8000 --host 127.0.0.1",
            "mlx_lm.server --model '\(targetModel)' --port 8000 --host 127.0.0.1",
            "/opt/homebrew/bin/python3 -m mlx_lm.server --model '\(targetModel)' --port 8000 --host 127.0.0.1",
            "/usr/local/bin/python3 -m mlx_lm.server --model '\(targetModel)' --port 8000 --host 127.0.0.1",
            "python3 -m mlx_lm.server --model '\(targetModel)' --port 8000 --host 127.0.0.1",
            "python -m mlx_lm.server --model '\(targetModel)' --port 8000 --host 127.0.0.1"
        ]

        for cmd in launchCommands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", cmd]
            process.environment = ShellEnvironment.standard()
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                serverLock.withLock { self.serverProcess = process }

                // Poll until server port opens (up to 20 seconds per attempt to allow model loading into memory)
                for _ in 0..<40 {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    for p in probePorts {
                        if await isServerRunning(port: p) {
                            return (true, "MLX server launched successfully on port \(p)", p)
                        }
                    }
                }
            } catch {
                continue
            }
        }

        // Final check across all probe ports
        for p in probePorts {
            if await isServerRunning(port: p) {
                return (true, "MLX server is running on port \(p)", p)
            }
        }

        return (false, "Could not start local MLX server automatically. Please ensure `omlx` or `mlx-lm` is installed (`pip install mlx-lm`), or run Osaurus in the background.", 8000)
    }
}

extension LocalMLXEngine: LocalServerLauncher {}
