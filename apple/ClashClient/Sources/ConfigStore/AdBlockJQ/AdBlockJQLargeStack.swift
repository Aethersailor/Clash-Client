#if os(iOS) || os(macOS)
import Foundation

 
 
 
 
 
 
 
 
 

extension AdBlockJQ {
     
    static let largeStackBytes = 8 << 20

     
     
     
     
    static func parseOnLargeStack(_ text: String) throws -> Program {
        try AdBlockJQLargeStack.shared.run { try read(text) }.get()
    }

     
    static func parseOnLargeStack(_ text: String) async throws -> Program {
        try await AdBlockJQLargeStack.shared.run { try read(text) }.get()
    }

     
     
     
    static let noProgram = #"Top-level program not given (try ".")"#

     
     
     
     
     
     
     
    private static func read(_ text: String) throws -> Program {
        let program = try parse(text)
        let tokens: [AdBlockJQToken]
        do {
            tokens = try AdBlockJQLexer.tokens(text)
        } catch let error as AdBlockJQSyntaxError {
            throw ParseError(message: error.message)
        }
        let written = tokens.filter { if case .end = $0.kind { return false } else { return true } }
        guard let last = written.last else { throw ParseError(message: noProgram) }
         
        if last.isPunctuation(";") {
            if let syntax = try? AdBlockJQParser.parse(text), definitionsOnly(syntax) { throw ParseError(message: noProgram) }
            let end = tokens.last ?? last
            throw ParseError(message: "syntax error, unexpected \(end.spelling) at line \(end.line)")
        }
        return program
    }

     
    private static func definitionsOnly(_ syntax: AdBlockJQSyntax) -> Bool {
        switch syntax {
        case .define(_, let body): return definitionsOnly(body)
        case .identity: return true
        default: return false
        }
    }
}

 
 
final class AdBlockJQLargeStack: @unchecked Sendable {
    static let shared = AdBlockJQLargeStack(name: "adblock.jq.read")
     
     
    static let moduleReads = AdBlockJQLargeStack(name: "adblock.module.read")

    private let name: String
    private let condition = NSCondition()
    private var jobs: [() -> Void] = []
    private var thread: Thread?

     
     
    func run<T>(_ work: @escaping () throws -> T) -> Result<T, Error> {
        condition.lock()
        let onIt = thread != nil && Thread.current === thread
        condition.unlock()
        if onIt { return Result { try work() } }
        let done = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        enqueue {
            result = Result { try work() }
            done.signal()
        }
        done.wait()
        return result!
    }

    func run<T>(_ work: @escaping () throws -> T) async -> Result<T, Error> {
        await withCheckedContinuation { finished in
            enqueue { finished.resume(returning: Result { try work() }) }
        }
    }

    init(name: String) {
        self.name = name
    }

    private func enqueue(_ job: @escaping () -> Void) {
        condition.lock()
        jobs.append(job)
        if thread == nil {
            let started = Thread { [unowned self] in self.serve() }
            started.stackSize = AdBlockJQ.largeStackBytes
            started.name = name
            thread = started
            started.start()
        }
        condition.signal()
        condition.unlock()
    }

    private func serve() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            job()
        }
    }
}
#endif
