#if os(iOS) || os(macOS)
import Foundation

 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 

enum AdBlockJSONRewrite {
    enum Outcome: Equatable {
        case rewritten(Data)
         
        case unchanged
         
        case notJSON
         
        case tooLarge
         
         
        case stopped
    }

     
    enum Change: Equatable {
        case changed
        case unchanged
        case stopped
    }

     
     
     
     
     
     
     
     
     
    static let iPhoneMaximumNodes = 48 << 10
    #if os(iOS)
    static let maximumNodes = iPhoneMaximumNodes
    #else
    static let maximumNodes = 4 << 20
    #endif

     
     
     
     
    struct Compiled {
        fileprivate let steps: [Step]
         
        let heldBytes: Int

         
        static let nothing = Compiled(steps: [], heldBytes: 0)
    }

     
     
     
     
    static let readValueBytesPerTextByte = 17

     
    struct CompileFailure: Error, Equatable {
        let reason: String
    }

     
     
     
     
     
    static func compile(_ operations: [AdBlockJSONOperation], readingValues: Bool = true,
                        maximumBodyBytes: Int = AdBlockJQ.maximumBodyBytes,
                        maximumNodes: Int = AdBlockJSONRewrite.maximumNodes) -> Result<Compiled, CompileFailure> {
        var steps: [Step] = []
        var held = 0
        for operation in operations {
            var step = Step(operation)
            if !readingValues {
                held += step.valueJSON?.utf8.count ?? 0
            } else if let json = step.valueJSON {
                guard let value = Self.value(json, maximumBodyBytes: maximumBodyBytes, maximumNodes: maximumNodes) else {
                    return .failure(CompileFailure(reason: "a value it writes is larger than a body may be (\(maximumBodyBytes) bytes, \(maximumNodes) values)"))
                }
                step.value = value
                held += json.utf8.count * readValueBytesPerTextByte + 64
            }
            steps.append(step)
        }
        return .success(Compiled(steps: steps, heldBytes: held))
    }

     
     
     
     
     
    static func apply(_ compiled: Compiled, to value: inout AdBlockJSONValue, maximumBodyBytes: Int = AdBlockJQ.maximumBodyBytes,
                      bodyBytes: Int, budget: inout AdBlockRequestBudget) -> Change {
        var working = value
        let change = run(compiled.steps, on: &working, maximumBodyBytes: maximumBodyBytes, maximumNodes: maximumNodes,
                         bodyBytes: bodyBytes, budget: &budget)
        if change == .changed { value = working }
        return change
    }

    static func apply(_ operations: [AdBlockJSONOperation], to body: Data, maximumBodyBytes: Int = AdBlockJQ.maximumBodyBytes,
                      maximumNodes: Int = AdBlockJSONRewrite.maximumNodes, budget: inout AdBlockRequestBudget) -> Outcome {
        guard !operations.isEmpty else { return .unchanged }
        guard body.count <= maximumBodyBytes else { return .tooLarge }
         
        if budget.isSpent {
            budget.noteStop()
            return .stopped
        }
        var value: AdBlockJSONValue
        switch AdBlockJSONText.parse(body, maximumNodes: maximumNodes) {
        case .value(let read): value = read
        case .notJSON: return .notJSON
        case .tooManyNodes: return .tooLarge
        }
        switch run(operations.map(Step.init), on: &value, maximumBodyBytes: maximumBodyBytes, maximumNodes: maximumNodes,
                   bodyBytes: body.count, budget: &budget) {
        case .unchanged: return .unchanged
        case .stopped: return .stopped
        case .changed:
             
             
            guard let data = AdBlockJSONText.serialize(value, limit: maximumBodyBytes) else {
                budget.noteStop()
                return .stopped
            }
            return .rewritten(data)
        }
    }

     
     
     
     
    static func apply(_ operations: [AdBlockJSONOperation], to value: inout AdBlockJSONValue,
                      maximumBodyBytes: Int = AdBlockJQ.maximumBodyBytes, maximumNodes: Int = AdBlockJSONRewrite.maximumNodes,
                      bodyBytes: Int? = nil, budget: inout AdBlockRequestBudget) -> Change {
        var working = value
        let change = run(operations.map(Step.init), on: &working, maximumBodyBytes: maximumBodyBytes, maximumNodes: maximumNodes,
                         bodyBytes: bodyBytes ?? maximumBodyBytes, budget: &budget)
        if change == .changed { value = working }
        return change
    }

     
     
     
     
     
    static func envelope(bodyBytes: Int) -> Int {
        AdBlockJQ.Limits.engine(bodyBytes: AdBlockJQ.maximumBodyBytes, inputBytes: bodyBytes).memoryBytes
    }

     
     
