#if os(iOS) || os(macOS)
import Foundation

 
 
 
 

 

indirect enum AdBlockJQNode {
    case identity
    case recurseDefault
    case field(AdBlockJQNode, String, optional: Bool)
    case index(AdBlockJQNode, AdBlockJQNode, optional: Bool)
    case slice(AdBlockJQNode, AdBlockJQNode?, AdBlockJQNode?, optional: Bool)
    case iterate(AdBlockJQNode, optional: Bool)
    case literal(AdBlockJSONValue)
    case string([AdBlockJQCompiledPart], format: String?)
    case format(String)
    case collect(AdBlockJQNode)
    case object([AdBlockJQCompiledEntry])
    case negate(AdBlockJQNode)
     
    case pipe([AdBlockJQNode])
     
    case comma([AdBlockJQNode])
    case binary(AdBlockJQBinaryOperator, AdBlockJQNode, AdBlockJQNode)
    case and(AdBlockJQNode, AdBlockJQNode)
    case or(AdBlockJQNode, AdBlockJQNode)
    case alternative(AdBlockJQNode, AdBlockJQNode)
    case update(AdBlockJQUpdateOperator, AdBlockJQNode, AdBlockJQNode)
     
    case conditional([AdBlockJQBranch], AdBlockJQNode?)
    case tryCatch(AdBlockJQNode, AdBlockJQNode?)
    case reduce(AdBlockJQNode, AdBlockJQPatterns, AdBlockJQNode, AdBlockJQNode)
    case foreach(AdBlockJQNode, AdBlockJQPatterns, AdBlockJQNode, AdBlockJQNode, AdBlockJQNode?)
    case define(AdBlockJQFunction, AdBlockJQNode)
    case callUser(hops: Int, arguments: [AdBlockJQNode])
    case callParameter(hops: Int)
    case callBuiltin(AdBlockJQBuiltinReference, arguments: [AdBlockJQNode])
    case callNative(AdBlockJQNative, arguments: [AdBlockJQNode])
    case variable(hops: Int)
    case bind(AdBlockJQNode, AdBlockJQPatterns, AdBlockJQNode)
    case label(AdBlockJQNode)
    case breakLabel(hops: Int)
     
     
     
    case scalar(AdBlockJQNode)

     
     
    var givesOneOutput: Bool {
        switch self {
        case .identity, .literal, .variable, .format, .collect, .scalar:
            return true
        case .field(let target, _, let optional):
            return !optional && target.givesOneOutput
        case .index(let target, let key, let optional):
            return !optional && target.givesOneOutput && key.givesOneOutput
        case .slice(let target, let from, let to, let optional):
            return !optional && target.givesOneOutput && (from?.givesOneOutput ?? true) && (to?.givesOneOutput ?? true)
        case .string(let parts, _):
            return parts.allSatisfy { part in
                if case .interpolation(let inner) = part { return inner.givesOneOutput }
                return true
            }
        case .object(let entries):
            return entries.allSatisfy { entry in
                switch entry {
                case .pair(let key, let value): return key.givesOneOutput && value.givesOneOutput
                case .keyOnly(let key): return key.givesOneOutput
                }
            }
        case .negate(let inner):
            return inner.givesOneOutput
        case .pipe(let stages):
            return stages.allSatisfy(\.givesOneOutput)
        case .binary(_, let a, let b), .and(let a, let b), .or(let a, let b), .alternative(let a, let b):
            return a.givesOneOutput && b.givesOneOutput
        case .conditional(let branches, let otherwise):
            return branches.allSatisfy { $0.condition.givesOneOutput && $0.then.givesOneOutput } && (otherwise?.givesOneOutput ?? true)
        case .update(let operation, _, let right):
            if case .modify = operation { return true }
            return right.givesOneOutput
        case .reduce(_, _, let initial, _):
            return initial.givesOneOutput
        case .define(_, let rest):
            return rest.givesOneOutput
        case .bind(let source, let patterns, let body):
            return patterns.alternatives.count == 1 && patterns.keysGiveOneOutput && source.givesOneOutput && body.givesOneOutput
        case .callNative(let native, let arguments):
            return native.givesOneOutput(arguments)
        default:
            return false
        }
    }

     
    var isSingle: Bool {
        switch self {
        case .scalar, .identity, .literal, .variable: return true
        default: return false
        }
    }

     
     
     
     
     
     
     
     
     
    var givesAtMostOneOutput: Bool {
        var work: [AdBlockJQNode] = [self]
        var seen: Set<ObjectIdentifier> = []
        while let node = work.popLast() {
            if node.isSingle { continue }
            switch node {
            case .field(let target, _, _):
                work.append(target)
            case .index(let target, let key, _):
                work.append(target)
                work.append(key)
            case .slice(let target, let from, let to, _):
                work.append(target)
                if let from { work.append(from) }
                if let to { work.append(to) }
            case .pipe(let stages):
                work.append(contentsOf: stages)
            case .negate(let inner):
                work.append(inner)
            case .binary(_, let a, let b), .and(let a, let b), .or(let a, let b):
                work.append(a)
                work.append(b)
            case .object(let entries):
                for entry in entries {
                    switch entry {
                    case .pair(let key, let value):
                        work.append(key)
                        work.append(value)
                    case .keyOnly(let key):
                        work.append(key)
                    }
                }
            case .string(let parts, _):
                for case .interpolation(let inner) in parts { work.append(inner) }
            case .conditional(let branches, let otherwise):
                for branch in branches {
                    guard branch.condition.isSingle else { return false }
                    work.append(branch.then)
                }
                if let otherwise { work.append(otherwise) }
            case .tryCatch(let body, let handler):
                work.append(body)
                if let handler { work.append(handler) }
            case .alternative(let a, let b):
                work.append(a)
                work.append(b)
            case .label(let body), .define(_, let body):
                work.append(body)
            case .breakLabel:
                break
            case .bind(let source, let patterns, let body):
                guard patterns.alternatives.count == 1, patterns.keysGiveOneOutput else { return false }
                work.append(source)
                work.append(body)
            case .callNative(let native, let arguments):
                switch native {
                case .empty, .error, .first: break
                case .select: guard arguments[0].isSingle else { return false }
                default: return false
                }
            case .callBuiltin(let reference, let arguments):
                guard let function = reference.function else { return false }
                 
                if function.name == "error", function.parameters.count == 1 { break }
                 
                guard arguments.isEmpty else { return false }
                if seen.insert(ObjectIdentifier(function)).inserted { work.append(function.body) }
            default:
                return false
            }
        }
        return true
    }
}

