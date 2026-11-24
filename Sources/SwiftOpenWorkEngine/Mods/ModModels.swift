import Foundation

/// A JSON value that can cross actors.
public enum ModJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ModJSON])
    case object([String: ModJSON])

    public init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            // JSONSerialization hands booleans back as NSNumber.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) } else { self = .number(number.doubleValue) }
        case let text as String: self = .string(text)
        case let list as [Any]: self = .array(list.map { ModJSON(any: $0) })
        case let dict as [String: Any]: self = .object(dict.mapValues { ModJSON(any: $0) })
        default: self = .null
        }
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [ModJSON]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: ModJSON]? { if case .object(let o) = self { return o }; return nil }
    /// Text for a prop that may be written as a string or a number.
    public var text: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
}

/// What a mod drew: the element tree its `ui.render` hook returned.
public indirect enum ModNode: Sendable, Equatable {
    case text(String)
    case element(ModElement)
    case fragment([ModNode])
}

public struct ModElement: Sendable, Equatable {
    public var type: String
    public var props: [String: ModJSON]
    public var children: [ModNode]
    /// Which mod's handler a press goes to, and its handle.
    public var pressPlugin: String?
    public var pressHandle: Int?
    public var onInput: Int?
    public var onSelect: Int?
    public var onSubmit: Int?

    public func prop(_ key: String) -> ModJSON? { props[key] }
}

/// The reply to a `ui.render` request: either a drawing, or the (possibly rewritten) props the
/// app would have drawn itself.
public enum ModRenderResult: Sendable, Equatable {
    case none
    case engine(props: [String: ModJSON])
    case tree(ModNode)

    public var isEmpty: Bool {
        switch self {
        case .none: return true
        case .engine: return true
        case .tree(let node):
            if case .fragment(let items) = node { return items.isEmpty }
            return false
        }
    }

    static func parse(_ any: Any?) -> ModRenderResult {
        guard let any, !(any is NSNull) else { return .none }
        if let dict = any as? [String: Any], (dict["type"] as? String) == "engine" {
            let props = (dict["props"] as? [String: Any]) ?? [:]
            return .engine(props: props.mapValues { ModJSON(any: $0) })
        }
        return .tree(parseNode(any))
    }

    static func parseNode(_ any: Any?) -> ModNode {
        switch any {
        case let text as String: return .text(text)
        case let number as NSNumber: return .text(number.stringValue)
        case let list as [Any]: return .fragment(list.map(parseNode))
        case let dict as [String: Any]:
            guard let type = dict["type"] as? String else { return .fragment([]) }
            let props = ((dict["props"] as? [String: Any]) ?? [:]).mapValues { ModJSON(any: $0) }
            let kids = ((dict["children"] as? [Any]) ?? []).map(parseNode)
            var element = ModElement(type: type, props: props, children: kids)
            if let press = dict["press"] as? [String: Any] {
                element.pressPlugin = press["plugin"] as? String
                element.pressHandle = (press["handle"] as? NSNumber)?.intValue
            }
            if let on = dict["on"] as? [String: Any] {
                element.onInput = (on["onInput"] as? NSNumber)?.intValue
                element.onSelect = (on["onSelect"] as? NSNumber)?.intValue
                element.onSubmit = (on["onSubmit"] as? NSNumber)?.intValue
            }
            return .element(element)
        default: return .fragment([])
        }
    }
}

/// A mod as it is on disk: where it lives and how it starts.
struct ModManifest: Equatable, Sendable {
    var name: String
    var version: String
    var description: String
    var root: String
    var entries: [String]
    var source: String
    var optionsJSON: String
    var pluginId: String?
}

/// How a mod stands, for the Mods page.
public struct ModInfo: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable { case off, starting, running, failed, stopped, needsReview }
    public var id: String { name }
    public var name: String
    public var version: String
    public var description: String
    public var source: String
    public var root: String
    public var enabled: Bool
    public var status: Status
    public var error: String?
    public var hookCount: Int
    public var toolCount: Int
    public var commandCount: Int
    /// Only mods in this app's own folder can be deleted here.
    public var isRemovable: Bool
}

public struct ModPane: Identifiable, Equatable, Sendable {
    public var id: String
    public var plugin: String
    public var title: String
}

public struct ModStatusLine: Identifiable, Equatable, Sendable {
    public var id: String { plugin }
    public var plugin: String
    public var text: String
}

public struct ModCommand: Identifiable, Equatable, Sendable {
    public var id: String { plugin + ":" + name }
    public var plugin: String
    public var name: String
    public var description: String
    public var argumentHint: String
}

/// A question a mod asked with `$.ui.ask`, waiting for the person.
public struct ModQuestion: Identifiable, Equatable, Sendable {
    public var id: String
    public var plugin: String
    public var question: String
    public var header: String?
    public var options: [String]
    public var multiSelect: Bool
}

public enum PromptSubmitOutcome: Sendable, Equatable {
    case text(String)
    case drop(String)
}
