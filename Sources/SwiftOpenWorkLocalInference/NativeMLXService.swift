import Foundation
#if canImport(MLXLMCommon) && canImport(MLXLLM) && canImport(MLXHuggingFace) && canImport(HuggingFace) && canImport(Tokenizers)
import MLX
import MLXLMCommon
import MLXLLM
import MLXVLM
import MLXHuggingFace
import HuggingFace
import Tokenizers
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

/// In-process Apple Silicon Metal MLX Inference Engine.
/// Matches GrizzyClaw and Osaurus architecture using `mlx-swift-lm` directly on GPU.
public final class NativeMLXService: LLMProviderClient, @unchecked Sendable {
    public static let shared = NativeMLXService()

    private var loadedContainers: [String: ModelContainer] = [:]
    private var recentLoadFailures: [String: Date] = [:]
    /// Loads already running. A load that overran its deadline keeps going, and the next turn
    /// waits on the same task instead of starting a second copy of a 48GB read.
    /// `token` is identity: a completing load must not install itself after `unload` / `deinit`
    /// has abandoned it and a newer load for the same id has started.
    private final class LoadToken: @unchecked Sendable {}
    private struct InFlightLoad {
        let token: LoadToken
        let task: Task<ModelContainer, Error>
    }
    private var inFlightLoads: [String: InFlightLoad] = [:]
    /// A live chat session and what it has already consumed, so a continuing conversation
    /// reuses its KV cache instead of re-prefilling the whole transcript every turn.
    private final class CachedChat {
        let session: ChatSession
        let key: MLXSessionReuse.Key
        var consumed: [MLXSessionReuse.Fingerprint]
        /// Tokens the KV cache holds: every prompt prefilled into it plus every reply generated.
        var contextTokens: Int

        init(session: ChatSession, key: MLXSessionReuse.Key, consumed: [MLXSessionReuse.Fingerprint]) {
            self.session = session
            self.key = key
            self.consumed = consumed
            self.contextTokens = 0
        }
    }

    /// Most recently used first. Only touched while holding `LocalGenerationGate`, and under
    /// `lock` for the eviction paths that run outside it.
    private var cachedChats: [CachedChat] = []

    /// Two, so a chat and an automation (or a lead and its sub-agent) can take turns without
    /// each rebuilding the other's cache. Each entry pins a KV cache in unified memory, which is
    /// why it is not more.
    public static let maxCachedChats = 2
    /// Generations still running, so quitting can stop them first (see `prepareForExit`).
    private var activeGenerations: [UUID: ActiveGeneration] = [:]
    private let lock = NSLock()

    private struct ActiveGeneration: @unchecked Sendable {
        let modelId: String
        let cancel: @Sendable () -> Void
        let join: @Sendable () async -> Void
    }

    private struct UncheckedSendable<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    /// What a finished (or stopped) generation produced.
    private struct ConsumedGeneration: Sendable {
        var tokens = 0
        var text = ""
        var toolCalls: [ToolCallInfo] = []
        var cancelled = false
        var promptTokenCount: Int?
        var generationTokenCount: Int?
        var generateTime: Double?
        var tokensPerSecond: Double?
    }

    /// How long returning from a stopped generation waits for MLX to actually stop.
    ///
    /// Cancellation is checked once per token, so this is normally a single token's work. A long
    /// prompt prefill does not check it and can overrun, in which case the call returns anyway,
    /// as it did before this wait existed.
    public static let generationJoinSeconds: TimeInterval = 15

    /// Don't retry a doomed load on every subsequent message.
    private static let failureCooldown: TimeInterval = 300

    /// Smallest load budget, however tiny the model.
    ///
    /// The budget is deliberately *not* a stall timer any more. Timing silence only works when the
    /// work reports progress, and reading a bundle off disk does not: `loadContainer(from:)` takes
    /// no progress handler, so the watchdog saw one tick at the start and then nothing for the
    /// whole load. A 46GB Llama-3.3-70B on an external volume loads in ~220s, which a 180s silence
    /// budget calls wedged — abandoning a load that was about to succeed.
    ///
    /// Size the budget by the bytes actually on disk instead (see `loadBudgetSeconds`). Overrunning
    /// costs only this one turn: the load keeps running and populates the cache, so the next turn
    /// is fast either way.
    private static let minimumLoadSeconds: TimeInterval = 180

    /// Bytes per second a load is assumed to manage, for sizing the budget.
    ///
    /// Pessimistic on purpose — slower than a spinning external disk. The budget is a ceiling on
    /// how long one turn waits, not a performance claim, so erring long costs nothing and erring
    /// short abandons work that would have finished.
    private static let assumedLoadBytesPerSecond: Double = 25_000_000

    /// How long this turn will wait for `modelId` to load, from the size of its weights.
    public static func loadBudgetSeconds(modelId: String, settings: AppSettings) -> TimeInterval {
        guard let dir = LocalMLXEngine.shared.resolveLocalModelDirectory(modelId: modelId, settings: settings)
        else { return minimumLoadSeconds }
        let bytes = Double(weightBytes(in: dir))
        return max(minimumLoadSeconds, bytes / assumedLoadBytesPerSecond)
    }