    static let paddingBytesEach = 24

    private static func run(_ steps: [Step], on value: inout AdBlockJSONValue, maximumBodyBytes: Int,
                            maximumNodes: Int, bodyBytes: Int, budget: inout AdBlockRequestBudget) -> Change {
        guard !steps.isEmpty else { return .unchanged }
        if budget.isSpent {
            budget.noteStop()
            return .stopped
        }
        let start = AdBlockRequestBudget.threadNanoseconds()
        func stop() -> Change {
            budget.charge(AdBlockRequestBudget.threadNanoseconds() &- start)
            budget.noteStop()
            return .stopped
        }
        var changed = false
        let paddable = min(maximumBodyBytes / 5, envelope(bodyBytes: bodyBytes) / paddingBytesEach)
        for step in steps {
            if budget.isSpent(since: start) { return stop() }
            switch applies(step, to: value, paddable: paddable) {
            case .no: continue
            case .pastTheCap: return stop()
            case .yes: break
            }
             
             
             
            guard let new = step.value ?? step.valueJSON.map({ Self.value($0, maximumBodyBytes: maximumBodyBytes, maximumNodes: maximumNodes) })
                    ?? .some(.null) else { return stop() }
             
            guard step.path.count + new.depth <= AdBlockJSONText.maximumDepth else { continue }
            change(&value, step.path, step.verb, new)
            changed = true
        }
        budget.charge(AdBlockRequestBudget.threadNanoseconds() &- start)
        return changed ? .changed : .unchanged
    }

     
     
    static func value(_ text: String) -> AdBlockJSONValue {
        value(text, maximumBodyBytes: .max, maximumNodes: .max)!
    }

     
     
    private static func value(_ text: String, maximumBodyBytes: Int, maximumNodes: Int) -> AdBlockJSONValue? {
        guard text.utf8.count <= maximumBodyBytes else { return nil }
        switch AdBlockJSONText.parse(Data(text.utf8), maximumNodes: maximumNodes) {
        case .value(let value): return value
        case .notJSON: return .string(text)
        case .tooManyNodes: return nil
        }
    }

    fileprivate struct Step {
        enum Verb: Equatable {
            case delete
            case replace
             
             
             
            case add
             
             
            case fill
        }

        let path: [AdBlockJSONPathComponent]
        let verb: Verb
        let valueJSON: String?
         
        let onlyTruthy: Bool
         
        var value: AdBlockJSONValue?

        init(_ operation: AdBlockJSONOperation) {
            switch operation {
            case .delete(let path): self.init(path, .delete, nil, onlyTruthy: false)
            case .replace(let path, let value): self.init(path, .replace, value, onlyTruthy: false)
            case .add(let path, let value): self.init(path, .add, value, onlyTruthy: false)
            case .deleteIfTruthy(let path): self.init(path, .delete, nil, onlyTruthy: true)
            case .replaceIfTruthy(let path, let value): self.init(path, .replace, value, onlyTruthy: true)
            case .addIfMissingOrNull(let path, let value): self.init(path, .fill, value, onlyTruthy: false)
            }
        }

        private init(_ path: [AdBlockJSONPathComponent], _ verb: Verb, _ valueJSON: String?, onlyTruthy: Bool) {
            self.path = path
            self.verb = verb
            self.valueJSON = valueJSON
            self.onlyTruthy = onlyTruthy
        }
    }

