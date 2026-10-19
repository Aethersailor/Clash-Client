#if os(iOS) || os(macOS)
import Foundation

 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 

 

 
 
 
struct AdBlockJQGathered {
    private(set) var items: [AdBlockJSONValue] = []
    private(set) var deepest = 0
    private var strings = 0
    private var checked = 0

    mutating func append(_ value: AdBlockJSONValue, _ machine: AdBlockJQMachine) throws {
        try machine.checkDepth(building: value.depth + 1)
        try machine.beforeAppend(to: items, holding: strings)
        items.append(value)
        deepest = max(deepest, value.depth)
        strings &+= AdBlockJSONLedger.stringBytes(value)
        let bytes = AdBlockJSONLedger.arrayBytes(capacity: items.capacity) &+ strings
        if bytes &- checked > 64 << 10 || items.count & 1023 == 0 {
            try machine.reserve(bytes)
            checked = bytes
        }
    }

     
    func array(_ machine: AdBlockJQMachine) throws -> AdBlockJSONValue {
        try machine.reserve(AdBlockJSONLedger.arrayBytes(capacity: items.count) &+ strings)
        return .array(AdBlockJSONArray(items, childDepth: deepest))
    }
}

 

 
final class AdBlockJQMachine {
    typealias Value = AdBlockJSONValue
    typealias Emit = (Value, AdBlockJQPath?) throws -> Void

    let limits: AdBlockJQ.Limits
    var budget: AdBlockRequestBudget
    let log: (String) -> Void
     
     
     
    private let counters: UnsafeMutablePointer<Int>
    private var remaining: Int {
        get { counters[0] }
        set { counters[0] = newValue }
    }
    private var callDepth: Int {
        get { counters[1] }
        set { counters[1] = newValue }
    }
    private var nextToken: Int {
        get { counters[2] }
        set { counters[2] = newValue }
    }
    private var nextLabel: Int {
        get { counters[3] }
        set { counters[3] = newValue }
    }
    var stepsTaken: Int { max(1, limits.steps) - counters[0] }
    let runStarted: UInt64
     
    let ledger: AdBlockJSONLedger
    private let memoryCap: Int
    private let footprintStart: Int64
     
     
     
     
    private let backstopBytes: Int64
    private(set) var stoppedByBackstop = false
     
     
     
    private(set) var stoppedByBudget = false
    private let stackFloor: UInt
    var regexes: [String: NSRegularExpression] = [:]

    init(limits: AdBlockJQ.Limits, budget: AdBlockRequestBudget, ledger: AdBlockJSONLedger, log: @escaping (String) -> Void) {
        self.limits = limits
        self.budget = budget
        self.ledger = ledger
        self.log = log
        counters = UnsafeMutablePointer<Int>.allocate(capacity: 4)
        counters.initialize(repeating: 0, count: 4)
        counters[0] = max(1, limits.steps)
        runStarted = AdBlockRequestBudget.threadNanoseconds()
        memoryCap = limits.memoryBytes
        footprintStart = AdBlockJQMachine.footprint()
        backstopBytes = Int64(limits.backstopBytes)
        stackFloor = AdBlockJQStack.floor(reserve: AdBlockJQStack.runReserve)
    }

    deinit {
        counters.deallocate()
    }

     
    func settle() -> AdBlockRequestBudget {
        ledgerPeak = max(ledgerPeak, ledger.total)
        var settled = budget
        settled.charge(AdBlockRequestBudget.threadNanoseconds() &- runStarted)
        return settled
    }

    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

     

    @inline(__always)
    func tick() throws {
        let left = counters[0] &- 1
        counters[0] = left
        if left & 1023 == 0 { try checkpoint() }
    }

     
    func charge(_ count: Int) throws {
        guard count > 0 else { return }
        let before = counters[0]
        let left = before &- count
        counters[0] = left
        if left <= 0 || (before >> 10) != (left >> 10) { try checkpoint() }
    }

    private func checkpoint() throws {
        if remaining <= 0 { throw AdBlockJQThrow.stop("it ran past its \(limits.steps) steps") }
        if budget.isSpent(since: runStarted) { throw budgetStop("it ran past the request's CPU budget") }
        try checkMemory()
        try checkBackstop()
    }

     
     
