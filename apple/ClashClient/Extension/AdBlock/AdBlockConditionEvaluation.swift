#if os(iOS) || os(macOS)
import Foundation

 
 
 
 
 
 
 
 
 
 

 
struct AdBlockMessageView {
    var urls: AdBlockRequestURLs
    var method: String
    var requestHeaders: AdBlockHTTPHeaders
    var responseStatus: Int?
    var responseHeaders: AdBlockHTTPHeaders?

    init(urls: AdBlockRequestURLs, method: String, requestHeaders: AdBlockHTTPHeaders = AdBlockHTTPHeaders(),
         responseStatus: Int? = nil, responseHeaders: AdBlockHTTPHeaders? = nil) {
        self.urls = urls
        self.method = method
        self.requestHeaders = requestHeaders
        self.responseStatus = responseStatus
        self.responseHeaders = responseHeaders
    }

     
     
     
    static func value(_ name: String, in headers: AdBlockHTTPHeaders?) -> String? {
        guard let values = headers?.values(name), !values.isEmpty else { return nil }
        return values.joined(separator: ", ")
    }
}

enum AdBlockConditionEvaluation {
     
     
    struct Captures: Equatable {
        var named: [String: [String]] = [:]
    }

     
     
    indirect enum Compiled {
        case all([Compiled])
        case any([Compiled])
         
         
        case gate(capture: String?)
        case regex(AdBlockConditionVariable, NSRegularExpression, capture: String?)
        case equals(AdBlockConditionVariable, AdBlockConditionValue)
    }

     
    struct Refusal: Error {
        let reason: String
    }

     
     
     
    static func compile(_ condition: AdBlockCondition, gate: String?,
                        compile: (String) throws -> NSRegularExpression) throws -> Compiled {
        switch condition {
        case .all(let parts): return .all(try parts.map { try self.compile($0, gate: gate, compile: compile) })
        case .any(let parts): return .any(try parts.map { try self.compile($0, gate: gate, compile: compile) })
        case .match(let variable, .regexSearch, .regex(let pattern), let capture):
            if variable == .url, let gate, !gate.isEmpty, pattern == gate { return .gate(capture: capture) }
            return .regex(variable, try compile(pattern), capture: capture)
        case .match(let variable, .regexSearch, let value, let capture):
             
            guard case .string(let text) = value else { throw Refusal(reason: "a `~=` against \(value) is no regex") }
            return .regex(variable, try compile(NSRegularExpression.escapedPattern(for: text)), capture: capture)
        case .match(let variable, .equals, let value, _):
            return .equals(variable, value)
        }
    }

     
    static func regexCount(_ compiled: Compiled) -> Int {
        switch compiled {
        case .all(let parts), .any(let parts): return parts.reduce(0) { $0 + regexCount($1) }
        case .regex: return 1
        case .gate, .equals: return 0
        }
    }

     
     
    static func readsRequestHeaders(_ compiled: Compiled) -> Bool {
        switch compiled {
        case .all(let parts), .any(let parts): return parts.contains { readsRequestHeaders($0) }
        case .regex(.requestHeader, _, _), .equals(.requestHeader, _): return true
        case .gate, .regex, .equals: return false
        }
    }

     
     
    struct GateMatch {
        let url: String
        let match: NSTextCheckingResult
    }

     
    enum Outcome: Equatable {
        case holds(Captures)
        case fails
         
         
        case budgetSpent
         
         
        case timedOut
    }

     
     
     
     
    static func evaluate(_ condition: Compiled, in view: AdBlockMessageView, gate: GateMatch?,
                         budget: inout AdBlockRequestBudget) -> Outcome {
        var captures = Captures()
        let outcome = evaluate(condition, view, gate, &captures, &budget)
        switch outcome {
        case .holds: return .holds(captures)
        default: return outcome
        }
    }