struct AdBlockJQBranch {
    let condition: AdBlockJQNode
    let then: AdBlockJQNode
}

enum AdBlockJQCompiledPart {
    case text(String)
    case interpolation(AdBlockJQNode)
}

enum AdBlockJQCompiledEntry {
    case pair(key: AdBlockJQNode, value: AdBlockJQNode)
    case keyOnly(AdBlockJQNode)
}

struct AdBlockJQPatterns {
    let alternatives: [AdBlockJQPatternNode]
    let variableCount: Int

     
     
    var keysGiveOneOutput: Bool {
        var work = alternatives
        while let pattern = work.popLast() {
            switch pattern {
            case .variable: break
            case .array(let items): work.append(contentsOf: items)
            case .object(let entries):
                for entry in entries {
                    if case .expression(let key) = entry.key, !key.givesOneOutput { return false }
                    if let inner = entry.pattern { work.append(inner) }
                }
            }
        }
        return true
    }
}

indirect enum AdBlockJQPatternNode {
    case variable(slot: Int)
    case array([AdBlockJQPatternNode])
    case object([(key: AdBlockJQPatternKey, pattern: AdBlockJQPatternNode?)])
}

enum AdBlockJQPatternKey {
     
    case variable(name: String, slot: Int)
    case expression(AdBlockJQNode)
}

final class AdBlockJQFunction: @unchecked Sendable {
    let name: String
    let parameters: [AdBlockJQFunctionSyntax.Parameter]
     
    let valued: [Int]
    var body: AdBlockJQNode = .identity

    init(name: String, parameters: [AdBlockJQFunctionSyntax.Parameter]) {
        self.name = name
        self.parameters = parameters
        valued = parameters.indices.filter { parameters[$0].isValue }
    }
}

 
 
final class AdBlockJQBuiltinReference: @unchecked Sendable {
    var function: AdBlockJQFunction!
}

 

struct AdBlockJQCompiler {
    final class Scope {
        enum Kind {
            case variable(String)
            case function(String, Int, AdBlockJQFunction)
            case parameter(String)
            case label(String)
        }

         
        private(set) var parent: Scope?
        let kind: Kind

        init(_ parent: Scope?, _ kind: Kind) {
            self.parent = parent
            self.kind = kind
        }

        deinit {
            var next = parent
            parent = nil
            while isKnownUniquelyReferenced(&next) {
                let following = next!.parent
                next!.parent = nil
                next = following
            }
        }
    }

     
     
     
     