    /// Total size of the weight shards in a bundle directory.
    public static func weightBytes(in directory: URL) -> Int64 {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var total: Int64 = 0
        for name in names where name.hasSuffix(".safetensors") {
            let path = directory.appendingPathComponent(name).path
            if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }

    public init() {}

    deinit {
        // A test instance (or a discarded engine) must not leave GPU work and KV caches behind.
        abandonInFlightLoads()
        let active = lock.withLock { Array(activeGenerations.values) }
        active.forEach { $0.cancel() }
        lock.withLock {
            activeGenerations.removeAll()
            cachedChats.removeAll()
            loadedContainers.removeAll()
            recentLoadFailures.removeAll()
        }
    }

    public var cachedChatCount: Int {
        lock.withLock { cachedChats.count }
    }

    public var inFlightLoadCount: Int {
        lock.withLock { inFlightLoads.count }
    }

    /// Drop in-flight load tasks so a completing load cannot reinstall a container this instance
    /// has already abandoned. Cancels the tasks; does not wait.
    private func abandonInFlightLoads(modelId: String? = nil) {
        let tasks = lock.withLock { () -> [Task<ModelContainer, Error>] in
            if let modelId {
                return [inFlightLoads.removeValue(forKey: modelId)?.task].compactMap { $0 }
            }
            let all = inFlightLoads.values.map(\.task)
            inFlightLoads.removeAll()
            return all
        }
        tasks.forEach { $0.cancel() }
    }

    public var loadedModelIds: [String] {
        lock.withLock { Array(loadedContainers.keys).sorted() }
    }

    public func isModelLoaded(_ modelId: String) -> Bool {
        lock.withLock { loadedContainers[modelId] != nil }
    }

    /// Evict an in-process model from Metal/RAM so another can be loaded.
    @discardableResult
    public func unload(modelId: String) -> Bool {
        abandonInFlightLoads(modelId: modelId)
        let toCancel = lock.withLock { activeGenerations.values.filter { $0.modelId == modelId } }
        toCancel.forEach { $0.cancel() }
        let removed = lock.withLock { () -> Bool in
            for (id, generation) in activeGenerations where generation.modelId == modelId {
                activeGenerations[id] = nil
            }
            guard loadedContainers.removeValue(forKey: modelId) != nil else { return false }
            recentLoadFailures[modelId] = nil
            // A cached session holds the container too. Dropping only the dictionary entry left
            // the weights resident behind a UI that said they were gone.
            cachedChats.removeAll { $0.key.modelId == modelId }
            return true
        }
        if removed {
            MLX.Memory.clearCache()
            NotificationCenter.default.post(name: .mlxLoadedModelsDidChange, object: nil)
        }
        return removed
    }

    /// Evict every in-process MLX model currently held in memory.
    @discardableResult
    public func unloadAll() -> Int {
        abandonInFlightLoads()
        let toCancel = lock.withLock { Array(activeGenerations.values) }
        toCancel.forEach { $0.cancel() }
        let count = lock.withLock { () -> Int in
            let n = loadedContainers.count
            activeGenerations.removeAll()
            loadedContainers.removeAll()
            recentLoadFailures.removeAll()
            cachedChats.removeAll()
            return n
        }
        if count > 0 {
            MLX.Memory.clearCache()
            NotificationCenter.default.post(name: .mlxLoadedModelsDidChange, object: nil)
        }
        return count
    }

    public func testConnection(provider: ModelProvider) async throws -> Bool {
        return true
    }

    public func listModels(provider: ModelProvider) async throws -> [ModelInfo] {
        return provider.models
    }

    /// Run `model` on this Mac's GPU, in this process. Nothing else.
    ///
    /// This used to fall through to probing ports 1337, 8000, 8080, 11434, 1234 and 5243 for any
    /// HTTP server willing to answer, which meant a turn the user sent to the built-in engine
    /// could be served by Ollama, LM Studio, or whatever else happened to be listening — reported
    /// as if the built-in engine had produced it. A provider named "Apple Silicon (Built-in)"
    /// has to mean exactly one thing, so a failure here is now a failure, with the reason.
    ///
    /// Those backends are still fully available; they are separate providers in the picker,
    /// selected deliberately, reached through their own clients.
    public func streamChat(
        provider: ModelProvider,
        model: ModelInfo,
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort,
        tools: [SwiftOpenWorkCore.Tool],
        onChunk: @Sendable @escaping (LLMStreamChunk) -> Void
    ) async throws {
        try await streamInProcess(
            model: model,
            systemPrompt: systemPrompt,
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            tools: tools,
            onChunk: onChunk
        )
    }

    private func streamInProcess(
        model: ModelInfo,
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int,
        tools: [SwiftOpenWorkCore.Tool],
        onChunk: @Sendable @escaping (LLMStreamChunk) -> Void
    ) async throws {
        // Taken before the load as well as the generation: loading a different checkpoint evicts
        // the resident one, which must not happen underneath a generation that is using it.
        let label = LocalGenerationGate.claimLabel ?? "a chat turn"
        let ticket = try await LocalGenerationGate.shared.acquire(label: label) { holder in
            onChunk(LLMStreamChunk(deltaNotice: LocalGenerationGate.waitingNotice(behind: holder)))
        }
        // Declared first so it runs last, after the cache bookkeeping below has been recorded.
        defer { Task { await LocalGenerationGate.shared.release(ticket) } }
        try Task.checkCancellation()

        let container = try await getOrLoadContainer(modelId: model.id) { status in
            // A status chip, not reasoning. Loading a 50GB checkpoint needs to be visible so a
            // first run does not look like a hang, but it is the app's status, not the model's
            // thinking — and filed as reasoning it both polluted that transcript and could be
            // surfaced as the answer when a turn produced nothing else.
            onChunk(LLMStreamChunk(deltaNotice: status))
        }
        let sanitizedInstructions = sanitizeForHFChatTemplate(systemPrompt)
        let preparedMessages = mergeToolMessagesIntoFollowingUser(messages)
        // A VLM checkpoint takes images by URL, so nothing is re-encoded on this path. Whether
        // the loaded model can actually see is `isVLM`, detected from its own `config.json` at
        // discovery — a text-only model handed images would fail inside the chat template
        // rather than politely ignore them.
        let modelSeesImages = model.supportsVision
        var mlxMessages: [Chat.Message] = preparedMessages.map { m in
            let cleanContent = sanitizeForHFChatTemplate(m.content)
            let imageURLs: [UserInput.Image] = modelSeesImages
                ? ImageTransport.imageAttachments(in: m).map { .url(URL(fileURLWithPath: $0.path)) }
                : []
            switch m.role {
            case .user:
                return Chat.Message(role: .user, content: cleanContent, images: imageURLs)
            case .assistant:
                return Chat.Message(role: .assistant, content: cleanContent)
            case .system:
                return Chat.Message(role: .system, content: cleanContent)
            case .tool:
                // The merge above already labels tool output; this path only sees a stray
                // .tool message that never went through it.
                return Chat.Message(
                    role: .user,
                    content: cleanContent.hasPrefix("[Tool output]") ? cleanContent : "[Tool output]\n" + cleanContent,
                    images: imageURLs
                )
            }
        }

        if !mlxMessages.contains(where: { $0.role == Chat.Message.Role.user }) {
            let fallback = preparedMessages.last(where: { $0.role == .user })?.content
                ?? preparedMessages.last?.content
                ?? "Continue."
            let insertAt = mlxMessages.firstIndex(where: { $0.role != Chat.Message.Role.system }) ?? mlxMessages.count
            mlxMessages.insert(
                Chat.Message(role: .user, content: sanitizeForHFChatTemplate(fallback)),
                at: insertAt
            )
        }

        guard let last = mlxMessages.last else {
            return
        }

        let toolSpecs = Self.mlxToolSpecs(from: tools)
        let key = MLXSessionReuse.Key(
            modelId: model.id,
            instructions: sanitizedInstructions,
            toolNames: tools.map(\.name)
        )
        let fingerprints = mlxMessages.map {
            MLXSessionReuse.Fingerprint(
                role: String(describing: $0.role),
                content: $0.content,
                hasAttachments: !$0.images.isEmpty || !$0.videos.isEmpty || !$0.audios.isEmpty
            )
        }

        let selection = lock.withLock {
            MLXSessionReuse.select(
                candidates: cachedChats.map { .init(key: $0.key, consumed: $0.consumed) },
                incomingKey: key,
                incoming: fingerprints
            )
        }

        let entry: CachedChat
        let contextBefore: Int
        let stream: AsyncThrowingStream<Generation, Error>

        if let index = selection.index, case .advance(let new) = selection.decision {
            // Continue the live session: only the messages it has not seen are prefilled.
            entry = lock.withLock {
                let found = cachedChats.remove(at: index)
                cachedChats.insert(found, at: 0)
                return found
            }
            contextBefore = entry.contextTokens
            let appended = Array(mlxMessages[new.startIndex...])
            stream = entry.session.streamDetails(to: appended)
            lock.withLock { entry.consumed = fingerprints }
        } else {
            if case .rebuild(let reason) = selection.decision, reason != "no cached session" {
                // Say what changed, not only where: the cause is usually a folded tool result or
                // a rewritten message, and the position alone cannot tell them apart.
                let previous = lock.withLock { cachedChats.first { $0.key == key }?.consumed }
                let detail = previous
                    .flatMap { MLXSessionReuse.describeDivergence(consumed: $0, incoming: fingerprints) }
                    .map { " — \($0)" } ?? ""
                onChunk(LLMStreamChunk(deltaNotice: "Context cache reset: \(reason)\(detail)"))
            }
            let history = MLXSessionReuse.sessionHistory(
                system: sanitizedInstructions.isEmpty ? nil : Chat.Message.system(sanitizedInstructions),
                earlierMessages: Array(mlxMessages.dropLast())
            )
            let fresh = ChatSession(
                container,
                history: history,
                generateParameters: Self.generateParameters(
                    maxTokens: maxTokens,
                    temperature: temperature
                ),
                tools: toolSpecs.isEmpty ? nil : toolSpecs
                // No toolDispatch — AgentRunner owns approval + MCP execution (Radiant shape).
                // streamDetails surfaces .toolCall for the outer loop.
            )
            stream = fresh.streamDetails(
                to: last.content,
                role: last.role,
                images: last.images,
                videos: [],
                audios: []
            )
            entry = CachedChat(session: fresh, key: key, consumed: fingerprints)
            contextBefore = 0
            lock.withLock {
                MLXSessionReuse.remember(
                    entry,
                    in: &cachedChats,
                    maxCount: Self.maxCachedChats,
                    droppingStale: {
                        $0.key.modelId == key.modelId && $0.key.instructions == key.instructions
                    }
                )
            }
        }

        // Ornith-class templates end their generation prompt with a bare `<think>`, so the model
        // generates reasoning with no opening tag and is meant to close with `</think>`. When it
        // forgets, the text carries no tags at all and `AssistantContentSanitizer` — correctly —
        // will not guess, so chain-of-thought reaches the user as the answer. Knowing the
        // template opened the block makes that determinate instead of a guess.
        let preOpensThinking = LocalMLXEngine.shared
            .resolveLocalModelDirectory(modelId: model.id, settings: PersistenceManager.shared.loadSettings())
            .map { ReasoningChannel.templatePreOpensThinking(modelDirectory: $0) } ?? false
        let splitter = ReasoningChannel.StreamSplitter(startsInsideReasoning: preOpensThinking)

        // The stream is read in a task this service owns, and the call does not return until MLX
        // has stopped. Stopping to read only *asks* the generation to stop; it keeps evaluating on
        // the GPU for up to a token, or through a whole prefill. A caller that returned first
        // could quit the process meanwhile, and `exit` then tears down MLX's scheduler and
        // compiler cache under the running evaluation: SIGSEGV or a Metal assertion.
        let consumer = Task { () async throws -> ConsumedGeneration in
            try await Self.consume(stream, splitter: splitter, onChunk: onChunk)
        }
        let generationId = UUID()
        let sessionBox = UncheckedSendable(entry.session)
        let join: @Sendable () async -> Void = {
            _ = try? await consumer.value
            await sessionBox.value.synchronize()
        }
        lock.withLock {
            activeGenerations[generationId] = ActiveGeneration(
                modelId: model.id,
                cancel: { consumer.cancel() },
                join: join
            )
        }

        let outcome: Result<ConsumedGeneration, Error>
        do {
            outcome = .success(try await withTaskCancellationHandler {
                try await consumer.value
            } onCancel: {
                consumer.cancel()
            })
        } catch {
            outcome = .failure(error)
        }
        _ = try? await AsyncDeadline.wait(for: Task<Void, Error> { await join() }, seconds: Self.generationJoinSeconds)
        lock.withLock { activeGenerations[generationId] = nil }

        let consumed: ConsumedGeneration
        switch outcome {
        case .failure(let error):
            lock.withLock { cachedChats.removeAll { $0 === entry } }
            throw error
        case .success(let value):
            consumed = value
        }
        let completedNormally = !consumed.cancelled && !Task.isCancelled
        lock.withLock {
            if completedNormally {
                entry.consumed.append(
                    MLXSessionReuse.Fingerprint(
                        role: "assistant",
                        content: consumed.text,
                        isGeneratedReply: true
                    )
                )
                entry.contextTokens = MLXSessionReuse.contextTokens(
                    cachedBefore: contextBefore,
                    prefilled: (consumed.promptTokenCount ?? 0)
                        + (consumed.generationTokenCount ?? consumed.tokens)
                )
            } else {
                cachedChats.removeAll { $0 === entry }
            }
        }

        // A block the model never closed is reasoning, not an answer.
        let tail = splitter.flush()
        if !tail.visible.isEmpty || !tail.reasoning.isEmpty {
            onChunk(LLMStreamChunk(
                deltaText: tail.visible,
                deltaReasoning: tail.reasoning.isEmpty ? nil : tail.reasoning
            ))
        }

        onChunk(LLMStreamChunk(
            isFinished: true,
            promptTokens: consumed.promptTokenCount.map {
                MLXSessionReuse.contextTokens(cachedBefore: contextBefore, prefilled: $0)
            },
            completionTokens: consumed.generationTokenCount ?? consumed.tokens,
            generationTokensPerSecond: {
                guard let tps = consumed.tokensPerSecond,
                      let generateTime = consumed.generateTime,
                      let count = consumed.generationTokenCount,
                      generateTime > 0, count > 0 else { return nil }
                return tps
            }(),
            toolCalls: consumed.toolCalls
        ))
    }

    /// Read a generation stream to its end, or until the reading task is cancelled.
    private static func consume(
        _ stream: AsyncThrowingStream<Generation, Error>,
        splitter: ReasoningChannel.StreamSplitter,
        onChunk: @Sendable @escaping (LLMStreamChunk) -> Void
    ) async throws -> ConsumedGeneration {
        var result = ConsumedGeneration()
        for try await generation in stream {
            if Task.isCancelled {
                result.cancelled = true
                break
            }
            switch generation {
            case .chunk(let piece):
                if !piece.isEmpty {
                    result.tokens += 1
                    result.text += piece
                    let split = splitter.consume(piece)
                    if !split.visible.isEmpty || !split.reasoning.isEmpty {
                        onChunk(LLMStreamChunk(
                            deltaText: split.visible,
                            deltaReasoning: split.reasoning.isEmpty ? nil : split.reasoning
                        ))
                    }
                }
            case .toolCall(let call):
                let argsObject = call.function.arguments.mapValues { $0.anyValue }
                let argsJson: String
                if JSONSerialization.isValidJSONObject(argsObject),
                   let data = try? JSONSerialization.data(withJSONObject: argsObject),
                   let s = String(data: data, encoding: .utf8) {
                    argsJson = s
                } else {
                    argsJson = "{}"
                }
                let info = ToolCallInfo(
                    id: call.id ?? UUID().uuidString,
                    toolName: call.function.name,
                    argumentsJson: argsJson,
                    status: .running
                )
                result.toolCalls.append(info)
                onChunk(LLMStreamChunk(toolCalls: [info]))
            case .info(let info):
                result.promptTokenCount = info.promptTokenCount
                result.generationTokenCount = info.generationTokenCount
                result.generateTime = info.generateTime
                result.tokensPerSecond = info.tokensPerSecond
            @unknown default:
                break
            }
        }
        if Task.isCancelled { result.cancelled = true }
        return result
    }

    /// Stop every running generation and wait, up to `timeout`, for MLX to finish its work.
    ///
    /// For `applicationWillTerminate`. `exit` destroys MLX's C++ globals while other threads keep
    /// running, so a reply still generating at quit crashes the process on its way out. Returns
    /// false if something was still running when the wait gave up.
    @discardableResult
    public func prepareForExit(timeout: TimeInterval = 3) -> Bool {
        let active = lock.withLock { Array(activeGenerations.values) }
        guard !active.isEmpty else { return true }
        active.forEach { $0.cancel() }
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            for generation in active {
                await generation.join()
            }
            finished.signal()
        }
        return finished.wait(timeout: .now() + timeout) == .success
    }

