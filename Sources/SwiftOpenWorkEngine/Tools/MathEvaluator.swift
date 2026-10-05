import Foundation

/// Evaluates the arithmetic the `calculator` tool accepts, in plain Swift.
///
/// This replaced `NSExpression(format:)`, which raised an Objective-C exception on malformed input
/// such as `"2 +"` (taking the whole app down mid-turn) and could invoke selectors via `FUNCTION()`.
/// Supports numbers (incl. `1e3`, `0x1F`), `+ - * / % ^ **`, `×`/`÷`/`x` as operators, parentheses,
/// the constants `pi` and `e`, and a fixed set of math functions. Anything else is an error.
public enum MathEvaluator {
    public struct EvaluationError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public static func evaluate(_ expression: String) throws -> Double {
        var parser = Parser(tokens: try tokenize(expression))
        let value = try parser.parseExpression()
        guard parser.isAtEnd else {
            throw EvaluationError(description: "Unexpected '\(parser.peek().map(String.init(describing:)) ?? "")'")
        }
        guard value.isFinite else {
            throw EvaluationError(description: value.isNaN ? "Result is not a number" : "Result is infinite (division by zero or overflow)")
        }
        return value
    }

    /// Integers print without a trailing `.0`; everything else uses Swift's shortest round-trip form.
    public static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    // MARK: - Tokens

    enum Token: Equatable, CustomStringConvertible {
        case number(Double)
        case identifier(String)
        case op(Character)
        case leftParen, rightParen, comma

        /// True for a token an operand can end with, so an `x` after it is an operator.
        var endsOperand: Bool {
            switch self {
            case .number, .rightParen: return true
            default: return false
            }
        }

        var description: String {
            switch self {
            case .number(let n): return MathEvaluator.format(n)
            case .identifier(let s): return s
            case .op(let c): return String(c)
            case .leftParen: return "("
            case .rightParen: return ")"
            case .comma: return ","
            }
        }
    }

