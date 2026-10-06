import XCTest
@testable import SwiftOpenWork
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkLocalInference

/// Sampling parameters for the in-process MLX path, and a deadline that works on uncancellable work.
final class MLXParametersTests: XCTestCase {

    private func settings(
        boost: Bool,
        repeatP: Double = 1.0,
        presence: Double = 0,
        frequency: Double = 0,
        topP: Double = 1.0
    ) -> AppSettings {
        var s = AppSettings.default
        s.autoAdjustPenaltiesForLocalModels = boost
        s.defaultRepeatPenalty = repeatP
        s.defaultPresencePenalty = presence
        s.defaultFrequencyPenalty = frequency
        s.defaultTopP = topP
        return s
    }

    /// The bug: this path passed only maxTokens and temperature, so local models had no
    /// repetition penalty at all and would loop.
    func testPenaltiesReachTheGenerator() {
        let p = NativeMLXService.generateParameters(
            maxTokens: 512, temperature: 0.7,
            settings: settings(boost: false, repeatP: 1.15, presence: 0.4, frequency: 0.5)
        )
        XCTAssertEqual(p.repetitionPenalty, 1.15)
        XCTAssertEqual(p.presencePenalty, 0.4)
        XCTAssertEqual(p.frequencyPenalty, 0.5)
    }

    /// `autoAdjustPenaltiesForLocalModels` raises weak values to the same floors the Ollama
    /// path uses — this path is the most local of all and previously ignored the flag.
    func testLocalModelBoostAppliesTheSameFloorsAsOllama() {
        let p = NativeMLXService.generateParameters(
            maxTokens: 512, temperature: 0.7,
            settings: settings(boost: true, repeatP: 1.0, presence: 0, frequency: 0)
        )
        XCTAssertEqual(p.repetitionPenalty, 1.20)
        XCTAssertEqual(p.presencePenalty, 0.30)
        XCTAssertEqual(p.frequencyPenalty, 0.30)
    }

    func testBoostNeverLowersAStrongerUserSetting() {
        let p = NativeMLXService.generateParameters(
            maxTokens: 512, temperature: 0.7,
            settings: settings(boost: true, repeatP: 1.5, presence: 0.9, frequency: 0.8)
        )
        XCTAssertEqual(p.repetitionPenalty, 1.5)
        XCTAssertEqual(p.presencePenalty, 0.9)
        XCTAssertEqual(p.frequencyPenalty, 0.8)
    }

    /// A penalty of 1.0 / 0.0 is a no-op; passing nil lets MLX skip the processor entirely.
    func testNeutralPenaltiesArePassedAsNil() {
        let p = NativeMLXService.generateParameters(
            maxTokens: 512, temperature: 0.7,
            settings: settings(boost: false, repeatP: 1.0, presence: 0, frequency: 0)
        )
        XCTAssertNil(p.repetitionPenalty)
        XCTAssertNil(p.presencePenalty)
        XCTAssertNil(p.frequencyPenalty)
    }

    /// The bug: with the default penalties Qwen3-Coder-Next read files but never produced an
    /// edit, because a tool call has to repeat recent tokens exactly. A turn that offers tools
    /// gets none, whatever the settings say.
    func testATurnThatOffersToolsGetsNoPenalties() {
        let p = NativeMLXService.generateParameters(
            maxTokens: 512, temperature: 0.7, toolsOffered: true,
            settings: settings(boost: true, repeatP: 1.25, presence: 0.35, frequency: 0.35)
        )
        XCTAssertNil(p.repetitionPenalty)
        XCTAssertNil(p.presencePenalty)
        XCTAssertNil(p.frequencyPenalty)
    }

    func testPlainChatStillGetsTheLocalFloors() {
        let s = settings(boost: true, repeatP: 1.0, presence: 0, frequency: 0)
        XCTAssertEqual(
            s.samplingPenalties(localFloor: SamplingPenalties(repetition: 1.2, presence: 0.3, frequency: 0.3), toolsOffered: false),
            SamplingPenalties(repetition: 1.2, presence: 0.3, frequency: 0.3)
        )
        XCTAssertEqual(
            s.samplingPenalties(localFloor: nil, toolsOffered: false),
            SamplingPenalties(repetition: 1.0, presence: 0, frequency: 0),
            "a cloud endpoint gets no floor"
        )
        XCTAssertEqual(s.samplingPenalties(localFloor: nil, toolsOffered: true), .neutral)
    }

    func testTopPIsHonouredAndNeverZero() {
        XCTAssertEqual(
            NativeMLXService.generateParameters(maxTokens: 1, temperature: 0, settings: settings(boost: false, topP: 0.9)).topP,
            0.9
        )
        XCTAssertEqual(
            NativeMLXService.generateParameters(maxTokens: 1, temperature: 0, settings: settings(boost: false, topP: 0)).topP,
            1.0,
            "a zero topP would sample nothing"
        )
    }

    func testMaxTokensFallsBackWhenUnset() {
        XCTAssertEqual(
            NativeMLXService.generateParameters(maxTokens: 0, temperature: 0.7, settings: settings(boost: false)).maxTokens,
            4096
        )
    }
}

final class AsyncDeadlineTests: XCTestCase {

    func testReturnsTheValueWhenWorkFinishesInTime() async throws {
        let task = Task<Int, Error> { 42 }
        let value = try await AsyncDeadline.wait(for: task, seconds: 5)
        XCTAssertEqual(value, 42)
    }

    func testPropagatesAFailure() async {
        struct Boom: Error {}
        let task = Task<Int, Error> { throw Boom() }
        do {
            _ = try await AsyncDeadline.wait(for: task, seconds: 5)
            XCTFail("expected the work's error")
        } catch is AsyncDeadline.TimedOut {
            XCTFail("should not be reported as a timeout")
        } catch {
            // expected
        }
    }

    /// The whole point: work that ignores cancellation must not hold the caller past the deadline.
    func testGivesUpOnUncancellableWork() async {
        let started = Date()
        let task = Task<Int, Error> {
            // Blocks a thread outright — no cancellation checks anywhere, like MLX's loader.
            // `usleep` rather than `Thread.sleep`, which Swift 6 forbids in async code.
            usleep(6_000_000)
            return 1
        }
        do {
            _ = try await AsyncDeadline.wait(for: task, seconds: 1)
            XCTFail("expected a timeout")
        } catch is AsyncDeadline.TimedOut {
            XCTAssertLessThan(Date().timeIntervalSince(started), 4, "returned late — it waited on the work")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The work keeps running after the deadline, so its result is still available later.
    func testWorkSurvivesTheDeadline() async throws {
        let task = Task<Int, Error> {
            try? await Task.sleep(nanoseconds: 700_000_000)
            return 7
        }
        do {
            _ = try await AsyncDeadline.wait(for: task, seconds: 0.2)
            XCTFail("expected a timeout")
        } catch is AsyncDeadline.TimedOut {
            let eventual = try await task.value
            XCTAssertEqual(eventual, 7, "the abandoned work should still complete")
        }
    }
}
