#if os(iOS) || os(macOS)
import Foundation

 
 

 

final class AdBlockJQEnvironment {
    enum Entry {
        case value(AdBlockJSONValue)
        case closure(AdBlockJQNode, AdBlockJQEnvironment?)
        case function(AdBlockJQFunction)
        case label(Int)
    }

     
    private(set) var parent: AdBlockJQEnvironment?
    let entry: Entry
     
     
    private var run: UInt32 = 0
    private var charged = 0

    init(_ parent: AdBlockJQEnvironment?, _ entry: Entry) {
        self.parent = parent
        self.entry = entry
        if case .value(.string(let string)) = entry {
            let bytes = AdBlockJSONLedger.stringBytes(string)
            if bytes > 0, let ledger = AdBlockJSONLedger.current {
                run = ledger.run
                charged = bytes
                ledger.live &+= bytes
            }
        }
    }

    deinit {
        if run != 0, let ledger = AdBlockJSONLedger.current, ledger.run == run { ledger.live &-= charged }
        AdBlockJQEnvironment.unlink(&parent)
    }

     
    static func unlink(_ head: inout AdBlockJQEnvironment?) {
        var next = head
        head = nil
        while isKnownUniquelyReferenced(&next) {
            let following = next!.parent
            next!.parent = nil
            next = following
        }
    }

    @inline(__always)
    static func up(_ environment: AdBlockJQEnvironment?, _ hops: Int) -> AdBlockJQEnvironment {
        var node = environment!
        var left = hops
        while left > 0 {
            node = node.parent!
            left -= 1
        }
        return node
    }
}

 
 
final class AdBlockJQPath {
     
    private(set) var parent: AdBlockJQPath?
    let component: AdBlockJSONValue
    let value: AdBlockJSONValue
    let length: Int

    init(root value: AdBlockJSONValue) {
        parent = nil
        component = .null
        self.value = value
        length = 0
    }

    init(_ parent: AdBlockJQPath, _ component: AdBlockJSONValue, _ value: AdBlockJSONValue) {
        self.parent = parent
        self.component = component
        self.value = value
        length = parent.length + 1
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

     
    static let bytes = 96

    var components: [AdBlockJSONValue] {
        var result = [AdBlockJSONValue](repeating: .null, count: length)
        var node: AdBlockJQPath? = self
        while let current = node, current.length > 0 {
            result[current.length - 1] = current.component
            node = current.parent
        }
        return result
    }

    func appending(_ components: [AdBlockJSONValue], value: AdBlockJSONValue) -> AdBlockJQPath {
        var node = self
        for (offset, component) in components.enumerated() {
            node = AdBlockJQPath(node, component, offset == components.count - 1 ? value : .null)
        }
        return components.isEmpty ? AdBlockJQPath(parent: parent, component: component, value: value, length: length) : node
    }

    private init(parent: AdBlockJQPath?, component: AdBlockJSONValue, value: AdBlockJSONValue, length: Int) {
        self.parent = parent
        self.component = component
        self.value = value
        self.length = length
    }
}

 

 
 
 
indirect enum AdBlockJQThrow: Error {
    case raised(AdBlockJSONValue)
    case breakLabel(Int)
     
    case downstream(AdBlockJQThrow, owner: Int)
    case halt(AdBlockJSONValue?)
    case stop(String)
}
#endif