    static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isASCII, c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isASCII && chars[i + 1].isNumber) {
                // Hex literal.
                if c == "0", i + 1 < chars.count, chars[i + 1] == "x" || chars[i + 1] == "X",
                   i + 2 < chars.count, chars[i + 2].isHexDigit {
                    var j = i + 2
                    while j < chars.count, chars[j].isHexDigit { j += 1 }
                    guard let value = UInt64(String(chars[(i + 2)..<j]), radix: 16) else {
                        throw EvaluationError(description: "Invalid hex number")
                    }
                    tokens.append(.number(Double(value)))
                    i = j
                    continue
                }
                var j = i
                while j < chars.count, chars[j].isASCII, chars[j].isNumber || chars[j] == "." { j += 1 }
                // Exponent, only when digits follow.
                if j < chars.count, chars[j] == "e" || chars[j] == "E" {
                    var k = j + 1
                    if k < chars.count, chars[k] == "+" || chars[k] == "-" { k += 1 }
                    if k < chars.count, chars[k].isASCII, chars[k].isNumber {
                        while k < chars.count, chars[k].isASCII, chars[k].isNumber { k += 1 }
                        j = k
                    }
                }
                let literal = String(chars[i..<j])
                guard let value = Double(literal) else {
                    throw EvaluationError(description: "Invalid number '\(literal)'")
                }
                tokens.append(.number(value))
                i = j
                continue
            }
            // `x` right after a number or `)` is multiplication, even unspaced ("3x4").
            if c == "x" || c == "X", tokens.last?.endsOperand == true {
                tokens.append(.op("*"))
                i += 1
                continue
            }
            if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                tokens.append(.identifier(String(chars[i..<j]).lowercased()))
                i = j
                continue
            }
            switch c {
            case "+", "-", "/", "%", "^": tokens.append(.op(c))
            case "−": tokens.append(.op("-"))
            case "×", "·": tokens.append(.op("*"))
            case "÷": tokens.append(.op("/"))
            case "*":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    tokens.append(.op("^")); i += 1
                } else {
                    tokens.append(.op("*"))
                }
            case "(": tokens.append(.leftParen)
            case ")": tokens.append(.rightParen)
            case ",": tokens.append(.comma)
            default:
                throw EvaluationError(description: "Unsupported character '\(c)'")
            }
            i += 1
        }
        return tokens
    }

    // MARK: - Parser

    static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E, "tau": 2 * .pi]

    static let unaryFunctions: [String: @Sendable (Double) -> Double] = [
        "sqrt": { $0.squareRoot() }, "cbrt": { cbrt($0) }, "abs": { abs($0) },
        "sin": { sin($0) }, "cos": { cos($0) }, "tan": { tan($0) },
        "asin": { asin($0) }, "acos": { acos($0) }, "atan": { atan($0) },
        "sinh": { sinh($0) }, "cosh": { cosh($0) }, "tanh": { tanh($0) },
        "ln": { log($0) }, "log": { log10($0) }, "log10": { log10($0) }, "log2": { log2($0) },
        "exp": { exp($0) }, "floor": { $0.rounded(.down) }, "ceil": { $0.rounded(.up) },
        "round": { $0.rounded() }, "trunc": { $0.rounded(.towardZero) },
    ]

    static let binaryFunctions: [String: @Sendable (Double, Double) -> Double] = [
        "pow": { pow($0, $1) }, "atan2": { atan2($0, $1) }, "mod": { fmod($0, $1) },
        "min": { min($0, $1) }, "max": { max($0, $1) }, "hypot": { hypot($0, $1) },
    ]

    struct Parser {
        let tokens: [Token]
        var index = 0
        var depth = 0

        init(tokens: [Token]) { self.tokens = tokens }

        var isAtEnd: Bool { index >= tokens.count }
        func peek() -> Token? { isAtEnd ? nil : tokens[index] }
        mutating func advance() -> Token? {
            defer { index += 1 }
            return peek()
        }

        private func isMultiplyOperator(_ token: Token?) -> Bool {
            if case .op(let c) = token, c == "*" || c == "/" || c == "%" { return true }
            return false
        }

        mutating func parseExpression() throws -> Double {
            depth += 1
            defer { depth -= 1 }
            guard depth < 200 else { throw EvaluationError(description: "Expression is nested too deeply") }
            var value = try parseTerm()
            while case .op(let c) = peek(), c == "+" || c == "-" {
                index += 1
                let rhs = try parseTerm()
                value = c == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func parseTerm() throws -> Double {
            var value = try parseUnary()
            while isMultiplyOperator(peek()) {
                let token = advance()
                let rhs = try parseUnary()
                switch token {
                case .op("/"): value /= rhs
                case .op("%"): value = fmod(value, rhs)
                default: value *= rhs
                }
            }
            return value
        }

        mutating func parseUnary() throws -> Double {
            if case .op(let c) = peek(), c == "-" || c == "+" {
                index += 1
                let operand = try parseUnary()
                return c == "-" ? -operand : operand
            }
            return try parsePower()
        }

        /// Right-associative, and binds tighter than unary minus on its left: `-2^2` is -4.
        mutating func parsePower() throws -> Double {
            let base = try parsePrimary()
            if case .op("^") = peek() {
                index += 1
                let exponent = try parseUnary()
                return pow(base, exponent)
            }
            return base
        }

        mutating func parsePrimary() throws -> Double {
            guard let token = advance() else {
                throw EvaluationError(description: "Expression ended unexpectedly")
            }
            switch token {
            case .number(let value):
                return value
            case .leftParen:
                let value = try parseExpression()
                try expect(.rightParen)
                return value
            case .identifier(let name):
                if case .leftParen = peek() {
                    index += 1
                    var args = [try parseExpression()]
                    while case .comma = peek() {
                        index += 1
                        args.append(try parseExpression())
                    }
                    try expect(.rightParen)
                    if let f = MathEvaluator.unaryFunctions[name] {
                        guard args.count == 1 else { throw EvaluationError(description: "\(name)() takes 1 argument") }
                        return f(args[0])
                    }
                    if let f = MathEvaluator.binaryFunctions[name] {
                        if name == "min" || name == "max", !args.isEmpty {
                            return args.dropFirst().reduce(args[0], f)
                        }
                        guard args.count == 2 else { throw EvaluationError(description: "\(name)() takes 2 arguments") }
                        return f(args[0], args[1])
                    }
                    throw EvaluationError(description: "Unknown function '\(name)'")
                }
                if let value = MathEvaluator.constants[name] { return value }
                throw EvaluationError(description: "Unknown name '\(name)'")
            default:
                throw EvaluationError(description: "Unexpected '\(token)'")
            }
        }

        mutating func expect(_ token: Token) throws {
            guard peek() == token else {
                throw EvaluationError(description: "Expected '\(token)'")
            }
            index += 1
        }
    }
}
