#if os(iOS) || os(macOS)
import Foundation

 
 
 

indirect enum AdBlockJQSyntax {
     
    case identity
     
    case recurseDefault
     
     
    case index(AdBlockJQSyntax, AdBlockJQSyntax)
     
    case slice(AdBlockJQSyntax, AdBlockJQSyntax?, AdBlockJQSyntax?)
     
    case iterate(AdBlockJQSyntax)
     
     
     
    case optional(AdBlockJQSyntax)
    case literal(AdBlockJSONValue)
     
    case string([AdBlockJQStringPart], format: String?)
     
    case format(String)
     
    case array(AdBlockJQSyntax?)
    case object([AdBlockJQObjectEntry])
     
    case negate(AdBlockJQSyntax)
     
     
    case pipe([AdBlockJQSyntax])
     
    case comma([AdBlockJQSyntax])
    case binary(AdBlockJQBinaryOperator, AdBlockJQSyntax, AdBlockJQSyntax)
    case and(AdBlockJQSyntax, AdBlockJQSyntax)
    case or(AdBlockJQSyntax, AdBlockJQSyntax)
     
    case alternative(AdBlockJQSyntax, AdBlockJQSyntax)
     
    case update(AdBlockJQUpdateOperator, AdBlockJQSyntax, AdBlockJQSyntax)
     
    case conditional([(condition: AdBlockJQSyntax, then: AdBlockJQSyntax)], otherwise: AdBlockJQSyntax?)
     
    case tryCatch(AdBlockJQSyntax, AdBlockJQSyntax?)
    case reduce(source: AdBlockJQSyntax, patterns: [AdBlockJQPattern], initial: AdBlockJQSyntax, update: AdBlockJQSyntax)
    case foreach(source: AdBlockJQSyntax, patterns: [AdBlockJQPattern], initial: AdBlockJQSyntax, update: AdBlockJQSyntax,
                 extract: AdBlockJQSyntax?)
     
    case define(AdBlockJQFunctionSyntax, AdBlockJQSyntax)
    case call(String, [AdBlockJQSyntax])
    case variable(String)
     
    case bind(source: AdBlockJQSyntax, patterns: [AdBlockJQPattern], body: AdBlockJQSyntax)
    case label(String, AdBlockJQSyntax)
    case breakLabel(String)
}

enum AdBlockJQStringPart {
    case text(String)
    case interpolation(AdBlockJQSyntax)
}

enum AdBlockJQObjectEntry {
     
    case pair(key: AdBlockJQSyntax, value: AdBlockJQSyntax)
     
    case keyOnly(AdBlockJQSyntax)
}

enum AdBlockJQBinaryOperator: String, Sendable {
    case plus = "+", minus = "-", multiply = "*", divide = "/", modulo = "%"
    case equal = "==", notEqual = "!=", less = "<", lessOrEqual = "<=", greater = ">", greaterOrEqual = ">="
}

enum AdBlockJQUpdateOperator: Sendable {
     
    case assign
     
    case modify
     
    case arithmetic(AdBlockJQBinaryOperator)
     
    case alternative
}

indirect enum AdBlockJQPattern {
    case variable(String)
    case array([AdBlockJQPattern])
    case object([AdBlockJQObjectPatternEntry])

     
    var variables: [String] {
        var names: [String] = []
        func visit(_ pattern: AdBlockJQPattern) {
            switch pattern {
            case .variable(let name):
                if !names.contains(name) { names.append(name) }
            case .array(let items):
                items.forEach(visit)
            case .object(let entries):
                for entry in entries {
                    if case .variable(let name) = entry.key, !names.contains(name) { names.append(name) }
                    if let value = entry.pattern { visit(value) }
                }
            }
        }
        visit(self)
        return names
    }
}

struct AdBlockJQObjectPatternEntry {
    enum Key {
         
        case variable(String)
         
        case expression(AdBlockJQSyntax)
    }

    let key: Key
    let pattern: AdBlockJQPattern?
}

struct AdBlockJQFunctionSyntax {
    struct Parameter {
        let name: String
         
        let isValue: Bool
    }

    let name: String
    let parameters: [Parameter]
    let body: AdBlockJQSyntax
}
#endif