    private enum Verdict {
        case yes
        case no
         
         
        case pastTheCap
    }

     
     
     
     
     
     
     
    private static func applies(_ step: Step, to root: AdBlockJSONValue, paddable: Int) -> Verdict {
        let path = step.path
        guard !path.isEmpty, path.count <= AdBlockJSONText.maximumDepth, !path.contains(.every) else { return .no }
        var padding = 0
         
        func made(_ rest: ArraySlice<AdBlockJSONPathComponent>) -> Verdict {
            for component in rest {
                switch component {
                case .key: continue
                case .index(let index):
                    guard index >= 0 else { return .no }
                    guard index <= paddable - padding else { return .pastTheCap }
                    padding += index
                case .every: return .no
                }
            }
            return .yes
        }
        var current = root
        for position in path.indices {
            let last = position == path.count - 1
            let child: AdBlockJSONValue?
            switch (current, path[position]) {
            case (.object(let object), .key(let key)):
                child = object[key]
                if last { return decide(step, existing: child, insertable: true) ? .yes : .no }
            case (.array(let array), .index(let index)) where index >= 0:
                child = index < array.count ? array[index] : nil
                if step.verb == .fill, index >= array.count {
                    guard index - array.count <= paddable - padding else { return .pastTheCap }
                    padding += index - array.count
                }
                if last { return decide(step, existing: child, insertable: index <= array.count) ? .yes : .no }
            case (.null, _) where step.verb == .fill:
                return made(path[position...])
            default:
                return .no
            }
            guard let child else { return step.verb == .fill ? made(path[(position + 1)...]) : .no }
            current = child
        }
        return .no
    }

    private static func decide(_ step: Step, existing: AdBlockJSONValue?, insertable: Bool) -> Bool {
        switch step.verb {
        case .delete, .replace:
            guard let existing else { return false }
            return !step.onlyTruthy || existing.isTruthy
        case .add:
            return insertable
        case .fill:
            guard let existing else { return true }
            if case .null = existing { return true }
            return false
        }
    }

     
     
     
    private static func change(_ root: inout AdBlockJSONValue, _ path: [AdBlockJSONPathComponent], _ verb: Step.Verb,
                               _ new: AdBlockJSONValue) {
        var spine: [AdBlockJSONValue] = []
        spine.reserveCapacity(path.count - 1)
        var current = root
        root = .null
        for component in path.dropLast() {
            let child = takeOut(&current, component)
            spine.append(current)
            current = child
        }
        act(&current, path[path.count - 1], verb, new)
        var position = path.count - 1
        while var parent = spine.popLast() {
            position -= 1
            set(&parent, path[position], current)
            current = parent
        }
        root = current
    }

     
     
    private static func takeOut(_ container: inout AdBlockJSONValue, _ component: AdBlockJSONPathComponent) -> AdBlockJSONValue {
        switch component {
        case .key(let key):
            var object = Self.object(container)
            container = .null
            let child = object[key] ?? .null
            object.set(key, .null)
            container = .object(object)
            return child
        case .index(let index):
            var array = Self.array(container)
            container = .null
            if index >= array.count {
                array.modify { items in items.append(contentsOf: repeatElement(.null, count: index + 1 - items.count)) }
            }
            let child = array[index]
            array.set(index, .null)
            container = .array(array)
            return child
        case .every:
            preconditionFailure("a path holding [*] is never walked")
        }
    }

    private static func set(_ container: inout AdBlockJSONValue, _ component: AdBlockJSONPathComponent, _ value: AdBlockJSONValue) {
        switch component {
        case .key(let key):
            var object = Self.object(container)
            container = .null
            object.set(key, value)
            container = .object(object)
        case .index(let index):
            var array = Self.array(container)
            container = .null
            array.set(index, value)
            container = .array(array)
        case .every:
            preconditionFailure("a path holding [*] is never walked")
        }
    }

    private static func act(_ container: inout AdBlockJSONValue, _ component: AdBlockJSONPathComponent, _ verb: Step.Verb,
                            _ new: AdBlockJSONValue) {
        switch component {
        case .key(let key):
            var object = Self.object(container)
            container = .null
            if verb == .delete {
                object.remove(key)
            } else {
                object.set(key, new)
            }
            container = .object(object)
        case .index(let index):
            var array = Self.array(container)
            container = .null
            switch verb {
            case .delete: array.remove(at: index)
            case .replace: array.set(index, new)
             
            case .add: index < array.count ? array.set(index, new) : array.append(new)
            case .fill:
                if index < array.count {
                    array.set(index, new)
                } else {
                    array.modify { items in
                        items.append(contentsOf: repeatElement(.null, count: index - items.count))
                        items.append(new)
                    }
                }
            }
            container = .array(array)
        case .every:
            preconditionFailure("a path holding [*] is never walked")
        }
    }

     
    private static func object(_ value: AdBlockJSONValue) -> AdBlockJSONObject {
        if case .object(let object) = value { return object }
        return AdBlockJSONObject()
    }

     
    private static func array(_ value: AdBlockJSONValue) -> AdBlockJSONArray {
        if case .array(let array) = value { return array }
        return AdBlockJSONArray()
    }
}
#endif