    static let maximumPatternVariables = 256
    static let maximumParameters = 256

     
    var preludeReferences: [String: AdBlockJQBuiltinReference]
     
     
    private let stackFloor = AdBlockJQStack.floor(reserve: AdBlockJQStack.readReserve)

    init(preludeReferences: [String: AdBlockJQBuiltinReference]) {
        self.preludeReferences = preludeReferences
    }

    func compile(_ syntax: AdBlockJQSyntax, _ scope: Scope?) throws -> AdBlockJQNode {
        guard AdBlockJQStack.address() >= stackFloor else {
            throw AdBlockJQSyntaxError(message: "the program nests too deep for the thread's stack")
        }
        let node = try compileForm(syntax, scope)
        if node.isSingle || !node.givesOneOutput { return node }
        return .scalar(node)
    }

    private func compileForm(_ syntax: AdBlockJQSyntax, _ scope: Scope?) throws -> AdBlockJQNode {
        switch syntax {
        case .identity:
            return .identity
        case .recurseDefault:
            return .recurseDefault
        case .index(let target, let key):
            if case .literal(.string(let name)) = key { return .field(try compile(target, scope), name, optional: false) }
            return .index(try compile(target, scope), try compile(key, scope), optional: false)
        case .slice(let target, let from, let to):
            return .slice(try compile(target, scope), try from.map { try compile($0, scope) }, try to.map { try compile($0, scope) },
                          optional: false)
        case .iterate(let target):
            return .iterate(try compile(target, scope), optional: false)
        case .optional(let inner):
            var compiled = try compile(inner, scope)
            if case .scalar(let unwrapped) = compiled { compiled = unwrapped }
            switch compiled {
            case .field(let target, let name, _): return .field(target, name, optional: true)
            case .index(let target, let key, _): return .index(target, key, optional: true)
            case .slice(let target, let from, let to, _): return .slice(target, from, to, optional: true)
            case .iterate(let target, _): return .iterate(target, optional: true)
            case let other: return .tryCatch(other, nil)
            }
        case .literal(let value):
             
            AdBlockJSONObject.settleSortedKeys(in: value)
            return .literal(value)
        case .string(let parts, let format):
            return .string(try parts.map { part in
                switch part {
                case .text(let text): return .text(text)
                case .interpolation(let inner): return .interpolation(try compile(inner, scope))
                }
            }, format: format)
        case .format(let name):
            return .format(name)
        case .array(let inner):
            guard let inner else { return .literal(.emptyArray) }
            return .collect(try compile(inner, scope))
        case .object(let entries):
            return .object(try entries.map { entry in
                switch entry {
                case .pair(let key, let value):
                     
                    if case .literal(let constant) = key, constant.stringValue == nil {
                        throw AdBlockJQSyntaxError(message: "Cannot use \(constant.typeName) (\(AdBlockJQMachine.dump(constant))) as object key")
                    }
                    return .pair(key: try compile(key, scope), value: try compile(value, scope))
                case .keyOnly(let key): return .keyOnly(try compile(key, scope))
                }
            })
        case .negate(let inner):
            return .negate(try compile(inner, scope))
        case .pipe(let stages):
            return .pipe(try stages.map { try compile($0, scope) })
        case .comma(let items):
            return .comma(try items.map { try compile($0, scope) })
        case .binary(let operation, let a, let b):
            return .binary(operation, try compile(a, scope), try compile(b, scope))
        case .and(let a, let b):
            return .and(try compile(a, scope), try compile(b, scope))
        case .or(let a, let b):
            return .or(try compile(a, scope), try compile(b, scope))
        case .alternative(let a, let b):
            return .alternative(try compile(a, scope), try compile(b, scope))
        case .update(let operation, let a, let b):
            return .update(operation, try compile(a, scope), try compile(b, scope))
        case .conditional(let branches, let otherwise):
            return .conditional(try branches.map { AdBlockJQBranch(condition: try compile($0.condition, scope), then: try compile($0.then, scope)) },
                                try otherwise.map { try compile($0, scope) })
        case .tryCatch(let body, let handler):
            return .tryCatch(try compile(body, scope), try handler.map { try compile($0, scope) })
        case .reduce(let source, let patterns, let initial, let update):
            let (compiled, inner) = try compilePatterns(patterns, scope)
            return .reduce(try compile(source, scope), compiled, try compile(initial, scope), try compile(update, inner))
        case .foreach(let source, let patterns, let initial, let update, let extract):
            let (compiled, inner) = try compilePatterns(patterns, scope)
            return .foreach(try compile(source, scope), compiled, try compile(initial, scope), try compile(update, inner),
                            try extract.map { try compile($0, inner) })
        case .define(let definition, let rest):
            let function = AdBlockJQFunction(name: definition.name, parameters: definition.parameters)
            let defined = Scope(scope, .function(definition.name, definition.parameters.count, function))
            function.body = try compile(definition.body, Self.parameterScope(definition.parameters, defined))
            return .define(function, try compile(rest, defined))
        case .call(let name, let arguments):
            return try resolveCall(name, arguments, scope)
        case .variable(let name):
            var hops = 0
            var node = scope
            while let current = node {
                if case .variable(let bound) = current.kind, bound == name { return .variable(hops: hops) }
                hops += 1
                node = current.parent
            }
            if name == "ENV" { return .literal(.emptyObject) }
            if name == "__loc__" {
                throw AdBlockJQSyntaxError(message: "$__loc__ is not supported in a module's jq")
            }
            throw AdBlockJQSyntaxError(message: "$\(name) is not defined")
        case .bind(let source, let patterns, let body):
            let (compiled, inner) = try compilePatterns(patterns, scope)
            return .bind(try compile(source, scope), compiled, try compile(body, inner))
        case .label(let name, let body):
            return .label(try compile(body, Scope(scope, .label(name))))
        case .breakLabel(let name):
            var hops = 0
            var node = scope
            while let current = node {
                if case .label(let bound) = current.kind, bound == name { return .breakLabel(hops: hops) }
                hops += 1
                node = current.parent
            }
            throw AdBlockJQSyntaxError(message: "$*label-\(name) is not defined")
        }
    }

     
    static func parameterScope(_ parameters: [AdBlockJQFunctionSyntax.Parameter], _ scope: Scope?) -> Scope? {
        var inner = scope
        for parameter in parameters { inner = Scope(inner, .parameter(parameter.name)) }
        for parameter in parameters where parameter.isValue { inner = Scope(inner, .variable(parameter.name)) }
        return inner
    }

