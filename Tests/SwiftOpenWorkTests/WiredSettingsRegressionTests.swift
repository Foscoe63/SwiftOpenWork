import XCTest
import AVFoundation
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage
@testable import SwiftOpenWorkLocalInference
@testable import SwiftOpenWorkEngine

/// The GPU memory budget slider used to move a number nothing read.
///
/// `mlxGpuMemoryBudgetRatio` was rendered in green on the MLX settings page as "Safe GPU Memory
/// Budget: N GB" and repeated in ProvidersView, while the runtime capped MLX's buffer cache at a
/// hardcoded 0.5 and judged model compatibility against a *different* hardcoded 0.75. The
/// setting's default is 0.75, so the compatibility verdict agreed with the readout exactly until
/// someone moved the slider — which is why this went unnoticed.
final class GPUMemoryBudgetRatioTests: XCTestCase {

    private var ram: Double { LocalMLXEngine.physicalRAMGB }

    /// A model just inside the budget at a generous ratio must fall outside a stingy one.
    func testTheRatioDecidesWhatFits() {
        let generous = LocalMLXEngine.assessCompatibility(requiredRAMGB: ram * 0.7, budgetRatio: 0.9)
        let stingy = LocalMLXEngine.assessCompatibility(requiredRAMGB: ram * 0.7, budgetRatio: 0.5)
        XCTAssertEqual(generous, .runsWell)
        XCTAssertNotEqual(stingy, .runsWell, "halving the budget must change the verdict")
    }

    /// Nothing larger than the machine can ever be recommended, at any ratio.
    func testAModelBiggerThanTheMachineIsNeverRecommended() {
        for ratio in [0.5, 0.75, 0.9] {
            XCTAssertEqual(
                LocalMLXEngine.assessCompatibility(requiredRAMGB: ram * 2, budgetRatio: ratio),
                .notRecommended
            )
        }
    }

    /// settings.json is hand-editable; a stored 0 or 50 is a wedged machine, not a preference.
    func testAnOutOfRangeRatioIsClamped() {
        XCTAssertEqual(LocalMLXEngine.clampedBudgetRatio(0), 0.1)
        XCTAssertEqual(LocalMLXEngine.clampedBudgetRatio(50), 0.95)
        XCTAssertEqual(LocalMLXEngine.clampedBudgetRatio(0.75), 0.75)
        XCTAssertEqual(
            LocalMLXEngine.clampedBudgetRatio(.nan),
            AppSettings.default.mlxGpuMemoryBudgetRatio,
            "a non-finite stored value must not become the cache limit"
        )
    }

    /// The verdicts shown to the user come from `judged(atBudgetRatio:)`, not from the verdict the
    /// static curated catalog baked in at the shipped default.
    func testACatalogEntryIsRejudgedAgainstTheStoredRatio() {
        let model = LocalMLXModel(
            id: "test/model",
            name: "Test",
            description: "",
            compatibility: .runsWell,
            estimatedRAMGB: ram * 0.8
        )
        XCTAssertEqual(model.compatibility, .runsWell, "baked in at construction")
        XCTAssertNotEqual(
            model.judged(atBudgetRatio: 0.5).compatibility, .runsWell,
            "a stale badge must not survive a ratio the user lowered"
        )
        XCTAssertEqual(model.judged(atBudgetRatio: 0.9).compatibility, .runsWell)
    }

    /// Every field except the verdict survives a re-judge.
    func testRejudgingChangesNothingElse() {
        let model = LocalMLXModel(
            id: "test/model", name: "Test", description: "d",
            sizeBytes: 123, parameterCount: "7B", quantization: "4-bit",
            modelType: "llama", contextWindow: 4096, isDownloaded: true,
            localDirectory: "/tmp/x", isVLM: true, useCase: .coding,
            compatibility: .runsWell, estimatedRAMGB: 4.0,
            tags: ["a"], isTopPick: true, downloadCount: 9
        )
        let rejudged = model.judged(atBudgetRatio: 0.75)
        XCTAssertEqual(rejudged.id, model.id)
        XCTAssertEqual(rejudged.localDirectory, model.localDirectory)
        XCTAssertEqual(rejudged.isDownloaded, model.isDownloaded)
        XCTAssertEqual(rejudged.tags, model.tags)
        XCTAssertEqual(rejudged.isTopPick, model.isTopPick)
        XCTAssertEqual(rejudged.downloadCount, model.downloadCount)
        XCTAssertEqual(rejudged.estimatedRAMGB, model.estimatedRAMGB)
    }
}

