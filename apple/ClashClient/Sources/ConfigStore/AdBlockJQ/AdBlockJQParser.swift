#if os(iOS) || os(macOS)
import Foundation

 
 
 
 
 
 
 
 
 

struct AdBlockJQParser {
     
     
     
     
     
     
     
    static let maximumNesting = 256

    private let tokens: [AdBlockJQToken]
    private var index = 0
    private var nesting = 0
    private let stackFloor: UInt

    private init(_ tokens: [AdBlockJQToken], nesting: Int = 0) {
        self.tokens = tokens
        self.nesting = nesting
        stackFloor = AdBlockJQStack.floor(reserve: AdBlockJQStack.readReserve)
    }

     
    private mutating func descend() throws {
        nesting += 1
        if nesting > Self.maximumNesting {
            throw AdBlockJQSyntaxError(message: "the program nests deeper than \(Self.maximumNesting) levels")
        }
        if AdBlockJQStack.address() < stackFloor {
            throw AdBlockJQSyntaxError(message: "the program nests too deep for the thread's stack")
        }
    }

    private mutating func ascend(_ levels: Int = 1) { nesting -= levels }

    static func parse(_ text: String) throws -> AdBlockJQSyntax {
        var parser = AdBlockJQParser(try AdBlockJQLexer.tokens(text))
        return try parser.program()
    }

    private var current: AdBlockJQToken { tokens[min(index, tokens.count - 1)] }

    private func peek(_ offset: Int) -> AdBlockJQToken { tokens[min(index + offset, tokens.count - 1)] }

    private mutating func advance() { if index < tokens.count - 1 { index += 1 } }

    private func unexpected() -> AdBlockJQSyntaxError {
        AdBlockJQSyntaxError(message: "syntax error, unexpected \(current.spelling) at line \(current.line)")
    }

    private mutating func expect(_ punctuation: String) throws {
        guard current.isPunctuation(punctuation) else { throw unexpected() }
        advance()
    }

    private mutating func expectKeyword(_ word: String) throws {
        guard current.isKeyword(word) else { throw unexpected() }
        advance()
    }

    private var atEnd: Bool {
        if case .end = current.kind { return true }
        return false
    }

    private mutating func program() throws -> AdBlockJQSyntax {
        if current.isKeyword("import") || current.isKeyword("include") || current.isKeyword("module") {
            throw AdBlockJQSyntaxError(message: "jq modules (import, include) are not supported in a module's rewrite")
        }
        if atEnd { return .identity }
        let body = try pipe()
        guard atEnd else { throw unexpected() }
        return body
    }

     

    private mutating func pipe() throws -> AdBlockJQSyntax {
        try descend()
        defer { ascend() }
        var stages = [try comma()]
        while current.isPunctuation("|") {
            advance()
            stages.append(try comma())
        }
        return stages.count == 1 ? stages[0] : .pipe(stages)
    }

    private mutating func comma() throws -> AdBlockJQSyntax {
        var items = [try alternative()]
        while current.isPunctuation(",") {
            advance()
            items.append(try alternative())
        }
        return items.count == 1 ? items[0] : .comma(items)
    }

    private mutating func alternative() throws -> AdBlockJQSyntax {
        let left = try assignment()
        if current.isPunctuation("//") {
            advance()
            try descend()
            defer { ascend() }
            return .alternative(left, try alternative())
        }
        return left
    }

    private static let assignments: [String: AdBlockJQUpdateOperator] = [
        "=": .assign, "|=": .modify, "+=": .arithmetic(.plus), "-=": .arithmetic(.minus), "*=": .arithmetic(.multiply),
        "/=": .arithmetic(.divide), "%=": .arithmetic(.modulo), "//=": .alternative,
    ]

    private mutating func assignment() throws -> AdBlockJQSyntax {
        let left = try or()
        if case .punctuation(let text) = current.kind, let operation = Self.assignments[text] {
            advance()
            let right = try or()
            if case .punctuation(let next) = current.kind, Self.assignments[next] != nil { throw unexpected() }
            return .update(operation, left, right)
        }
        return left
    }

    private mutating func or() throws -> AdBlockJQSyntax {
        var left = try and()
        var levels = 0
        defer { ascend(levels) }
        while current.isKeyword("or") {
            advance()
            try descend()
            levels += 1
            left = .or(left, try and())
        }
        return left
    }

    private mutating func and() throws -> AdBlockJQSyntax {
        var left = try comparison()
        var levels = 0
        defer { ascend(levels) }
        while current.isKeyword("and") {
            advance()
            try descend()
            levels += 1
            left = .and(left, try comparison())
        }
        return left
    }