    public var activeGenerationCount: Int {
        lock.withLock { activeGenerations.count }
    }

    public enum OneShotError: LocalizedError {
        /// Something else is generating; a one-shot never waits.
        case engineBusy(String)
        /// A different model is resident, and loading this one would evict it.
        case wouldEvict(loaded: String)

        public var errorDescription: String? {
            switch self {
            case .engineBusy(let holder): return "The local model is busy with \(holder)."
            case .wouldEvict(let loaded): return "\(loaded) is loaded; suggestions will not swap it out."
            }
        }
    }

    /// A single short generation that leaves the conversation caches alone.
    ///
    /// For editor suggestions: it never queues (an agent turn must not wait behind a guess at the
    /// next line), never evicts a different resident model, never touches `cachedChats` (so it
    /// cannot throw away a chat's KV cache), and asks the template not to think — a reasoning model
    /// otherwise spends its whole budget deliberating before writing a single character.
    public func oneShot(
        modelId: String,
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Double,
        onVisibleText: @Sendable @escaping (String) -> Void,
        shouldStop: @Sendable @escaping () -> Bool = { false }
    ) async throws {
        let loaded = loadedModelIds
        if let resident = loaded.first, resident != modelId {
            throw OneShotError.wouldEvict(loaded: resident)
        }
        guard let ticket = await LocalGenerationGate.shared.tryAcquire(label: "editor suggestions") else {
            throw OneShotError.engineBusy(await LocalGenerationGate.shared.currentHolder ?? "another generation")
        }
        defer { Task { await LocalGenerationGate.shared.release(ticket) } }
        try Task.checkCancellation()

        let container = try await getOrLoadContainer(modelId: modelId) { _ in }
        let session = ChatSession(
            container,
            history: [Chat.Message.system(sanitizeForHFChatTemplate(system))],
            generateParameters: Self.generateParameters(maxTokens: maxTokens, temperature: temperature),
            additionalContext: ["enable_thinking": false]
        )
        // Thinking is switched off, so the template does not pre-open a reasoning block; tags the
        // model writes anyway are still split out.
        let splitter = ReasoningChannel.StreamSplitter(startsInsideReasoning: false)
        let stream = session.streamDetails(to: sanitizeForHFChatTemplate(user), role: .user, images: [], videos: [], audios: [])
        let consumer = Task {
            for try await generation in stream {
                if Task.isCancelled { break }
                if case .chunk(let piece) = generation, !piece.isEmpty {
                    let split = splitter.consume(piece)
                    if !split.visible.isEmpty {
                        onVisibleText(split.visible)
                        // Stop as soon as the suggestion is complete. Breaking out ends the stream,
                        // which cancels the generation behind it.
                        if split.visible.contains("\n"), shouldStop() { break }
                    }
                }
            }
            let tail = splitter.flush()
            if !tail.visible.isEmpty { onVisibleText(tail.visible) }
        }
        let generationId = UUID()
        let sessionBox = UncheckedSendable(session)
        let join: @Sendable () async -> Void = {
            _ = try? await consumer.value
            await sessionBox.value.synchronize()
        }
        lock.withLock {
            activeGenerations[generationId] = ActiveGeneration(
                modelId: modelId,
                cancel: { consumer.cancel() },
                join: join
            )
        }
        defer { lock.withLock { activeGenerations[generationId] = nil } }
        try await withTaskCancellationHandler {
            try await consumer.value
        } onCancel: {
            consumer.cancel()
        }
        _ = try? await AsyncDeadline.wait(for: Task<Void, Error> { await join() }, seconds: Self.generationJoinSeconds)
    }