    func checkBackstop(adding bytes: Int = 0) throws {
        if AdBlockJQMachine.footprint() - footprintStart + Int64(bytes) > backstopBytes {
            throw backstopStop("the tunnel's memory grew past \(backstopBytes >> 20) MiB while it ran")
        }
    }

     
     
    func backstopStop(_ why: String) -> AdBlockJQThrow {
        stoppedByBackstop = true
        return AdBlockJQThrow.stop(why)
    }

     
     
    func budgetStop(_ why: String) -> AdBlockJQThrow {
        stoppedByBudget = true
        return AdBlockJQThrow.stop(why)
    }

     
     
    @inline(__always)
    func checkMemory() throws {
        let total = ledger.total
        if total > ledgerPeak { ledgerPeak = total }
        if total > memoryCap { throw AdBlockJQThrow.stop("its values hold more than \(memoryCap >> 20) MiB") }
    }

     
    private(set) var ledgerPeak = 0

     
    var memoryLimit: Int { memoryCap }

     
    var memoryLeft: Int { max(0, memoryCap &- ledger.total) }

     
     
    func reserve(_ bytes: Int) throws {
        if bytes > memoryLeft {
            ledgerPeak = max(ledgerPeak, ledger.total &+ bytes)
            throw AdBlockJQThrow.stop("it would hold more than \(memoryCap >> 20) MiB")
        }
    }

     
     
     
    @inline(__always)
    func beforeAppend(to items: [Value], holding strings: Int = 0) throws {
        guard items.count == items.capacity, items.count >= 512 else { return }
        try reserve(AdBlockJSONLedger.arrayBytes(capacity: items.capacity &* 3) &+ strings)
    }

     
    @inline(__always)
    func beforeAppend<Element>(to items: [Element]) throws {
        guard items.count == items.capacity, items.count >= 512 else { return }
        try reserve(items.capacity &* 3 &* MemoryLayout<Element>.stride)
    }

     
     
     
     
     
     
     
    func produce(_ bytes: Int) throws {
        guard bytes > 15 else { return }
        try reserve(bytes)
        try charge(bytes >> 6)
        if bytes >= 64 << 10 { try checkBackstop(adding: bytes) }
    }

     

     
     
     
     
    static let heldStringBytes = 4 << 10

     
    private var heldStrings: [UInt: (holders: Int, bytes: Int)] = [:]

     
     
     
     
    @inline(__always)
    func hold(_ value: Value) throws -> UInt {
        guard case .string(let string) = value, string.isContiguousUTF8, string.utf8.count >= Self.heldStringBytes else { return 0 }
        return try holdString(string)
    }

    @inline(never)
    private func holdString(_ string: String) throws -> UInt {
        let found = string.utf8.withContiguousStorageIfAvailable { UInt(bitPattern: $0.baseAddress) }
        guard let key = found, key != 0 else { return 0 }
        if let entry = heldStrings[key] {
            heldStrings[key] = (entry.holders &+ 1, entry.bytes)
            return key
        }
        let bytes = AdBlockJSONLedger.stringBytes(string)
        try reserve(bytes)
        ledger.live &+= bytes
        heldStrings[key] = (1, bytes)
        return key
    }

    @inline(__always)
    func release(_ key: UInt) {
        if key != 0 { releaseString(key) }
    }

    @inline(never)
    private func releaseString(_ key: UInt) {
        guard let entry = heldStrings[key] else { return }
        if entry.holders > 1 {
            heldStrings[key] = (entry.holders &- 1, entry.bytes)
        } else {
            heldStrings[key] = nil
            ledger.live &-= entry.bytes
        }
    }

     
     
    func components(_ at: AdBlockJQPath) throws -> [Value] {
        try reserve(AdBlockJSONLedger.arrayBytes(capacity: at.length))
        return at.components
    }

    func checkDepth(_ value: Value) throws {
        if value.depth > limits.depth { throw AdBlockJQThrow.stop("it nests values deeper than \(limits.depth)") }
    }

     
    @inline(__always)
    func checkDepth(building depth: Int) throws {
        if depth > limits.depth { throw AdBlockJQThrow.stop("it nests values deeper than \(limits.depth)") }
    }