    private static let comparisons: [String: AdBlockJQBinaryOperator] = [
        "==": .equal, "!=": .notEqual, "<": .less, "<=": .lessOrEqual, ">": .greater, ">=": .greaterOrEqual,
    ]

    private mutating func comparison() throws -> AdBlockJQSyntax {
        let left = try additive()
        if case .punctuation(let text) = current.kind, let operation = Self.comparisons[text] {
            advance()
            let right = try additive()
            if case .punctuation(let next) = current.kind, Self.comparisons[next] != nil { throw unexpected() }
            return .binary(operation, left, right)
        }
        return left
    }

    private mutating func additive() throws -> AdBlockJQSyntax {
        var left = try multiplicative()
        var levels = 0
        defer { ascend(levels) }
        while true {
            if current.isPunctuation("+") {
                advance()
                try descend()
                levels += 1
                left = .binary(.plus, left, try multiplicative())
            } else if current.isPunctuation("-") {
                advance()
                try descend()
                levels += 1
                left = .binary(.minus, left, try multiplicative())
            } else {
                return left
            }
        }
    }

    private mutating func multiplicative() throws -> AdBlockJQSyntax {
        var left = try unary()
        var levels = 0
        defer { ascend(levels) }
        while true {
            let operation: AdBlockJQBinaryOperator
            if current.isPunctuation("*") {
                operation = .multiply
            } else if current.isPunctuation("/") {
                operation = .divide
            } else if current.isPunctuation("%") {
                operation = .modulo
            } else {
                return left
            }
            advance()
            try descend()
            levels += 1
            left = .binary(operation, left, try unary())
        }
    }

    private mutating func unary() throws -> AdBlockJQSyntax {
        if current.isPunctuation("-") {
            advance()
            try descend()
            defer { ascend() }
            return .negate(try multiplicative())
        }
        return try operand()
    }

     
     
    private mutating func operand() throws -> AdBlockJQSyntax {
        var result: AdBlockJQSyntax
        switch current.kind {
        case .keyword("reduce"):
            advance()
            let source = try term()
            try expectKeyword("as")
            let patterns = try self.patterns()
            try expect("(")
            let initial = try pipe()
            try expect(";")
            let update = try pipe()
            try expect(")")
            result = .reduce(source: source, patterns: patterns, initial: initial, update: update)
        case .keyword("foreach"):
            advance()
            let source = try term()
            try expectKeyword("as")
            let patterns = try self.patterns()
            try expect("(")
            let initial = try pipe()
            try expect(";")
            let update = try pipe()
            var extract: AdBlockJQSyntax?
            if current.isPunctuation(";") {
                advance()
                extract = try pipe()
            }
            try expect(")")
            result = .foreach(source: source, patterns: patterns, initial: initial, update: update, extract: extract)
        case .keyword("if"):
            advance()
            var branches: [(condition: AdBlockJQSyntax, then: AdBlockJQSyntax)] = []
            let condition = try pipe()
            try expectKeyword("then")
            branches.append((condition, try pipe()))
            var otherwise: AdBlockJQSyntax?
            while true {
                if current.isKeyword("elif") {
                    advance()
                    let next = try pipe()
                    try expectKeyword("then")
                    branches.append((next, try pipe()))
                } else if current.isKeyword("else") {
                    advance()
                    otherwise = try pipe()
                    try expectKeyword("end")
                    break
                } else {
                    try expectKeyword("end")
                    break
                }
            }
            result = .conditional(branches, otherwise: otherwise)
        case .keyword("try"):
            advance()
            try descend()
            defer { ascend() }
            let body = try unary()
            var handler: AdBlockJQSyntax?
            if current.isKeyword("catch") {
                advance()
                handler = try unary()
            }
            return .tryCatch(body, handler)
        case .keyword("label"):
            advance()
            guard case .variable(let name) = current.kind else { throw unexpected() }
            advance()
            try expect("|")
            return .label(name, try pipe())
        case .keyword("def"):
            let function = try definition()
            if atEnd { return .define(function, .identity) }
            return .define(function, try pipe())
        default:
            let source = try term()
            if current.isKeyword("as") {
                advance()
                let patterns = try self.patterns()
                try expect("|")
                return .bind(source: source, patterns: patterns, body: try pipe())
            }
            return source
        }
        var levels = 0
        defer { ascend(levels) }
        while current.isPunctuation("?") {
            advance()
            try descend()
            levels += 1
            result = .tryCatch(result, nil)
        }
        return result
    }