    /// Map SwiftOpenWork `Tool` models into mlx-swift-lm `ToolSpec` dictionaries.
    /// Sampling parameters for the in-process path.
    ///
    /// This path previously passed only maxTokens and temperature, so every penalty setting was
    /// silently inert — including `autoAdjustPenaltiesForLocalModels`, which exists precisely for
    /// local models and which the Ollama and OpenAI paths both honour. Repetition penalties are
    /// what stop a local model looping, so the one path most in need of them had none.
    public static func generateParameters(
        maxTokens: Int,
        temperature: Double,
        settings: AppSettings? = nil
    ) -> GenerateParameters {
        let s = settings ?? PersistenceManager.shared.loadSettings()
        let boost = s.autoAdjustPenaltiesForLocalModels
        // Same floors the Ollama path applies for local endpoints.
        let repetition = boost ? max(1.20, s.defaultRepeatPenalty) : s.defaultRepeatPenalty
        let presence = boost ? max(0.30, s.defaultPresencePenalty) : s.defaultPresencePenalty
        let frequency = boost ? max(0.30, s.defaultFrequencyPenalty) : s.defaultFrequencyPenalty

        return GenerateParameters(
            maxTokens: maxTokens > 0 ? maxTokens : 4096,
            temperature: Float(temperature),
            topP: Float(s.defaultTopP > 0 ? s.defaultTopP : 1.0),
            // A penalty of 1.0 / 0.0 is a no-op; pass nil so MLX skips the processor entirely.
            repetitionPenalty: repetition > 1.0 ? Float(repetition) : nil,
            presencePenalty: presence > 0 ? Float(presence) : nil,
            frequencyPenalty: frequency > 0 ? Float(frequency) : nil
        )
    }

