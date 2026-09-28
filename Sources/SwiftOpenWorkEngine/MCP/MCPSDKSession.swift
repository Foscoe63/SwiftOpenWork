import Foundation
import MCP
import System
import SwiftOpenWorkCore

/// Official Model Context Protocol Swift SDK session for one stdio server.
/// Spawns the child process and bridges pipes into `StdioTransport` — same architecture
/// as Radiant's `@modelcontextprotocol/sdk` Client + StdioClientTransport.
public actor MCPSDKSession {
    public let config: MCPServerConfig
    private var process: Process?
    private var client: Client?
    private var inPipe: Pipe?
    private var outPipe: Pipe?

    public init(config: MCPServerConfig) {
        self.config = config
    }

    public var isRunning: Bool {
        process?.isRunning == true && client != nil
    }

    @discardableResult
    public func start() async throws -> [MCPToolDefinition] {
        if isRunning, let client {
            return try await Self.listAll(client)
        }

        await stop()

        let process = Process()
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardError = FileHandle.nullDevice

        let env = ToolExecutionEngine.defaultEnvironment(custom: config.env)
        let launchArgs = MCPClientManager.sanitizedStdioArgs(
            command: config.command,
            name: config.name,
            args: config.args
        )
        let resolved = MCPClientManager.resolveExecutable(config.command, environment: env)
        if resolved.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: resolved)
            process.arguments = launchArgs
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [config.command] + launchArgs
        }
        if !config.workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: config.workingDirectory)
        }
        process.environment = env
        process.standardInput = inPipe
        process.standardOutput = outPipe

        try process.run()
        MCPProcessRegistry.register(process.processIdentifier)
        try await Task.sleep(nanoseconds: 120_000_000)
        guard process.isRunning else {
            MCPProcessRegistry.unregister(process.processIdentifier)
            throw MCPSDKError.processExited("MCP '\(config.name)' exited immediately after launch.")
        }

        // Retain process before connect so stop() can kill a hung handshake.
        self.process = process
        self.inPipe = inPipe
        self.outPipe = outPipe

        let inputFD = FileDescriptor(rawValue: outPipe.fileHandleForReading.fileDescriptor)
        let outputFD = FileDescriptor(rawValue: inPipe.fileHandleForWriting.fileDescriptor)
        let transport = StdioTransport(input: inputFD, output: outputFD)
        let client = Client(name: "SwiftOpenWork", version: "1.0.0")
        do {
            _ = try await client.connect(transport: transport)
        } catch {
            MCPProcessRegistry.stopTree(process)
            self.process = nil
            self.inPipe = nil
            self.outPipe = nil
            throw error
        }

        self.client = client

        return try await Self.listAll(client)
    }

    /// Every page of `tools/list`. Only the first page was read, so a server with more tools than
    /// one page holds silently lost the rest.
    private static func listAll(_ client: Client) async throws -> [MCPToolDefinition] {
        var all: [MCPToolDefinition] = []
        var cursor: String?
        var pages = 0
        repeat {
            let page = try await client.listTools(cursor: cursor)
            all.append(contentsOf: page.tools.map(Self.mapTool))
            cursor = page.nextCursor.flatMap { $0.isEmpty ? nil : $0 }
            pages += 1
        } while cursor != nil && pages < 20
        return all
    }

    /// How long one tool call may take before it is given up on.
    public static let callTimeoutSeconds: Double = 120

    public func callTool(name: String, arguments: sending [String: Any]) async throws -> String {
        guard let client else {
            throw MCPSDKError.notConnected
        }
        let valueArgs = try Self.toValueObject(arguments)
        // Bounded: a server that never answers used to hold the agent for ever. Raced with a
        // continuation rather than a task group, because the SDK's request does not unwind when
        // cancelled and a group would wait for it.
        let seconds = Self.callTimeoutSeconds
        let (content, isError): ([MCP.Tool.Content], Bool?) = try await withCheckedThrowingContinuation { continuation in
            let once = MCPOnceThrowing(continuation)
            Task {
                do {
                    let result = try await client.callTool(name: name, arguments: valueArgs)
                    once.resume(returning: (content: result.content, isError: result.isError))
                } catch {
                    once.resume(throwing: error)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.resume(throwing: MCPSDKError.timedOut(name, Int(seconds)))
            }
        }
        let text = content.compactMap { part -> String? in
            switch part {
            case .text(let t, _, _):
                return t
            case .image(_, let mime, _, _):
                return "[image \(mime)]"
            case .audio(_, let mime, _, _):
                return "[audio \(mime)]"
            case .resource(let resource, _, _):
                return "[resource \(resource.uri)]"
            case .resourceLink(let uri, let name, _, _, _, _):
                return "[resourceLink \(name) \(uri)]"
            }
        }.joined(separator: "\n")
        if isError == true {
            throw MCPSDKError.toolError(text.isEmpty ? "Tool returned isError" : text)
        }
        return text.isEmpty ? "(no output)" : text
    }

    public func stop() async {
        // Snapshot the tree *before* disconnecting: closing stdin can make the wrapper (`npx`)
        // exit and orphan the real server, which is then no longer found under it.
        let pid = process?.processIdentifier
        let descendants = pid.map { ProcessTree.liveDescendants(of: $0) } ?? []
        if let client {
            await client.disconnect()
        }
        client = nil
        if let process {
            if process.isRunning {
                ProcessTree.terminate(process.processIdentifier, alsoStopping: descendants)
            } else {
                // The wrapper is gone; whatever it started may not be.
                for child in descendants where kill(child, 0) == 0 { kill(child, SIGTERM) }
            }
            MCPProcessRegistry.unregister(process.processIdentifier)
        }
        process = nil
        inPipe = nil
        outPipe = nil
    }

    private static func mapTool(_ t: MCP.Tool) -> MCPToolDefinition {
        var schemaJson: String?
        if let data = try? JSONEncoder().encode(t.inputSchema),
           let s = String(data: data, encoding: .utf8) {
            schemaJson = s
        }
        return MCPToolDefinition(
            name: t.name,
            description: t.description,
            inputSchemaJson: schemaJson
        )
    }

    private static func toValueObject(_ dict: [String: Any]) throws -> [String: Value] {
        let data = try JSONSerialization.data(withJSONObject: dict)
        let value = try JSONDecoder().decode(Value.self, from: data)
        guard case .object(let obj) = value else {
            return [:]
        }
        return obj
    }
}

public enum MCPSDKError: LocalizedError {
    case processExited(String)
    case notConnected
    case toolError(String)
    case timedOut(String, Int)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let tool, let seconds):
            return "'\(tool)' did not answer within \(seconds) seconds (timed out)."
        case .processExited(let m): return m
        case .notConnected: return "MCP SDK client is not connected."
        case .toolError(let m): return m
        }
    }
}

/// Resumes a throwing continuation at most once, so a result and a timeout can race safely.
private final class MCPOnceThrowing<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock(); defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }

    func resume(returning value: T) { take()?.resume(returning: value) }
    func resume(throwing error: Error) { take()?.resume(throwing: error) }
}