    private mutating func definition() throws -> AdBlockJQFunctionSyntax {
        try expectKeyword("def")
        guard case .identifier(let name) = current.kind else { throw unexpected() }
        advance()
        var parameters: [AdBlockJQFunctionSyntax.Parameter] = []
        if current.isPunctuation("(") {
            advance()
            while true {
                switch current.kind {
                case .variable(let parameter): parameters.append(.init(name: parameter, isValue: true))
                case .identifier(let parameter): parameters.append(.init(name: parameter, isValue: false))
                case .keyword(let parameter) where parameter != "__loc__": parameters.append(.init(name: parameter, isValue: false))
                default: throw unexpected()
                }
                advance()
                if current.isPunctuation(";") {
                    advance()
                    continue
                }
                try expect(")")
                break
            }
        }
        guard parameters.count <= AdBlockJQCompiler.maximumParameters else {
            throw AdBlockJQSyntaxError(message: "\(name) takes more than \(AdBlockJQCompiler.maximumParameters) parameters")
        }
        try expect(":")
        let body = try pipe()
        try expect(";")
        return AdBlockJQFunctionSyntax(name: name, parameters: parameters, body: body)
    }

     

    private mutating func term() throws -> AdBlockJQSyntax {
        try descend()
        defer { ascend() }
        var result: AdBlockJQSyntax
         
        var indexed = false
        switch current.kind {
        case .dot:
            advance()
            if case .string(let pieces) = current.kind {
                advance()
                result = .index(.identity, try string(pieces, format: nil))
                indexed = true
            } else {
                result = .identity
            }
        case .field(let name):
            advance()
            result = .index(.identity, .literal(.string(name)))
            indexed = true
        case .recurse:
            advance()
            result = .recurseDefault
        case .number(let number):
            advance()
            result = .literal(.number(number))
        case .string(let pieces):
            advance()
            result = try string(pieces, format: nil)
        case .format(let name):
            advance()
            if case .string(let pieces) = current.kind {
                advance()
                result = try string(pieces, format: name)
            } else {
                result = .format(name)
            }
        case .punctuation("("):
            advance()
            result = try pipe()
            try expect(")")
        case .punctuation("["):
            advance()
            if current.isPunctuation("]") {
                advance()
                result = .array(nil)
            } else {
                result = .array(try pipe())
                try expect("]")
            }
        case .punctuation("{"):
            advance()
            result = .object(try objectEntries())
        case .variable(let name):
            advance()
            result = .variable(name)
        case .keyword("break"):
            advance()
            guard case .variable(let name) = current.kind else { throw unexpected() }
            advance()
            result = .breakLabel(name)
        case .identifier(let name):
            advance()
            var arguments: [AdBlockJQSyntax] = []
            if !current.isPunctuation("("), name == "null" || name == "true" || name == "false" {
                result = .literal(name == "null" ? .null : .bool(name == "true"))
                break
            }
            if current.isPunctuation("(") {
                advance()
                while true {
                    arguments.append(try pipe())
                    if current.isPunctuation(";") {
                        advance()
                        continue
                    }
                    try expect(")")
                    break
                }
            }
            result = .call(name, arguments)
        default:
            throw unexpected()
        }
        return try suffixes(result, indexed: indexed)
    }

    private mutating func suffixes(_ start: AdBlockJQSyntax, indexed start_indexed: Bool) throws -> AdBlockJQSyntax {
        var result = start
        var indexed = start_indexed
        var levels = 0
        defer { ascend(levels) }
        while true {
            if case .end = current.kind { return result }
            try descend()
            levels += 1
            switch current.kind {
            case .field(let name):
                advance()
                result = .index(result, .literal(.string(name)))
                indexed = true
            case .dot:
                if case .string(let pieces) = peek(1).kind {
                    advance()
                    advance()
                    result = .index(result, try string(pieces, format: nil))
                    indexed = true
                } else if peek(1).isPunctuation("[") {
                    advance()
                } else {
                    return result
                }
            case .punctuation("["):
                advance()
                if current.isPunctuation("]") {
                    advance()
                    result = .iterate(result)
                } else if current.isPunctuation(":") {
                    advance()
                    let to = try pipe()
                    try expect("]")
                    result = .slice(result, nil, to)
                } else {
                    let key = try pipe()
                    if current.isPunctuation(":") {
                        advance()
                        if current.isPunctuation("]") {
                            advance()
                            result = .slice(result, key, nil)
                        } else {
                            let to = try pipe()
                            try expect("]")
                            result = .slice(result, key, to)
                        }
                    } else {
                        try expect("]")
                        result = .index(result, key)
                    }
                }
                indexed = true
            case .punctuation("?"):
                advance()
                result = indexed ? .optional(result) : .tryCatch(result, nil)
                indexed = false
            default:
                return result
            }
        }
    }