    @inline(__always)
    func guardStack() throws {
        if AdBlockJQStack.address() < stackFloor { throw AdBlockJQThrow.stop("it recursed past the thread's stack") }
    }

     
     
     
    func text(_ value: Value) throws -> String {
        let left = memoryLeft
        var spent = false
        var measure = AdBlockJSONWriter(AdBlockJSONCheckedSink(AdBlockJSONCountingSink(limit: left)) { [self] in
            if budget.isSpent(since: runStarted) { spent = true }
            return !spent
        })
        guard measure.write(value) else {
            if spent { throw budgetStop("it ran past the request's CPU budget") }
            throw AdBlockJQThrow.stop("it would hold more than \(memoryCap >> 20) MiB")
        }
        let length = measure.sink.inner.total
        try charge(length >> 6)
        try produce(length)
        return AdBlockJSONText.written(value, length: length)
    }

     
    func tostring(_ value: Value) throws -> String {
        if case .string(let string) = value { return string }
        return try text(value)
    }

     
    static func logText(_ value: Value) -> String {
        AdBlockJSONText.string(value, limit: AdBlockJQ.logLineBytes) ?? AdBlockJSONText.truncated(value, bufferSize: AdBlockJQ.logLineBytes)
    }

    func enter() throws {
        callDepth += 1
        if callDepth > limits.depth { throw AdBlockJQThrow.stop("it nests calls deeper than \(limits.depth)") }
        try guardStack()
    }

    func leave() { callDepth -= 1 }

    func token() -> Int {
        nextToken += 1
        return nextToken
    }

     
     
    func newLabel() -> Int {
        defer { nextLabel += 1 }
        return nextLabel
    }

     

    func fail(_ message: String) -> AdBlockJQThrow { .raised(.string(message)) }

    static func dump(_ value: Value, _ size: Int = 15) -> String { AdBlockJSONText.truncated(value, bufferSize: size) }

    func typeError(_ value: Value, _ message: String) -> AdBlockJQThrow {
        fail("\(value.typeName) (\(Self.dump(value))) \(message)")
    }

    func typeError(_ a: Value, _ b: Value, _ message: String) -> AdBlockJQThrow {
        fail("\(a.typeName) (\(Self.dump(a))) and \(b.typeName) (\(Self.dump(b))) \(message)")
    }

     