    private static func evaluate(_ condition: Compiled, _ view: AdBlockMessageView, _ gate: GateMatch?, _ captures: inout Captures,
                                 _ budget: inout AdBlockRequestBudget) -> Outcome {
        switch condition {
        case .all(let parts):
            for part in parts {
                let outcome = evaluate(part, view, gate, &captures, &budget)
                guard case .holds = outcome else { return outcome }
            }
            return .holds(captures)
        case .any(let parts):
            var stopped: Outcome?
            for part in parts {
                 
                var branch = captures
                switch evaluate(part, view, gate, &branch, &budget) {
                case .holds:
                    captures = branch
                    return .holds(captures)
                case .fails: continue
                case let other: stopped = stopped ?? other
                }
            }
            return stopped ?? .fails
        case .gate(let capture):
            guard let gate else { return .fails }
            if let capture { captures.named[capture] = groups(of: gate.match, in: gate.url) }
            return .holds(captures)
        case .regex(let variable, let regex, let capture):
            guard let subject = text(of: variable, in: view, url: gate?.url) else { return .fails }
            guard !budget.isSpent else {
                budget.noteStop()
                return .budgetSpent
            }
            let allowed = min(AdBlockGatedMatcher.evaluationDeadline, budget.remainingSeconds)
            let started = AdBlockRequestBudget.threadNanoseconds()
            let evaluation = AdBlockGatedMatcher.evaluate(regex, on: subject, deadline: allowed)
            budget.charge(AdBlockRequestBudget.threadNanoseconds() &- started)
            switch evaluation {
            case .match(let match):
                if let capture { captures.named[capture] = groups(of: match, in: subject) }
                return .holds(captures)
            case .noMatch:
                return .fails
            case .timedOut where allowed < AdBlockGatedMatcher.evaluationDeadline:
                budget.noteStop()
                return .budgetSpent
            case .timedOut:
                return .timedOut
            }
        case .equals(let variable, let value):
            return equals(variable, value, view, url: gate?.url) ? .holds(captures) : .fails
        }
    }

     
     
    static func text(of variable: AdBlockConditionVariable, in view: AdBlockMessageView, url: String?) -> String? {
        switch variable {
        case .url: return url ?? view.urls.primary
        case .requestMethod: return view.method
        case .requestHeader(let name): return AdBlockMessageView.value(name, in: view.requestHeaders)
        case .responseStatus: return view.responseStatus.map(String.init)
        case .responseHeader(let name): return AdBlockMessageView.value(name, in: view.responseHeaders)
        }
    }

     
     
     
     
    private static func equals(_ variable: AdBlockConditionVariable, _ value: AdBlockConditionValue, _ view: AdBlockMessageView,
                               url: String?) -> Bool {
        let subject = text(of: variable, in: view, url: url)
        switch value {
        case .null:
            return subject == nil
        case .string(let text):
            return subject == text
        case .number(let number):
            if case .responseStatus = variable, let status = view.responseStatus { return Double(status) == number }
            guard let subject, let read = Double(subject.trimmingCharacters(in: .whitespaces)) else { return false }
            return read == number
        case .regex(let pattern):
             
            return subject == pattern
        }
    }

     
    static func groups(of match: NSTextCheckingResult, in text: String) -> [String] {
        let source = text as NSString
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : source.substring(with: range)
        }
    }

     
     
     
     
     
     
    static func holds(_ condition: AdBlockCondition, in view: AdBlockMessageView,
                      deadline: TimeInterval = AdBlockGatedMatcher.evaluationDeadline) -> Captures? {
        guard let compiled = try? compile(condition, gate: nil, compile: { try NSRegularExpression(pattern: $0) }) else { return nil }
        var budget = AdBlockRequestBudget(seconds: max(deadline, 0) * Double(max(1, regexCount(compiled))))
        if case .holds(let captures) = evaluate(compiled, in: view, gate: nil, budget: &budget) { return captures }
        return nil
    }
}
#endif