    private func string(_ pieces: [AdBlockJQToken.Piece], format: String?) throws -> AdBlockJQSyntax {
        var parts: [AdBlockJQStringPart] = []
        for piece in pieces {
            switch piece {
            case .text(let text):
                parts.append(.text(text))
            case .interpolation(let inner):
                var parser = AdBlockJQParser(inner, nesting: nesting)
                let expression = try parser.pipe()
                guard parser.atEnd else { throw parser.unexpected() }
                parts.append(.interpolation(expression))
            }
        }
        if format == nil, parts.count == 1, case .text(let text) = parts[0] { return .literal(.string(text)) }
        return .string(parts, format: format)
    }

     

    private mutating func objectEntries() throws -> [AdBlockJQObjectEntry] {
        var entries: [AdBlockJQObjectEntry] = []
        while !current.isPunctuation("}") {
            entries.append(try objectEntry())
            if current.isPunctuation(",") {
                advance()
                continue
            }
            guard current.isPunctuation("}") else { throw unexpected() }
        }
        advance()
        return entries
    }

    private mutating func objectEntry() throws -> AdBlockJQObjectEntry {
        switch current.kind {
        case .identifier(let name), .keyword(let name):
            advance()
            let key = AdBlockJQSyntax.literal(.string(name))
            if current.isPunctuation(":") {
                advance()
                return .pair(key: key, value: try valueExpression())
            }
            return .keyOnly(key)
        case .variable(let name):
            advance()
            if current.isPunctuation(":") {
                advance()
                return .pair(key: .variable(name), value: try valueExpression())
            }
            return .pair(key: .literal(.string(name)), value: .variable(name))
        case .string(let pieces):
            advance()
            let key = try string(pieces, format: nil)
            if current.isPunctuation(":") {
                advance()
                return .pair(key: key, value: try valueExpression())
            }
            return .keyOnly(key)
        case .format(let name):
            advance()
            guard case .string(let pieces) = current.kind else { throw unexpected() }
            advance()
            let key = try string(pieces, format: name)
            if current.isPunctuation(":") {
                advance()
                return .pair(key: key, value: try valueExpression())
            }
            return .keyOnly(key)
        case .punctuation("("):
            advance()
            let key = try pipe()
            try expect(")")
            try expect(":")
            return .pair(key: key, value: try valueExpression())
        default:
            throw unexpected()
        }
    }

     
    private mutating func valueExpression() throws -> AdBlockJQSyntax {
        try descend()
        defer { ascend() }
        if current.isPunctuation("-") {
            advance()
            return .negate(try valueExpression())
        }
        var stages = [try term()]
        while current.isPunctuation("|") {
            advance()
            if current.isPunctuation("-") {
                stages.append(try valueExpression())
                break
            }
            stages.append(try term())
        }
        return stages.count == 1 ? stages[0] : .pipe(stages)
    }

     

    private mutating func patterns() throws -> [AdBlockJQPattern] {
        var alternatives = [try pattern()]
        while current.isPunctuation("?//") {
            advance()
            alternatives.append(try pattern())
        }
        return alternatives
    }

    private mutating func pattern() throws -> AdBlockJQPattern {
        try descend()
        defer { ascend() }
        switch current.kind {
        case .variable(let name):
            advance()
            return .variable(name)
        case .punctuation("["):
            advance()
            var items: [AdBlockJQPattern] = []
            while true {
                items.append(try pattern())
                if current.isPunctuation(",") {
                    advance()
                    continue
                }
                try expect("]")
                break
            }
            return .array(items)
        case .punctuation("{"):
            advance()
            var entries: [AdBlockJQObjectPatternEntry] = []
            while true {
                entries.append(try objectPatternEntry())
                if current.isPunctuation(",") {
                    advance()
                    continue
                }
                try expect("}")
                break
            }
            return .object(entries)
        default:
            throw unexpected()
        }
    }

    private mutating func objectPatternEntry() throws -> AdBlockJQObjectPatternEntry {
        switch current.kind {
        case .variable(let name):
            advance()
            if current.isPunctuation(":") {
                advance()
                return AdBlockJQObjectPatternEntry(key: .variable(name), pattern: try pattern())
            }
            return AdBlockJQObjectPatternEntry(key: .variable(name), pattern: nil)
        case .identifier(let name), .keyword(let name):
            advance()
            try expect(":")
            return AdBlockJQObjectPatternEntry(key: .expression(.literal(.string(name))), pattern: try pattern())
        case .string(let pieces):
            advance()
            let key = try string(pieces, format: nil)
            try expect(":")
            return AdBlockJQObjectPatternEntry(key: .expression(key), pattern: try pattern())
        case .punctuation("("):
            advance()
            let key = try pipe()
            try expect(")")
            try expect(":")
            return AdBlockJQObjectPatternEntry(key: .expression(key), pattern: try pattern())
        default:
            throw unexpected()
        }
    }
}
#endif