    private func resolveCall(_ name: String, _ arguments: [AdBlockJQSyntax], _ scope: Scope?) throws -> AdBlockJQNode {
        let arity = arguments.count
        var hops = 0
        var node = scope
        while let current = node {
            switch current.kind {
            case .function(let bound, let boundArity, _) where bound == name && boundArity == arity:
                return .callUser(hops: hops, arguments: try arguments.map { try compile($0, scope) })
            case .parameter(let bound) where bound == name:
                if arity == 0 { return .callParameter(hops: hops) }
            default:
                break
            }
            hops += 1
            node = current.parent
        }
        let key = "\(name)/\(arity)"
        if let native = AdBlockJQNative.byName[key] {
            let compiled = try arguments.map { try compile($0, scope) }
            return .callNative(AdBlockJQNative.proved(native, compiled), arguments: compiled)
        }
        if let reference = preludeReferences[key] {
            return .callBuiltin(reference, arguments: try arguments.map { try compile($0, scope) })
        }
        if AdBlockJQNative.leftOut.contains(name) {
            throw AdBlockJQSyntaxError(message: "\(key) is not supported in a module's jq")
        }
        throw AdBlockJQSyntaxError(message: "\(key) is not defined")
    }

    private func compilePatterns(_ patterns: [AdBlockJQPattern], _ scope: Scope?) throws -> (AdBlockJQPatterns, Scope?) {
        var names: [String] = []
        for pattern in patterns {
            for name in pattern.variables where !names.contains(name) { names.append(name) }
        }
        func slot(_ name: String) -> Int { names.firstIndex(of: name)! }
        func compilePattern(_ pattern: AdBlockJQPattern) throws -> AdBlockJQPatternNode {
            switch pattern {
            case .variable(let name):
                return .variable(slot: slot(name))
            case .array(let items):
                return .array(try items.map(compilePattern))
            case .object(let entries):
                return .object(try entries.map { entry in
                    let key: AdBlockJQPatternKey
                    switch entry.key {
                    case .variable(let name): key = .variable(name: name, slot: slot(name))
                    case .expression(let expression): key = .expression(try compile(expression, scope))
                    }
                    return (key, try entry.pattern.map(compilePattern))
                })
            }
        }
         
        guard names.count <= Self.maximumPatternVariables else {
            throw AdBlockJQSyntaxError(message: "a pattern binds more than \(Self.maximumPatternVariables) variables")
        }
        let compiled = try patterns.map(compilePattern)
        var inner = scope
        for name in names { inner = Scope(inner, .variable(name)) }
        return (AdBlockJQPatterns(alternatives: compiled, variableCount: names.count), inner)
    }
}
#endif
