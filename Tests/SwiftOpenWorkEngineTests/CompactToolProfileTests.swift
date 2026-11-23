import XCTest
import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

final class CompactToolProfileTests: XCTestCase {
    private func tools(_ names: [String]) -> [Tool] {
        names.map { Tool(id: $0, name: $0, displayName: $0, description: "d", category: .system, parametersJsonSchema: "{}") }
    }

    private let everyday = ["file_read", "edit_file", "terminal_command", "grep", "glob"]

    func testOnlySmallLocalModelsGetTheCompactProfile() {
        XCTAssertTrue(BuiltInToolSearch.usesCompactProfile(providerType: .local, contextWindow: 32_768))
        XCTAssertFalse(BuiltInToolSearch.usesCompactProfile(providerType: .local, contextWindow: 131_072))
        XCTAssertFalse(BuiltInToolSearch.usesCompactProfile(providerType: .cloud, contextWindow: 32_768))
    }

    func testCompactDefersMoreButNeverTheEverydayTools() {
        let all = tools(everyday + ["rename_symbol", "find_references", "go_to_definition", "code_diagnostics", "calculator"])
        let normal = BuiltInToolSearch.partition(all, prompt: "tidy this up")
        XCTAssertTrue(normal.deferred.isEmpty)
        let compact = BuiltInToolSearch.partition(all, prompt: "tidy this up", compact: true)
        XCTAssertEqual(Set(compact.deferred.map(\.name)),
                       ["rename_symbol", "find_references", "go_to_definition", "code_diagnostics", "calculator"])
        XCTAssertEqual(Set(compact.loaded.map(\.name)), Set(everyday))
    }

    func testAPromptThatNamesTheToolKeepsItLoaded() {
        let all = tools(everyday + ["rename_symbol", "find_references", "go_to_definition", "code_diagnostics", "calculator"])
        let split = BuiltInToolSearch.partition(all, prompt: "rename the symbol Foo to Bar", compact: true)
        XCTAssertTrue(split.loaded.contains { $0.name == "rename_symbol" })
    }

    func testCommonWordsDoNotKeepTheCompactToolsLoaded() {
        let all = tools(everyday + ["rename_symbol", "find_references", "go_to_definition", "code_diagnostics", "file_copy"])
        let split = BuiltInToolSearch.partition(all, prompt: "find the file that parses config", compact: true)
        XCTAssertTrue(split.deferred.contains { $0.name == "find_references" })
        XCTAssertTrue(split.deferred.contains { $0.name == "file_copy" })
    }
}