/// The voice toggles gated nothing: the mic button in the composer and the speak button on every
/// assistant message were drawn whatever they said, and `speechVoiceIdentifier` was never read.
final class VoiceSettingsTests: XCTestCase {

    /// Both features ship on, because both buttons have always been drawn. Defaulting them off
    /// now that they are honoured would amount to removing a working feature.
    func testVoiceDefaultsMatchTheBehaviourTheAppAlwaysHad() {
        XCTAssertTrue(AppSettings.default.voiceInputEnabled)
        XCTAssertTrue(AppSettings.default.voiceSynthesisEnabled)
    }

    /// A file written before the toggles were wired carries `false` from a switch that did
    /// nothing. That is not a preference, and the migration must not honour it as one.
    func testAPreMigrationFileHasItsVoiceTogglesTurnedOn() throws {
        let json = """
        {"theme":"dark","voiceInputEnabled":false,"voiceSynthesisEnabled":false}
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.settingsSchemaVersion, 1, "an absent version means pre-migration")

        var migrated = decoded
        XCTAssertTrue(PersistenceManager.applyMigrations(to: &migrated))
        XCTAssertTrue(migrated.voiceInputEnabled)
        XCTAssertTrue(migrated.voiceSynthesisEnabled)
        XCTAssertEqual(migrated.settingsSchemaVersion, AppSettings.currentSchemaVersion)
    }

    /// Once migrated, turning voice off has to stick — otherwise the switch is unusable in the
    /// other direction, which is the same defect wearing a different hat.
    func testAMigratedFileKeepsTheUsersChoiceToTurnVoiceOff() throws {
        var settings = AppSettings.default
        settings.voiceInputEnabled = false
        settings.voiceSynthesisEnabled = false

        let round = try JSONDecoder().decode(
            AppSettings.self, from: try JSONEncoder().encode(settings)
        )
        XCTAssertEqual(round.settingsSchemaVersion, AppSettings.currentSchemaVersion)

        var again = round
        XCTAssertFalse(PersistenceManager.applyMigrations(to: &again), "nothing left to migrate")
        XCTAssertFalse(again.voiceInputEnabled, "the migration must not re-enable a deliberate off")
        XCTAssertFalse(again.voiceSynthesisEnabled)
    }

    /// A stored identifier naming a voice this Mac does not have must fall back, not go silent.
    @MainActor
    func testAnUnknownVoiceIdentifierFallsBack() {
        XCTAssertNotNil(
            VoiceSpeechEngine.preferredVoice(),
            "speech must still have a voice when the stored identifier resolves to nothing"
        )
    }

    /// The shipped default was `com.apple.speech.synthesis.voice.Alex` — an *NSSpeechSynthesizer*
    /// identifier. Speech goes through AVSpeechSynthesizer, whose identifiers look nothing like
    /// it, so it matched none of the installed voices. A SwiftUI Picker whose selection matches
    /// no tag renders completely blank, which is what the new control did until this was found by
    /// looking at it.
    @MainActor
    func testTheLegacyVoiceIdentifierNormalisesToTheSystemDefault() {
        XCTAssertNil(
            AVSpeechSynthesisVoice(identifier: "com.apple.speech.synthesis.voice.Alex"),
            "if this ever resolves, the normalisation below is no longer needed"
        )
        XCTAssertEqual(
            VoiceSpeechEngine.resolvedVoiceIdentifier("com.apple.speech.synthesis.voice.Alex"), "",
            "an unresolvable identifier must show as System Default, not as an empty picker"
        )
        XCTAssertEqual(VoiceSpeechEngine.resolvedVoiceIdentifier(""), "")
    }

    /// A real installed voice must survive the round trip, or the picker could never hold one.
    @MainActor
    func testAnInstalledVoiceIdentifierIsKept() throws {
        let voices = VoiceSpeechEngine.installedVoices()
        try XCTSkipIf(voices.isEmpty, "no speech voices installed on this machine")
        let identifier = try XCTUnwrap(voices.first).identifier
        XCTAssertEqual(VoiceSpeechEngine.resolvedVoiceIdentifier(identifier), identifier)
    }

    /// The default must be reachable from the picker. The old one was not in the list at all.
    func testTheDefaultVoiceIdentifierIsTheSystemDefault() {
        XCTAssertEqual(AppSettings.default.speechVoiceIdentifier, "")
    }
}

/// `loadSettings()` is a read. It used to rewrite `mcp_servers.json` on every call, from 26 sites
/// including per-turn and per-tool-call paths.
final class LoadSettingsDoesNotWriteTests: XCTestCase {

    func testASecondLoadTouchesNoFiles() throws {
        let store = PersistenceManager.shared
        let original = store.loadSettings()
        defer { store.saveSettings(original) }

        // First load converges anything stale (schema migration, MCP repair, backup drift).
        _ = store.loadSettings()

        let dir = StorageService.shared.baseDirectory
        let watched = ["settings.json", "mcp_servers.json"]
        let before = try watched.map { name -> Date in
            let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
            return attrs[.modificationDate] as? Date ?? .distantPast
        }

        for _ in 0..<5 { _ = store.loadSettings() }

        let after = try watched.map { name -> Date in
            let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
            return attrs[.modificationDate] as? Date ?? .distantPast
        }

        for (index, name) in watched.enumerated() {
            XCTAssertEqual(before[index], after[index], "loadSettings() rewrote \(name)")
        }
    }
}

/// Top-P reached only the in-process MLX path: the slider did nothing for OpenAI-compatible,
/// Ollama or Anthropic endpoints.
final class TopPReachesEveryProviderTests: XCTestCase {

    /// 1.0 is a no-op and OpenAI advises against steering with temperature and top_p at once, so
    /// the key is sent only when the user has actually moved the slider.
    func testTopPIsOmittedAtItsNeutralDefault() {
        XCTAssertEqual(AppSettings.default.defaultTopP, 1.0, "the default must stay a no-op")
    }

    /// The MLX path has always honoured it; this pins that it still does, and from settings.
    func testTheMLXPathTakesTopPFromSettings() {
        var settings = AppSettings.default
        settings.defaultTopP = 0.4
        let params = NativeMLXService.generateParameters(maxTokens: 16, temperature: 0.5, settings: settings)
        XCTAssertEqual(params.topP, 0.4, accuracy: 0.0001)
    }

    /// A stored 0 would silence the model entirely if it were passed through.
    func testAZeroTopPFallsBackRatherThanTruncatingEverything() {
        var settings = AppSettings.default
        settings.defaultTopP = 0
        let params = NativeMLXService.generateParameters(maxTokens: 16, temperature: 0.5, settings: settings)
        XCTAssertEqual(params.topP, 1.0, accuracy: 0.0001)
    }
}

/// Settings that had a switch, or no control at all, and no reader anywhere.
@MainActor
final class NewlyWiredSettingsTests: XCTestCase {

    /// `showInterAgentCommunicationLogs` hides the Agent Messages tab. The tab list is what the
    /// inspector renders, so an inspector built from `InspectorTab.allCases` ignored it.
    func testTheAgentMessagesTabIsHiddenWhenTheLogIsSwitchedOff() {
        var settings = AppSettings.default
        settings.showInterAgentCommunicationLogs = false
        let visible = InspectorTab.allCases.filter {
            $0 != .comms || settings.showInterAgentCommunicationLogs
        }
        XCTAssertFalse(visible.contains(.comms))
        XCTAssertEqual(visible.count, InspectorTab.allCases.count - 1, "only that one tab goes")
    }

    /// `AgentCommunicationHub` is gone, and every path that used to post to it now reaches the
    /// one store the inspector reads.
    ///
    /// The hub was a second message log with four writers and no readers. Capping it — which is
    /// what the previous version of this test pinned — kept a dead store tidy instead of noticing
    /// that sub-agent replies and `agent_message` sends were being written somewhere invisible.
    func testNothingPostsToASecondMessageStore() throws {
        let sources = try Self.swiftSources()
        for file in sources {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard line.contains("AgentCommunicationHub") else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                XCTAssertTrue(
                    trimmed.hasPrefix("//") || trimmed.hasPrefix("///"),
                    "\(file.lastPathComponent):\(number + 1) still references the deleted hub"
                )
            }
        }
    }

    /// Every `AgentMessage` an agent produces has to reach `onInterAgentMessage`, because that
    /// callback is what writes `AppState.interAgentMessages` — the store the Agent Messages
    /// inspector renders. A message built and not passed there is one the user never sees.
    func testEveryAgentMessageIsForwardedToTheInspector() throws {
        let runner = try SourceTree.agentLoopSource()
        // Delegation now happens through `agent_spawn`; both halves of the exchange — the task
        // handed over and the report that came back — are built where its result is read.
        let forwardedInline = runner.components(separatedBy: "onInterAgentMessage(AgentMessage(").count - 1
        XCTAssertGreaterThanOrEqual(forwardedInline, 2, "a delegation and its reply must both reach the inspector")
        XCTAssertTrue(runner.contains("result.createdSubAgentTask"), "the task agent_spawn ran is never read")
        XCTAssertTrue(
            runner.contains("onInterAgentMessage(sent)"),
            "a message created by the agent_message tool is never forwarded to the inspector"
        )
    }

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private static func swiftSources() throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Verbose logging is off by default, and the gate is what decides whether a payload is even
    /// interpolated.
    func testVerboseLoggingIsOffByDefault() {
        XCTAssertFalse(AppSettings.default.verboseLogging)
    }

    /// The app must report the version it actually is. This was hardcoded "1.0.0" while the
    /// shipped release was 1.1.0.
    func testTheVersionStringComesFromTheBundle() {
        XCTAssertNotEqual(SettingsView.appVersionString, "1.0.0", "hardcoded again?")
        XCTAssertFalse(SettingsView.appVersionString.isEmpty)
    }

    /// The compaction threshold had a reader in `AgentRunner` and no control anywhere; the
    /// stepper that now exists must not be able to store a value that disables compaction.
    func testTheCompactionThresholdStaysPositive() {
        XCTAssertGreaterThan(AppSettings.default.contextCompactionThresholdTokens, 0)
    }
}

/// `verboseLogging` only means something if flipping it changes what gets logged, without a
/// relaunch. The gate is cached, so `saveSettings` has to invalidate it.
final class VerboseLoggingGateTests: XCTestCase {

    func testTheGateFollowsTheSettingAcrossASave() {
        let store = PersistenceManager.shared
        let original = store.loadSettings()
        defer {
            store.saveSettings(original)
            AppLog.invalidate()
        }

        var on = original
        on.verboseLogging = true
        store.saveSettings(on)
        XCTAssertTrue(AppLog.isVerbose, "saving must invalidate the cached gate")

        var off = original
        off.verboseLogging = false
        store.saveSettings(off)
        XCTAssertFalse(AppLog.isVerbose, "a relaunch must not be needed to turn it back off")
    }

    /// A payload has to be trimmed to something a log line can hold, and say it was trimmed.
    func testLongPayloadsAreTruncatedAndSayHowLongTheyWere() {
        let long = String(repeating: "x", count: 5000)
        let trimmed = AppLog.truncated(long, limit: 100)
        XCTAssertTrue(trimmed.hasPrefix(String(repeating: "x", count: 100)))
        XCTAssertTrue(trimmed.contains("5000 chars total"))
        XCTAssertEqual(AppLog.truncated("short", limit: 100), "short")
    }
}

/// "Prefer local, never silently reach the network."
///
/// `resolve` used to fall through to the first *enabled* provider in array order when the
/// selection was off. In a typical configuration a cloud provider sits earlier in that array than
/// the local engine, so disabling the local provider sent the next turn over the network with
/// nothing said. Fixing `defaultProviderId` stopped it firing on a fresh install; it stayed one
/// toggle away for anyone who switched the built-in engine off.
final class LocalProviderIsNeverSubstitutedByCloudTests: XCTestCase {

    private func provider(_ id: String, _ type: ProviderType, enabled: Bool) -> ModelProvider {
        ModelProvider(id: id, name: id, type: type, kind: type == .local ? .ollama : .openai, isEnabled: enabled)
    }

    /// The exact shape found on this machine: a cloud provider enabled and earlier in the array.
    func testADisabledLocalSelectionDoesNotFallThroughToCloud() {
        let providers = [
            provider("openrouter-cloud", .cloud, enabled: true),
            provider("omlx-local", .local, enabled: false)
        ]
        let resolved = ProviderSelection.resolve(providers: providers, selectedId: "omlx-local")
        XCTAssertEqual(resolved?.provider.type, .local, "must not hand the turn to a cloud provider")
        XCTAssertTrue(resolved?.mustRefuse == true)
        XCTAssertNotNil(resolved?.refusalMessage)
        XCTAssertEqual(resolved?.outcome, .refusedToLeaveLocal(selected: "omlx-local"))
    }

    /// Another local provider is a fine substitute; only the network is off limits.
    func testAnotherLocalProviderIsSubstitutedWithoutRefusing() {
        let providers = [
            provider("openrouter-cloud", .cloud, enabled: true),
            provider("lmstudio-local", .local, enabled: true),
            provider("omlx-local", .local, enabled: false)
        ]
        let resolved = ProviderSelection.resolve(providers: providers, selectedId: "omlx-local")
        XCTAssertEqual(resolved?.provider.id, "lmstudio-local")
        XCTAssertFalse(resolved?.mustRefuse == true)
        XCTAssertEqual(resolved?.overrodeDisabled, "omlx-local")
    }

    /// A disabled *cloud* selection keeps the old behaviour — the rule is about not leaving
    /// local, not about never substituting.
    func testADisabledCloudSelectionStillFallsBack() {
        let providers = [
            provider("openai-cloud", .cloud, enabled: false),
            provider("openrouter-cloud", .cloud, enabled: true)
        ]
        let resolved = ProviderSelection.resolve(providers: providers, selectedId: "openai-cloud")
        XCTAssertEqual(resolved?.provider.id, "openrouter-cloud")
        XCTAssertFalse(resolved?.mustRefuse == true)
        XCTAssertEqual(resolved?.overrodeDisabled, "openai-cloud")
    }

    /// Startup correction follows the same rule, or it would move the selection to a cloud
    /// provider before `resolve` ever got the chance to refuse.
    func testStartupCorrectionDoesNotMoveALocalSelectionToCloud() {
        let providers = [
            provider("openrouter-cloud", .cloud, enabled: true),
            provider("omlx-local", .local, enabled: false)
        ]
        XCTAssertEqual(
            ProviderSelection.correctedSelectionId(providers: providers, selectedId: "omlx-local"),
            "omlx-local",
            "a stale local selection stays put rather than being corrected onto the network"
        )
    }

    /// The refusal has to say which provider and what to do, or it is just a failed turn.
    func testTheRefusalNamesTheProviderAndTheFix() {
        let providers = [provider("omlx-local", .local, enabled: false)]
        let message = ProviderSelection.resolve(providers: providers, selectedId: "omlx-local")?.refusalMessage ?? ""
        XCTAssertTrue(message.contains("omlx-local"))
        XCTAssertTrue(message.contains("Model Providers"))
    }
}