    private static func mlxToolSpecs(from tools: [SwiftOpenWorkCore.Tool]) -> [ToolSpec] {
        tools.filter(\.isEnabled).compactMap { tool -> ToolSpec? in
            var parameters: [String: any Sendable] = [
                "type": "object",
                "properties": [String: any Sendable]()
            ]
            if let data = tool.parametersJsonSchema.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               !obj.isEmpty {
                parameters = toSendableDict(obj)
            }
            return [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": parameters
                ] as [String: any Sendable]
            ]
        }
    }

    private static func toSendableDict(_ dict: [String: Any]) -> [String: any Sendable] {
        var out: [String: any Sendable] = [:]
        for (k, v) in dict {
            out[k] = toSendable(v)
        }
        return out
    }

    private static func toSendable(_ value: Any) -> any Sendable {
        switch value {
        case let s as String: return s
        case let i as Int: return i
        case let d as Double: return d
        case let b as Bool: return b
        case let a as [Any]: return a.map { toSendable($0) }
        case let d as [String: Any]: return toSendableDict(d)
        case let n as NSNumber:
            // Distinguish Bool boxed as NSNumber
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue
            }
            if n.doubleValue.rounded() == n.doubleValue,
               abs(n.doubleValue) < Double(Int.max) {
                return n.intValue
            }
            return n.doubleValue
        default:
            return String(describing: value)
        }
    }

    /// Start loading `modelId` into memory without waiting for it.
    ///
    /// The first turn against a large local model pays the whole load — minutes, for a 35GB
    /// checkpoint — while the user watches a spinner. Doing it at launch, when they are not
    /// waiting on an answer, moves that cost somewhere it does not block anything.
    ///
    /// Fire-and-forget on purpose: a failure here is not worth surfacing, because nothing has been
    /// asked for yet, and the real request will report it properly. `getOrLoadContainer` already
    /// shares one in-flight load per model, so a turn starting mid-preload joins it rather than
    /// loading a second copy.
    public func preload(modelId: String) {
        guard !modelId.isEmpty else { return }
        guard lock.withLock({ loadedContainers[modelId] == nil && inFlightLoads[modelId] == nil }) else { return }
        Task.detached(priority: .utility) { [weak self] in
            _ = try? await self?.getOrLoadContainer(modelId: modelId, onProgress: { _ in })
        }
    }

    private func getOrLoadContainer(
        modelId: String,
        onProgress: @Sendable @escaping (String) -> Void
    ) async throws -> ModelContainer {
        if let existing = lock.withLock({ loadedContainers[modelId] }) {
            return existing
        }

        if let failedAt = lock.withLock({ recentLoadFailures[modelId] }),
           Date().timeIntervalSince(failedAt) < Self.failureCooldown {
            throw NSError(
                domain: "NativeMLXService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Skipping in-process MLX for '\(modelId)': a load attempt failed or timed out recently. Download it from the Local Models tab, or wait a few minutes before retrying."]
            )
        }

        // One load per model, shared by every caller. MLX's loader never checks for cancellation,
        // so racing it inside a task group blocked on the load it was meant to abandon: the
        // "falling back for this turn" message could not be honoured, and a 48GB read hung the
        // turn instead. The load now runs on its own task, outlives the deadline, and caches
        // itself when it finishes — so overrunning once makes the next turn fast rather than
        // starting over.
        let clock = AsyncDeadline.ProgressClock()
        let budget = Self.loadBudgetSeconds(
            modelId: modelId,
            settings: PersistenceManager.shared.loadSettings()
        )

        let task: Task<ModelContainer, Error> = lock.withLock {
            if let existing = inFlightLoads[modelId] { return existing.task }
            let token = LoadToken()
            let created = Task<ModelContainer, Error> { [weak self] in
                guard let self else { throw CancellationError() }
                do {
                    let container = try await self.loadContainerFromDiskOrDownload(
                        modelId: modelId, onProgress: onProgress
                    )
                    let installed = self.lock.withLock { () -> Bool in
                        // Abandoned (unload/deinit) or superseded by a newer load: drop the result.
                        guard self.inFlightLoads[modelId]?.token === token else { return false }
                        self.loadedContainers[modelId] = container
                        self.recentLoadFailures[modelId] = nil
                        self.inFlightLoads[modelId] = nil
                        return true
                    }
                    if installed {
                        NotificationCenter.default.post(name: .mlxLoadedModelsDidChange, object: nil)
                    }
                    return container
                } catch {
                    self.lock.withLock {
                        guard self.inFlightLoads[modelId]?.token === token else { return }
                        self.recentLoadFailures[modelId] = Date()
                        self.inFlightLoads[modelId] = nil
                    }
                    throw error
                }
            }
            inFlightLoads[modelId] = InFlightLoad(token: token, task: created)
            return created
        }

        // Reading tens of gigabytes is silent, so say so periodically: without this the user
        // watches an idle spinner for minutes with no way to tell loading from hanging. The
        // heartbeat reports status only — it deliberately does not touch the clock, or the budget
        // below could never expire.
        let heartbeat = Task.detached(priority: .utility) {
            let started = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { return }
                onProgress("Loading \(modelId) — \(Int(Date().timeIntervalSince(started)))s elapsed")
            }
        }
        defer { heartbeat.cancel() }

        do {
            return try await AsyncDeadline.wait(
                for: task,
                stalledAfter: budget,
                clock: clock
            )
        } catch is AsyncDeadline.TimedOut {
            // Deliberately not recorded as a failure: the load is still running and will be
            // waiting in the cache shortly.
            throw NSError(
                domain: "NativeMLXService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Loading '\(modelId)' is taking longer than \(Int(budget))s. It is still running in the background — this turn falls back; try again once it finishes."]
            )
        }
    }

    private func loadContainerFromDiskOrDownload(
        modelId: String,
        onProgress: @Sendable @escaping (String) -> Void
    ) async throws -> ModelContainer {
        let settings = PersistenceManager.shared.loadSettings()
        let tokenizerLoader = #huggingFaceTokenizerLoader()

        // Prefer an already-complete directory from the shared model library / other known roots.
        guard let localDir = LocalMLXEngine.shared.resolveLocalModelDirectory(modelId: modelId, settings: settings) else {
            // A chat turn never downloads. This used to fall through to a Hugging Face fetch, so
            // asking a 37GB model to say hello started a 37GB download behind a status chip that
            // said "Loading MLX weights: 20%" — indistinguishable from loading a model already on
            // disk, with no size, no ETA, and no way to tell it apart from a hang. Worse, the
            // weights were usually already present somewhere the root list did not look, so the
            // download was pure waste.
            //
            // Downloading is now an explicit action in Local Models, where it has a real progress
            // bar and can be cancelled. This path only reports what it could not find, and where
            // it looked.
            throw Self.modelNotDownloadedError(modelId: modelId, settings: settings)
        }

        // One model resident at a time. Loading a second multi-gigabyte checkpoint beside the
        // first is the quickest way to exhaust unified memory on a machine that can just barely
        // hold one — the same policy GrizzyBot's generator applies.
        evictOtherModels(keeping: modelId)
        Self.applyMemoryPolicy(budgetRatio: settings.mlxGpuMemoryBudgetRatio)

        // Pick the factory that matches the checkpoint.
        //
        // Everything used to load through `LLMModelFactory`, which builds a **text-only**
        // pipeline: no vision tower, no image processor. Images handed to it in
        // `Chat.Message.images` are dropped without a word, so a vision model captured a
        // screenshot, was told it was attached, and then reasoned its way around never having
        // seen it. `MLXVLM` was not even linked.
        let usesVision = (try? Data(contentsOf: localDir.appendingPathComponent("config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .map { LocalMLXEngine.declaresVisionSupport(config: $0) } ?? false

        onProgress("Loading \(modelId) from \(localDir.path)\(usesVision ? " (vision)" : "")")
        if usesVision {
            return try await VLMModelFactory.shared.loadContainer(
                from: localDir,
                using: tokenizerLoader
            )
        }
        return try await LLMModelFactory.shared.loadContainer(
            from: localDir,
            using: tokenizerLoader
        )
    }

    /// Drop every resident container except `modelId` and release its GPU buffers.
    private func evictOtherModels(keeping modelId: String) {
        let evicted = lock.withLock { () -> [String] in
            let stale = loadedContainers.keys.filter { $0 != modelId }
            for key in stale { loadedContainers[key] = nil }
            if !stale.isEmpty {
                // Cached sessions for a model that is no longer resident would keep it alive.
                cachedChats.removeAll { $0.key.modelId != modelId }
            }
            return stale
        }
        guard !evicted.isEmpty else { return }
        MLX.Memory.clearCache()
        NotificationCenter.default.post(name: .mlxLoadedModelsDidChange, object: nil)
    }

    /// Cap MLX's buffer cache so a resident model does not squeeze the rest of the machine.
    ///
    /// `budgetRatio` is the user's "GPU Memory Budget Ratio". This used to be a hardcoded 0.5
    /// while the MLX settings page rendered `physicalRAM * ratio` in green as the "Safe GPU
    /// Memory Budget" and ProvidersView repeated it — so the slider moved a number nothing read.
    /// It went unnoticed because the setting's default (0.75) matched a *different* hardcode in
    /// `assessCompatibility`, which made the two readouts agree until someone moved the slider.
    public static func applyMemoryPolicy(budgetRatio: Double) {
        MLX.Memory.cacheLimit = Int(
            Double(ProcessInfo.processInfo.physicalMemory)
                * LocalMLXEngine.clampedBudgetRatio(budgetRatio)
        )
    }

    /// Where in-process downloads land. Also a `knownMLXSearchRoots` entry, so anything fetched
    /// here resolves on the next turn without a rescan.
    public static var downloadCacheRoot: URL {
        AppIdentity.homeDataDirectory
            .appendingPathComponent("mlx_models/hub", isDirectory: true)
    }

    /// Download `modelId`'s weights from Hugging Face into the app's own hub cache.
    ///
    /// This replaces a shell-out to `huggingface-cli`, which is a Python tool that is simply not
    /// installed on most Macs — so the Download button in Local Models could not succeed here at
    /// all, and its progress bar was three hardcoded numbers (5%, 40%, 100%) rather than anything
    /// measured. Using the same `HubClient` the loader already depends on means one mechanism, one
    /// destination, real byte progress, and resume on a retry.
    public func download(
        modelId: String,
        onProgress: @Sendable @escaping (Double, String) -> Void
    ) async throws {
        let root = Self.downloadCacheRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hubClient = HubClient(cache: HubCache(cacheDirectory: root))
        let downloader = #hubDownloader(hubClient)

        onProgress(0, "Resolving \(modelId)…")
        do {
            _ = try await LLMModelFactory.shared.loadContainer(
                from: downloader,
                using: #huggingFaceTokenizerLoader(),
                configuration: ModelConfiguration(id: modelId, revision: "main"),
                progressHandler: { progress in
                    let fraction = min(1, max(0, progress.fractionCompleted))
                    onProgress(fraction, "Downloading \(modelId) — \(Int((fraction * 100).rounded()))%")
                }
            )
        } catch {
            throw Self.describeDownloadFailure(error, modelId: modelId)
        }
        onProgress(1, "Downloaded \(modelId)")

        // The factory loaded the model to prove the download is usable; do not keep 37GB resident
        // just because the user pressed Download.
        MLX.Memory.clearCache()
    }

    /// Explain that the weights are not on this Mac, and name every place that was searched.
    ///
    /// Naming the roots is the point: the failure that produced this message was a model sitting
    /// complete on an attached volume that the root list did not include, and nothing on screen
    /// could have told the user that.
    public static func modelNotDownloadedError(modelId: String, settings: AppSettings) -> Error {
        let roots = LocalMLXEngine.knownMLXSearchRoots(settings: settings)
        let searched = roots.isEmpty
            ? "  (no model folders exist on this Mac yet)"
            : roots.map { "  • \($0.path)" }.joined(separator: "\n")

        var message = """
        `\(modelId)` is not downloaded on this Mac.

        Searched:
        \(searched)
        """

        if let incomplete = findIncompleteModelDirectory(modelId: modelId, settings: settings) {
            message += """


            A partial download is present at \(incomplete.path) — weight shards are missing or \
            empty. Resume it from Local Models.
            """
        }

        let installed = LocalMLXEngine.shared
            .scanInstalledModels(settings: settings)
            .filter(\.isDownloaded)
            .map(\.id)
            .sorted()
        if !installed.isEmpty {
            let listed = installed.prefix(8).map { "  • \($0)" }.joined(separator: "\n")
            let more = installed.count > 8 ? "\n  … and \(installed.count - 8) more" : ""
            message += """


            Ready to run right now:
            \(listed)\(more)
            """
        }

        message += """


        Open Local Models to download `\(modelId)`, add the folder that holds it, or pick one of \
        the models above.
        """

        return NSError(
            domain: "NativeMLXService",
            code: 12,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// Turn a Hugging Face download failure into something the user can act on.
    ///
    /// The raw error is `The operation couldn't be completed. (HuggingFace.HTTPClientError error
    /// 1.)`, which names neither the repo nor the reason. In the case that produced it, the repo
    /// simply did not exist — the app's own curated catalog held an id that 401s — and the user had
    /// no way to tell that from a network problem or a half-finished download.
    public static func describeDownloadFailure(_ error: Error, modelId: String) -> Error {
        let raw = error.localizedDescription
        let nsError = error as NSError

        // Hugging Face answers 401 for a repo that does not exist as well as one that is private,
        // so both possibilities have to be offered rather than asserting the wrong one.
        let looksLikeMissingRepo = raw.contains("HTTPClientError")
            || nsError.code == 401 || nsError.code == 403 || nsError.code == 404

        let offline = (error as? URLError)?.code == .notConnectedToInternet
            || (error as? URLError)?.code == .cannotFindHost

        let explanation: String
        if offline {
            explanation = "This Mac appears to be offline, so the weights could not be fetched."
        } else if looksLikeMissingRepo {
            explanation = """
            Hugging Face would not serve `\(modelId)`. That repo is either missing, renamed, or \
            private — Hugging Face answers the same way for all three.

            Check the id at https://huggingface.co/\(modelId), or pick a model that is already \
            downloaded in Local Models.
            """
        } else {
            explanation = "The download failed: \(raw)"
        }

        return NSError(
            domain: "NativeMLXService",
            code: 13,
            userInfo: [
                NSLocalizedDescriptionKey: explanation,
                NSUnderlyingErrorKey: error
            ]
        )
    }

    private static func findIncompleteModelDirectory(modelId: String, settings: AppSettings) -> URL? {
        let roots = LocalMLXEngine.knownMLXSearchRoots(settings: settings)
        let sanitizedId = modelId.replacingOccurrences(of: "/", with: "--")
        for base in roots {
            let candidates = [
                base.appendingPathComponent(modelId),
                base.appendingPathComponent(sanitizedId),
                base.appendingPathComponent("models").appendingPathComponent(modelId),
                base.appendingPathComponent("models").appendingPathComponent(sanitizedId)
            ]
            for candidate in candidates {
                let configPath = candidate.appendingPathComponent("config.json").path
                if FileManager.default.fileExists(atPath: configPath),
                   !LocalMLXEngine.isModelDirectoryComplete(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// `config.json` alone is not proof a model is usable — an interrupted or cancelled download
    /// (including one killed by our own load timeout) can leave config.json and a handful of small
    /// metadata files on disk while most or all of the multi-gigabyte weight shards are missing.
    public static func isModelDirectoryComplete(_ dir: URL) -> Bool {
        LocalMLXEngine.isModelDirectoryComplete(dir)
    }

    private func sanitizeForHFChatTemplate(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "{{", with: "{ {")
        s = s.replacingOccurrences(of: "{%", with: "{ %")
        return s
    }

    /// Render tool results as their own user messages.
    ///
    /// Chat templates have no `tool` role, so results must arrive as user turns. They are emitted
    /// standalone and never folded into the message that follows, which is what makes the
    /// rendered transcript **append-only**: a result reads identically whether or not something
    /// comes after it.
    ///
    /// The previous version merged a run of tool results into the *next* user message, so the
    /// same result rendered one way while trailing and another once a user message landed after
    /// it. That silently rewrote earlier entries on every call, which defeated KV cache reuse
    /// (`MLXSessionReuse` correctly saw the prefix change and rebuilt) and made prompt caching
    /// impossible in principle, not just here.
    ///
    /// Consecutive results are still combined with each other — that run is complete once it ends,
    /// so combining them does not depend on anything later.
    private func mergeToolMessagesIntoFollowingUser(_ messages: [ChatMessage]) -> [ChatMessage] {
        guard !messages.isEmpty else { return messages }
        var out: [ChatMessage] = []
        var i = messages.startIndex
        while i < messages.endIndex {
            let m = messages[i]
            if m.role != .tool {
                out.append(m)
                i = messages.index(after: i)
                continue
            }
            var combined = ""
            // Attachments have to be carried across the merge, or a screenshot a tool just took
            // is discarded on the way to the model — the exact failure this transport exists to
            // remove, reintroduced one function later.
            var carriedAttachments: [MessageAttachment] = []
            while i < messages.endIndex, messages[i].role == .tool {
                if !combined.isEmpty { combined += "\n\n" }
                combined += messages[i].content
                carriedAttachments.append(contentsOf: messages[i].attachments)
                i = messages.index(after: i)
            }
            out.append(ChatMessage(
                role: .user,
                content: "[Tool output]\n" + combined,
                attachments: carriedAttachments
            ))
        }
        return out
    }
}
#else
/// Fallback client when MLX SPM packages are not linked in the Xcode app target.
/// Prefers any already-running local OpenAI-compatible server; otherwise uses MockLLMService
/// so prompts still complete (tools/automations) instead of failing with a connection error.
public final class NativeMLXService: LLMProviderClient, @unchecked Sendable {
    public static let shared = NativeMLXService()
    public init() {}

    public var loadedModelIds: [String] { [] }
    public func isModelLoaded(_ modelId: String) -> Bool { false }
    @discardableResult public func unload(modelId: String) -> Bool { false }
    @discardableResult public func unloadAll() -> Int { 0 }
    @discardableResult public func prepareForExit(timeout: TimeInterval = 3) -> Bool { true }
    public func preload(modelId: String) {}
    public var cachedChatCount: Int { 0 }
    public var inFlightLoadCount: Int { 0 }
    public var activeGenerationCount: Int { 0 }

    public static var downloadCacheRoot: URL {
        AppIdentity.homeDataDirectory
            .appendingPathComponent("mlx_models/hub", isDirectory: true)
    }

    public func download(
        modelId: String,
        onProgress: @Sendable @escaping (Double, String) -> Void
    ) async throws {
        throw NSError(
            domain: "NativeMLXService",
            code: 14,
            userInfo: [NSLocalizedDescriptionKey: "Built-in MLX packages are not linked in this build, so `\(modelId)` cannot be downloaded here. Rebuild with the MLX SPM packages linked, or fetch the weights with another tool and add the folder in Local Models."]
        )
    }

    public func testConnection(provider: ModelProvider) async throws -> Bool { return true }
    public func listModels(provider: ModelProvider) async throws -> [ModelInfo] { return provider.models }

    public func oneShot(
        modelId: String,
        system: String,
        user: String,
        maxTokens: Int,
        temperature: Double,
        onVisibleText: @Sendable @escaping (String) -> Void,
        shouldStop: @Sendable @escaping () -> Bool = { false }
    ) async throws {
        throw NSError(domain: "NativeMLXService", code: 11, userInfo: [NSLocalizedDescriptionKey: "The MLX packages are not linked into this build."])
    }

    /// Without the MLX packages there is no in-process engine, and the built-in provider means
    /// nothing else.
    ///
    /// This used to probe six ports and hand the turn to whatever answered. That made a build
    /// with MLX missing look like it was working — the built-in provider quietly served by
    /// Ollama or LM Studio — so the actual misconfiguration went unnoticed. Say what is wrong
    /// instead; the other backends are their own providers in the picker.
    public func streamChat(
        provider: ModelProvider,
        model: ModelInfo,
        systemPrompt: String,
        messages: [ChatMessage],
        temperature: Double,
        maxTokens: Int,
        reasoningEffort: ReasoningEffort,
        tools: [SwiftOpenWorkCore.Tool],
        onChunk: @Sendable @escaping (LLMStreamChunk) -> Void
    ) async throws {
        throw NSError(
            domain: "NativeMLXService",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: """
            The built-in Apple Silicon engine cannot run `\(model.id)`: the MLX packages are not \
            linked into this build, so there is no in-process engine.

            Rebuild with the MLX SPM packages linked, or select Ollama, LM Studio or a cloud \
            provider in the model picker — they run through their own providers, not this one.
            """]
        )
    }
}
#endif

public extension Notification.Name {
    static let mlxLoadedModelsDidChange = Notification.Name("mlxLoadedModelsDidChange")
}

extension NativeMLXService: InProcessModelEngine {}
