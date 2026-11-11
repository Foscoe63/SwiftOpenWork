import XCTest
@testable import SwiftOpenWorkEngine

/// The built-in tools are found by name in `ToolHandlerRegistry` instead of a `switch`. A name
/// missing from the table is not a compile error, so these check what the compiler no longer does.
final class ToolHandlerRegistryTests: XCTestCase {

    func testEveryBuiltInToolHasAHandler() {
        for name in ToolCallRepair.builtInNames {
            XCTAssertNotNil(ToolHandlerRegistry.handlers[name], "no handler is registered for \(name)")
        }
    }

    func testNoNameIsRegisteredTwice() {
        let names = ToolHandlerRegistry.registrations.flatMap(\.names)
        XCTAssertEqual(names.count, Set(names).count)
        XCTAssertEqual(ToolHandlerRegistry.names, Set(names))
    }

    func testAnAliasReachesTheSameToolAsItsCanonicalName() {
        for registration in ToolHandlerRegistry.registrations {
            XCTAssertFalse(registration.names.isEmpty)
            for name in registration.names {
                XCTAssertNotNil(ToolHandlerRegistry.handlers[name], name)
            }
        }
        XCTAssertNotNil(ToolHandlerRegistry.handlers["read_file"])
        XCTAssertNotNil(ToolHandlerRegistry.handlers["run_command"])
    }

    /// MCP tools are not built-ins: they are resolved against the servers' catalogs after the
    /// table misses, and a name nothing owns must still fail rather than report that it ran.
    func testAnUnknownNameHasNoHandler() {
        XCTAssertNil(ToolHandlerRegistry.handlers["mcp__server__tool"])
        XCTAssertNil(ToolHandlerRegistry.handlers["no_such_tool"])
    }
}