    static func identical(_ a: Value, _ b: Value) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .number(let y)):
            switch (x.literal, y.literal) {
            case (nil, nil): return x.value.bitPattern == y.value.bitPattern
            case (let lx?, let ly?): return lx === ly && x.value.bitPattern == y.value.bitPattern
            default: return false
            }
        case (.string(let x), .string(let y)): return AdBlockJSONBytes.equal(x, y)
        case (.array(let x), .array(let y)): return x.isIdentical(to: y)
        case (.object(let x), .object(let y)): return x.isIdentical(to: y)
        default: return false
        }
    }

     

     
     
     
     
    typealias Env = AdBlockJQEnvironment?
    typealias At = AdBlockJQPath?

    func eval(_ node: AdBlockJQNode, _ input: Value, _ path: At, _ env: Env, _ emit: Emit) throws {
        try tick()
        try guardStack()
        let held = try hold(input)
        defer { release(held) }
        switch node {
        case .identity: try emit(input, path)
        case .literal(let value): try emit(value, path)
        case .recurseDefault: try recurseAll(input, path, emit)
        case .field(let target, let name, let optional): try evalField(target, name, optional, input, path, env, emit)
        case .index(let target, let key, let optional): try evalIndex(target, key, optional, input, path, env, emit)
        case .slice(let target, let from, let to, let optional): try evalSlice(target, from, to, optional, input, path, env, emit)
        case .iterate(let target, let optional): try evalIterate(target, optional, input, path, env, emit)
        case .string(let parts, let format): try evalString(parts, format, input, path, env, emit)
        case .format(let name): try emit(.string(try applyFormat(name, input)), path)
        case .collect(let inner): try evalCollect(inner, input, path, env, emit)
        case .object(let entries): try evalObject(entries, input, path, env, emit)
        case .negate(let inner): try evalNegate(inner, input, path, env, emit)
        case .pipe(let stages): try evalPipe(stages, 0, input, path, env, emit)
        case .comma(let items):
            for item in items { try eval(item, input, path, env, emit) }
        case .binary(let operation, let left, let right): try evalBinary(operation, left, right, input, path, env, emit)
        case .and(let left, let right): try evalAnd(left, right, input, path, env, emit)
        case .or(let left, let right): try evalOr(left, right, input, path, env, emit)
        case .alternative(let left, let right): try evalAlternative(left, right, input, path, env, emit)
        case .update(let operation, let left, let right): try update(operation, left, right, input, path, env, emit)
        case .conditional(let branches, let otherwise):
            try evalConditional(branches, 0, otherwise, input, path, env, emit)
        case .tryCatch(let body, let handler): try evalTry(body, handler, input, path, env, emit)
        case .reduce(let source, let patterns, let initial, let update):
            try evalReduce(source, patterns, initial, update, input, path, env, emit)
        case .foreach(let source, let patterns, let initial, let update, let extract):
            try evalForeach(source, patterns, initial, update, extract, input, path, env, emit)
        case .define(let function, let rest): try eval(rest, input, path, AdBlockJQEnvironment(env, .function(function)), emit)
        case .callUser(let hops, let arguments): try evalCallUser(hops, arguments, input, path, env, emit)
        case .callParameter(let hops): try evalCallParameter(hops, input, path, env, emit)
        case .callBuiltin(let reference, let arguments): try call(reference.function, arguments, nil, input, path, env, emit)
        case .callNative(let native, let arguments): try callNative(native, arguments, input, path, env, emit)
        case .variable(let hops): try emit(Self.variable(env, hops), path)
        case .bind(let source, let patterns, let body): try evalBind(source, patterns, body, input, path, env, emit)
        case .label(let body): try evalLabel(body, input, path, env, emit)
        case .breakLabel(let hops): throw AdBlockJQThrow.breakLabel(Self.label(env, hops))
        case .scalar(let inner):
            if path == nil {
                try emit(try single(inner, input, env), nil)
            } else {
                try eval(inner, input, path, env, emit)
            }
        }
    }

     
     
     
    func single(_ node: AdBlockJQNode, _ input: Value, _ env: Env) throws -> Value {
        try guardStack()
        switch node {
        case .identity:
            return input
        case .literal(let value):
            return value
        case .variable(let hops):
            return Self.variable(env, hops)
        case .scalar(let inner):
            return try single(inner, input, env)
        case .field(let target, let name, _):
            try tick()
            return try index(try single(target, input, env), .string(name))
        case .index(let target, let key, _):
            try tick()
            let name = try single(key, input, env)
            return try index(try single(target, input, env), name)
        case .negate(let inner):
            try tick()
            let value = try single(inner, input, env)
            guard case .number(let number) = value else { throw typeError(value, "cannot be negated") }
            return .number(-number.value)
        case .pipe(let stages):
            try tick()
            var value = input
            for stage in stages { value = try single(stage, value, env) }
            return value
        case .binary(let operation, let left, let right):
            try tick()
             
            let b = try single(right, input, env)
            return try binary(operation, try single(left, input, env), b)
        case .and(let left, let right):
            try tick()
            guard try single(left, input, env).isTruthy else { return .bool(false) }
            return .bool(try single(right, input, env).isTruthy)
        case .or(let left, let right):
            try tick()
            if try single(left, input, env).isTruthy { return .bool(true) }
            return .bool(try single(right, input, env).isTruthy)
        case .alternative(let left, let right):
            try tick()
            let value = try single(left, input, env)
            return value.isTruthy ? value : try single(right, input, env)
        case .conditional(let branches, let otherwise):
            try tick()
            for branch in branches where try single(branch.condition, input, env).isTruthy {
                return try single(branch.then, input, env)
            }
            if let otherwise { return try single(otherwise, input, env) }
            return input
        default:
            var result: Value?
            try eval(node, input, nil, env) { value, _ in result = value }
            guard let result else { throw AdBlockJQThrow.stop("a form proved single gave no output") }
            return result
        }
    }

    private static func variable(_ env: Env, _ hops: Int) -> Value {
        guard case .value(let value) = AdBlockJQEnvironment.up(env, hops).entry else { preconditionFailure("a variable resolved to a value") }
        return value
    }

    private static func label(_ env: Env, _ hops: Int) -> Int {
        guard case .label(let label) = AdBlockJQEnvironment.up(env, hops).entry else { preconditionFailure("a break resolved to a label") }
        return label
    }
}
#endif
