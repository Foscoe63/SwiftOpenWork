import XCTest
@testable import SwiftOpenWork

final class SmokeTests: XCTestCase {

    func testNavigationDestinationCaseCountAndOrder() {
        let expected: [NavigationDestination] = [
            .chat, .localModels, .agents, .providers, .automations, .loops,
            .watchFolders, .artifacts, .memory, .tools, .dashboard, .settings
        ]
        XCTAssertEqual(NavigationDestination.allCases.count, 12, "NavigationDestination should have exactly 12 cases")
        XCTAssertEqual(NavigationDestination.allCases, expected, "NavigationDestination cases should match expected order")
    }

    func testInspectorTabCaseCountAndOrder() {
        let expected: [InspectorTab] = [
            .editor, .preview, .subagents, .comms, .artifacts, .files, .tools, .terminal
        ]
        XCTAssertEqual(InspectorTab.allCases.count, 8, "InspectorTab should have exactly 8 cases")
        XCTAssertEqual(InspectorTab.allCases, expected, "InspectorTab cases should match expected order")
    }

    func testNavigationDestinationDisplayNamesNonEmpty() {
        for destination in NavigationDestination.allCases {
            XCTAssertFalse(destination.displayName.isEmpty, "NavigationDestination.\(destination.rawValue).displayName should be non-empty")
        }
    }

    func testNavigationDestinationIconsNonEmpty() {
        for destination in NavigationDestination.allCases {
            XCTAssertFalse(destination.icon.isEmpty, "NavigationDestination.\(destination.rawValue).icon should be non-empty")
        }
    }
}
