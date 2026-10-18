//
//  ArithmeticEvaluator.swift
//  M1K3Eval
//
//  The calculator probe (2026-10-18): does Lil reach for a calculator, and does it fix
//  anything? Lil's hard-reasoning misses read as set-up slips more than sums, so the probe
//  runs before any router work. A recursive-descent parser over numbers, + − × ÷ % ^ and
//  brackets, nothing else: no NSExpression (it calls functions and raises on bad input).
//  Pure; the eval stage offers it as the `calculate` stub behind
//  M1K3_SELFTEST_CHATEVAL_CALCULATOR=1.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-18, Confidence 0.85, Prior: none (new file).
//  Open: eval-only until the probe shows Lil uses it; a shipped tool would move to M1K3AgentTools.

import Foundation

public enum ArithmeticEvaluator {
    /// Longest expression accepted; a model's sum is a line, not a page.
    static let maxLength = 200
    /// Deepest bracket nesting accepted.
    static let maxDepth = 32

    /// The value of `expression`, or nil when it isn't plain arithmetic or has no finite value.
    public static func evaluate(_ expression: String) -> Double? {
        guard expression.count <= maxLength else { return nil }
        var parser = Parser(tokens: tokenize(expression) ?? [])
        guard !parser.tokens.isEmpty, let value = parser.parseExpression(depth: 0),
              parser.atEnd, value.isFinite else { return nil }
        return value
    }

    /// The tool's observation: "expr = value", or an error the model can act on.
    public static func answer(_ expression: String) -> String {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = evaluate(trimmed) else {
            return "Error: not an arithmetic expression. Use numbers with + - * / % ^ and brackets, e.g. 120 / 3."
        }
        return "\(trimmed) = \(format(value))"
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    enum Token: Equatable {
        case number(Double)
        case op(Character)
        case open, close
    }

    static func tokenize(_ text: String) -> [Token]? {
        var tokens: [Token] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace || c == "," { i += 1; continue }
            if c.isNumber || c == "." {
                var j = i
                var digits = ""
                while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "," {
                    if chars[j] != "," { digits.append(chars[j]) }
                    j += 1
                }
                guard let value = Double(digits) else { return nil }
                tokens.append(.number(value))
                i = j
                continue
            }
            switch c {
            case "+": tokens.append(.op("+"))
            case "-", "−": tokens.append(.op("-"))
            case "*", "×": tokens.append(.op("*"))
            case "/", "÷": tokens.append(.op("/"))
            case "%": tokens.append(.op("%"))
            case "^": tokens.append(.op("^"))
            case "(": tokens.append(.open)
            case ")": tokens.append(.close)
            default: return nil
            }
            // "**" is power.
            if c == "*", i + 1 < chars.count, chars[i + 1] == "*" {
                tokens[tokens.count - 1] = .op("^")
                i += 1
            }
            i += 1
        }
        return tokens
    }

    struct Parser {
        let tokens: [Token]
        var index = 0

        var atEnd: Bool {
            index == tokens.count
        }

        private var peek: Token? {
            index < tokens.count ? tokens[index] : nil
        }

        /// expression := term (("+" | "-") term)*
        mutating func parseExpression(depth: Int) -> Double? {
            guard depth <= ArithmeticEvaluator.maxDepth, var value = parseTerm(depth: depth) else { return nil }
            while case let .op(op)? = peek, op == "+" || op == "-" {
                index += 1
                guard let rhs = parseTerm(depth: depth) else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        /// term := power (("*" | "/" | "%") power)*
        mutating func parseTerm(depth: Int) -> Double? {
            guard var value = parsePower(depth: depth) else { return nil }
            while case let .op(op)? = peek, op == "*" || op == "/" || op == "%" {
                index += 1
                guard let rhs = parsePower(depth: depth), op == "*" || rhs != 0 else { return nil }
                switch op {
                case "*": value *= rhs
                case "/": value /= rhs
                default: value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        /// power := unary ("^" power)?   (right-associative)
        mutating func parsePower(depth: Int) -> Double? {
            guard let base = parseUnary(depth: depth) else { return nil }
            if case .op("^")? = peek {
                index += 1
                guard let exponent = parsePower(depth: depth + 1) else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        /// unary := ("-" | "+") unary | primary
        mutating func parseUnary(depth: Int) -> Double? {
            guard depth <= ArithmeticEvaluator.maxDepth else { return nil }
            if case let .op(op)? = peek, op == "-" || op == "+" {
                index += 1
                guard let value = parseUnary(depth: depth + 1) else { return nil }
                return op == "-" ? -value : value
            }
            return parsePrimary(depth: depth)
        }

        /// primary := number | "(" expression ")"
        mutating func parsePrimary(depth: Int) -> Double? {
            switch peek {
            case let .number(value)?:
                index += 1
                return value
            case .open?:
                index += 1
                guard let value = parseExpression(depth: depth + 1), case .close? = peek else { return nil }
                index += 1
                return value
            default:
                return nil
            }
        }
    }
}
