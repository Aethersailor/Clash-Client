#if os(iOS) || os(macOS)
import CryptoKit
import Foundation

 
 
 
 
 
 
 
 
 
 
 
 

 
 
 
 
 
 
 
 
 
final class AdBlockTunnelModuleIR: Decodable, Equatable, Sendable {
    let schemaVersion: Int
    let format: AdBlockModuleFormat
    let rewriteRules: [AdBlockRewriteRule]
     
    let engineRules: [AdBlockEngineRule]
    let scripts: [AdBlockScript]

    init(schemaVersion: Int, format: AdBlockModuleFormat, rewriteRules: [AdBlockRewriteRule], engineRules: [AdBlockEngineRule],
         scripts: [AdBlockScript]) {
        self.schemaVersion = schemaVersion
        self.format = format
        self.rewriteRules = rewriteRules
        self.engineRules = engineRules
        self.scripts = scripts
    }

     
    convenience init(_ ir: AdBlockModuleIR) {
        self.init(schemaVersion: ir.schemaVersion, format: ir.manifest.format, rewriteRules: ir.rewriteRules,
                  engineRules: ir.engineRules, scripts: ir.scripts)
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, manifest, sections, rewriteRules, engineRules, scripts }

     
    private struct Manifest: Decodable {
        let format: AdBlockModuleFormat
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let table = AdBlockSectionTable.Table(try c.decodeIfPresent([String].self, forKey: .sections) ?? [])
        func list<T: Decodable>(_ key: CodingKeys) throws -> [T] { try c.decodeIfPresent([T].self, forKey: key) ?? [] }
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        format = try c.decode(Manifest.self, forKey: .manifest).format
        let lists: ([AdBlockRewriteRule], [AdBlockEngineRule], [AdBlockScript]) = try AdBlockSectionTable.$current.withValue(table) {
            (try list(.rewriteRules), try list(.engineRules), try list(.scripts))
        }
        rewriteRules = lists.0
        engineRules = lists.1
        scripts = lists.2
    }

     
     
    static let batchElements = 128

     
     
     
     
     
     
     
     
    static func read(_ values: inout [String: Data], sharing: AdBlockRuleSharing? = nil) -> AdBlockTunnelModuleIR? {
        let decoder = AdBlockJSON.decoder()
        func take<T: Decodable>(_ key: String, as type: T.Type) -> T? {
            guard let data = values.removeValue(forKey: key) else { return nil }
            return try? decoder.decode(T.self, from: data)
        }
        guard let schemaVersion = take("schemaVersion", as: Int.self), let manifest = take("manifest", as: Manifest.self) else { return nil }
        let table = AdBlockSectionTable.Table(take("sections", as: [String].self) ?? [])
        func list<T: Decodable>(_ key: String, each: ((inout T) -> Void)? = nil) -> [T]? {
            guard let data = values.removeValue(forKey: key) else { return [] }
            return AdBlockSectionTable.$current.withValue(table) {
                AdBlockJSONArrayBatches.decode(T.self, from: data, batch: batchElements, each: each)
            }
        }
        let share: ((inout AdBlockRewriteRule) -> Void)? = sharing.map { sharing in { (rule: inout AdBlockRewriteRule) in sharing.share(&rule) } }
        guard let rewriteRules: [AdBlockRewriteRule] = list("rewriteRules", each: share), let engineRules: [AdBlockEngineRule] = list("engineRules"),
              let scripts: [AdBlockScript] = list("scripts") else { return nil }
        return AdBlockTunnelModuleIR(schemaVersion: schemaVersion, format: manifest.format, rewriteRules: rewriteRules,
                                     engineRules: engineRules, scripts: scripts)
    }

    static func == (lhs: AdBlockTunnelModuleIR, rhs: AdBlockTunnelModuleIR) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion && lhs.format == rhs.format && lhs.rewriteRules == rhs.rewriteRules
            && lhs.engineRules == rhs.engineRules && lhs.scripts == rhs.scripts
    }
}

 
 
 
 
 
 
 
 
 
 
 
final class AdBlockRuleSharing {
     
     
    private var byPattern: [String: [AdBlockRewriteAction]] = [:]
     
    private static let rejects: [[AdBlockRewriteAction]] = [
        [.reject], [.reject200], [.rejectImg], [.rejectTinyGif], [.rejectDict], [.rejectArray], [.rejectDrop], [.rejectNoDrop],
    ]

    func share(_ rule: inout AdBlockRewriteRule) {
        if let known = byPattern.index(forKey: rule.pattern) {
            let (pattern, actions) = byPattern[known]
            rule.pattern = pattern
            if actions == rule.actions {
                rule.actions = actions
                return
            }
        }
        if rule.actions.count == 1, let reject = Self.rejects.first(where: { $0[0] == rule.actions[0] }) { rule.actions = reject }
        if byPattern[rule.pattern] == nil { byPattern[rule.pattern] = rule.actions }
    }
}

 
struct AdBlockPublishedModule: Equatable, Sendable {
     
    let module: AdBlockGlobalManifest.Module
     
    let ir: AdBlockTunnelModuleIR
     
     
    var keptBytes = 0

    init(module: AdBlockGlobalManifest.Module, ir: AdBlockTunnelModuleIR, keptBytes: Int = 0) {
        self.module = module
        self.ir = ir
        self.keptBytes = keptBytes
    }

     
    init(module: AdBlockGlobalManifest.Module, ir: AdBlockModuleIR, keptBytes: Int = 0) {
        self.init(module: module, ir: AdBlockTunnelModuleIR(ir), keptBytes: keptBytes)
    }
}

 
struct AdBlockModuleReading: Equatable, Sendable {
     
     
    var modules: [AdBlockPublishedModule]
     
    var omitted: [AdBlockEngineReport.OmittedModule]
     
     
    var unlisted: [AdBlockGlobalManifest.Module]
     
     
    var listProblem: String?
     
    var reads: Int
}

enum AdBlockModuleReader {
     
    static let rereads = 3
    static let maximumListBytes = 8 << 20
     
     
    static let maximumModuleTableBytes = 1 << 20
    static let maximumIRBytes = 8 << 20
    static let maximumScriptBytes = 8 << 20
     
     
     
     
     
     
     
     
     
     
    static let keptIRKeys: Set<String> = ["schemaVersion", "sections", "rewriteRules", "engineRules", "scripts"]
    static let keptManifestKeys: Set<String> = ["format"]
     
     
     
     
     
     
     
     
     
     
     
     
    static let maximumRuleBytes = 384 * 1024

     
    struct Pass: Sendable {
        enum Outcome: Sendable {
            case read(AdBlockTunnelModuleIR, kept: Int)
             
            case leftOut(AdBlockEngineReport.OmittedModule)
             
            case unsettled(AdBlockEngineReport.OmittedModule)
            case unlisted
        }

        var items: [(module: AdBlockGlobalManifest.Module, outcome: Outcome)] = []
         
        var listProblem: String?

        var modules: [AdBlockPublishedModule] {
            items.compactMap { item in
                if case .read(let ir, let kept) = item.outcome {
                    return AdBlockPublishedModule(module: item.module, ir: ir, keptBytes: kept)
                }
                return nil
            }
        }

        var unsettled: [AdBlockEngineReport.OmittedModule] {
            items.compactMap { item in
                if case .unsettled(let omitted) = item.outcome { return omitted }
                return nil
            }
        }

         
        var omitted: [AdBlockEngineReport.OmittedModule] {
            items.compactMap { item in
                switch item.outcome {
                case .leftOut(let omitted), .unsettled(let omitted): return omitted
                case .read, .unlisted: return nil
                }
            }
        }

        var unlisted: [AdBlockGlobalManifest.Module] {
            items.compactMap { item in
                if case .unlisted = item.outcome { return item.module }
                return nil
            }
        }
    }

     
     
     
     
     
     
     
    static func read(_ wanted: [AdBlockGlobalManifest.Module], locations: AdBlockEngineLocations, queue: DispatchQueue,
                     spacing: TimeInterval, rereads: Int = AdBlockModuleReader.rereads,
                     ruleBytes: Int = AdBlockModuleReader.maximumRuleBytes,
                     isCurrent: @escaping () -> Bool, eachRead: @escaping (Pass) -> Void = { _ in },
                     completion: @escaping (AdBlockModuleReading) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        func attempt(_ number: Int) {
            guard isCurrent() else { return }
            let pass = readOnce(wanted, locations: locations, ruleBytes: ruleBytes)
            eachRead(pass)
            if !pass.unsettled.isEmpty, number <= rereads {
                queue.asyncAfter(deadline: .now() + spacing) { attempt(number + 1) }
                return
            }
            completion(AdBlockModuleReading(modules: pass.modules, omitted: pass.omitted, unlisted: pass.unlisted,
                                            listProblem: pass.listProblem, reads: number))
        }
        attempt(1)
    }

     
     
     
     
     
     
    static func readOnce(_ wanted: [AdBlockGlobalManifest.Module], locations: AdBlockEngineLocations,
                         ruleBytes: Int = AdBlockModuleReader.maximumRuleBytes) -> Pass {
        var pass = Pass()
         
        guard !wanted.isEmpty else { return pass }
        var list: ListView?
         
         
         
         
        switch AdBlockTopLevelJSON.values(of: ["schemaVersion", "modules"], in: locations.globalManifest,
                                          maximumBytes: maximumListBytes, maximumValueBytes: maximumModuleTableBytes) {
        case .missing:
            pass.listProblem = "modules/manifest.json is missing or cannot be read"
        case .tooLarge:
            pass.listProblem = "modules/manifest.json is larger than \(maximumListBytes) bytes"
        case .notAnObject:
            pass.listProblem = "modules/manifest.json is not a module list this tunnel reads"
        case .values(_, let oversized) where !oversized.isEmpty:
            pass.listProblem = "modules/manifest.json's module table is larger than \(maximumModuleTableBytes) bytes"
        case .values(let values, _):
            if let view = try? AdBlockJSON.decoder().decode(ListView.self, from: AdBlockTopLevelJSON.object(values)) {
                if view.schemaVersion == AdBlockGlobalManifest.currentSchemaVersion {
                    list = view
                } else {
                    pass.listProblem = "modules/manifest.json is schema \(view.schemaVersion), this tunnel reads \(AdBlockGlobalManifest.currentSchemaVersion)"
                }
            } else {
                pass.listProblem = "modules/manifest.json is not a module list this tunnel reads"
            }
        }
        let listed = list.map { Dictionary($0.modules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
         
        let sharing = AdBlockRuleSharing()
         
        let total = min(maximumRuleBytes, max(0, ruleBytes))
        var budget = total
        for asked in wanted {
            let module: AdBlockGlobalManifest.Module
            if let listed {
                guard let named = listed[asked.id] else {
                    pass.items.append((asked, .unlisted))
                    continue
                }
                module = named
            } else {
                module = asked
            }
             
             
            let outcome = autoreleasepool { check(module, locations: locations, budget: &budget, of: total, sharing: sharing) }
            pass.items.append((module, outcome))
        }
        return pass
    }

     
     
     
    private struct ListView: Decodable {
        let schemaVersion: Int
        let modules: [AdBlockGlobalManifest.Module]
    }

     
     
     
     
    private static func check(_ module: AdBlockGlobalManifest.Module, locations: AdBlockEngineLocations,
                              budget: inout Int, of total: Int, sharing: AdBlockRuleSharing) -> Pass.Outcome {
        func omitted(_ reason: AdBlockEngineReport.OmittedModule.Reason, _ detail: String) -> AdBlockEngineReport.OmittedModule {
            AdBlockEngineReport.OmittedModule(id: module.id, name: module.name, reason: reason, detail: detail)
        }
        var hasher = SHA256()
        let left = max(0, budget)
        var wanted = 0
        var read = AdBlockTopLevelJSON.values(
            keeping: { keptIRKeys.contains($0) }, nested: ["manifest": keptManifestKeys], in: locations.moduleManifest(module.id),
            maximumBytes: maximumIRBytes, maximumValueBytes: left, eachChunk: { hasher.update(data: $0) },
            valueBytes: { wanted = $0 })
        let manifestDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        var kept: [String: Data]
        switch read {
        case .missing:
            return .unsettled(omitted(.unreadable, "its manifest is missing or cannot be read"))
        case .tooLarge:
            return .leftOut(omitted(.unreadable, "its manifest is larger than \(maximumIRBytes) bytes"))
        case .notAnObject, .values:
             
             
            guard manifestDigest == module.irSHA256 else {
                return .unsettled(omitted(.digestMismatch, "its manifest is \(manifestDigest), the module list names \(module.irSHA256)"))
            }
            guard case .values(let values, let oversized) = read else {
                return .leftOut(omitted(.unreadable, "its manifest is not a module this tunnel reads"))
            }
            guard oversized.isEmpty else {
                 
                 
                 
                let size = "what the tunnel keeps of it (its rewrites, engine rules and scripts) is \(wanted) bytes"
                let limit = total < maximumRuleBytes ? " (\(maximumRuleBytes), less what this configuration's host lists hold)" : ""
                 
                 
                 
                 
                 
                let crowdedOut = wanted <= total && left < total
                return .leftOut(omitted(crowdedOut ? .overSharedBudget : .overBudget, wanted > total
                    ? "\(size), more than the \(total) it takes for every module together\(limit)"
                    : "\(size), more than the \(left) left of the \(total) it takes for every module together\(limit)"))
            }
            kept = values
        }
        let keptBytes = kept.values.reduce(0) { $0 + $1.count }
         
        var decoding = kept
        kept = [:]
        read = .missing
        guard let decoded = AdBlockTunnelModuleIR.read(&decoding, sharing: sharing), decoded.schemaVersion == AdBlockModuleIR.currentSchemaVersion else {
            return .leftOut(omitted(.unreadable, "its manifest is not a module this tunnel reads"))
        }
         
         
         
         
         
        let ir: AdBlockTunnelModuleIR
        if let leftOut = module.leftOutOrigins.map(Set.init), !leftOut.isEmpty {
            ir = AdBlockTunnelModuleIR(schemaVersion: decoded.schemaVersion, format: decoded.format,
                                       rewriteRules: decoded.rewriteRules.filter { !leftOut.contains($0.origin) },
                                       engineRules: decoded.engineRules.filter { !leftOut.contains($0.origin) },
                                       scripts: decoded.scripts)
        } else {
            ir = decoded
        }
        for script in ir.scripts {
             
            guard let sha = script.bodySHA256 else { continue }
            switch digest(of: locations.script(module.id, sha256: sha), maximumBytes: maximumScriptBytes) {
            case .missing:
                return .unsettled(omitted(.scriptMismatch, "script \(script.name) (\(sha).js) is missing"))
            case .tooLarge:
                return .leftOut(omitted(.scriptMismatch, "script \(script.name) (\(sha).js) is larger than \(maximumScriptBytes) bytes"))
            case .data(let found) where found != sha:
                return .unsettled(omitted(.scriptMismatch, "script \(script.name) (\(sha).js) holds other bytes (\(found))"))
            case .data:
                continue
            }
        }
        budget -= keptBytes
        return .read(ir, kept: keptBytes)
    }

    private enum Contents<Value> {
        case missing
        case tooLarge
        case data(Value)
    }

     
     
    private static func digest(of url: URL, maximumBytes: Int) -> Contents<String> {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .missing }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        switch AdBlockChunkedRead.each(handle, chunkBytes: 64 * 1024, { chunk in
            total += chunk.count
            guard total <= maximumBytes else { return false }
            hasher.update(data: chunk)
            return true
        }) {
        case .failed: return .missing
        case .stopped: return .tooLarge
        case .end: return .data(hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }
}

 
 
 
 
 
enum AdBlockJSONArrayBatches {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, batch: Int, each: ((inout T) -> Void)? = nil) -> [T]? {
         
        var ends: [Int] = []
        var open = -1
        let shaped: Bool = data.withUnsafeBytes { raw -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            var depth = 0, inString = false, escaped = false, sawValue = false
            for index in bytes.indices {
                let byte = bytes[index]
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == UInt8(ascii: "\\") {
                        escaped = true
                    } else if byte == UInt8(ascii: "\"") {
                        inString = false
                    }
                    continue
                }
                switch byte {
                case UInt8(ascii: "\""):
                    inString = true
                    if depth == 1 { sawValue = true }
                case UInt8(ascii: "["), UInt8(ascii: "{"):
                    if depth == 0 {
                        guard byte == UInt8(ascii: "["), open < 0 else { return false }
                        open = index
                    } else if depth == 1 {
                        sawValue = true
                    }
                    depth += 1
                case UInt8(ascii: "]"), UInt8(ascii: "}"):
                    depth -= 1
                    guard depth >= 0 else { return false }
                    if depth == 0 {
                        if sawValue { ends.append(index) }
                        return index == bytes.count - 1 || bytes[(index + 1)...].allSatisfy { [0x20, 0x09, 0x0A, 0x0D].contains($0) }
                    }
                case UInt8(ascii: ","):
                    if depth == 1 {
                        ends.append(index)
                        sawValue = false
                    }
                case 0x20, 0x09, 0x0A, 0x0D:
                    continue
                default:
                    if depth == 1 { sawValue = true }
                }
            }
            return false
        }
        guard shaped, open >= 0 else { return nil }
        var out: [T] = []
        out.reserveCapacity(ends.count)
        let decoder = AdBlockJSON.decoder()
        var start = open + 1
        var position = 0
        while position < ends.count {
            let last = min(ends.count, position + max(1, batch)) - 1
            var chunk = Data([UInt8(ascii: "[")])
            chunk.append(data[(data.startIndex + start)..<(data.startIndex + ends[last])])
            chunk.append(UInt8(ascii: "]"))
            guard let decoded = try? decoder.decode([T].self, from: chunk) else { return nil }
            if let each {
                for var element in decoded {
                    each(&element)
                    out.append(element)
                }
            } else {
                out.append(contentsOf: decoded)
            }
            start = ends[last] + 1
            position = last + 1
        }
        return out
    }
}

 
 
 
 
enum AdBlockChunkedRead {
    enum Ending: Equatable {
        case end
        case stopped
        case failed
    }

    static func each(_ handle: FileHandle, chunkBytes: Int, _ take: (Data) -> Bool) -> Ending {
        while true {
            let step: Ending? = autoreleasepool {
                do {
                    guard let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty else { return .end }
                    return take(chunk) ? nil : .stopped
                } catch {
                    return .failed
                }
            }
            if let step { return step }
        }
    }
}

 
 
 
 
 
enum AdBlockTopLevelJSON {
    enum Outcome: Equatable {
        case missing
        case tooLarge
         
        case notAnObject
         
         
         
        case values([String: Data], oversized: Set<String>)
    }

    static let chunkBytes = 64 * 1024

    static func values(of keys: Set<String>, in url: URL, maximumBytes: Int, maximumValueBytes: Int,
                       chunkBytes: Int = AdBlockTopLevelJSON.chunkBytes) -> Outcome {
        values(keeping: { keys.contains($0) }, in: url, maximumBytes: maximumBytes, maximumValueBytes: maximumValueBytes,
               chunkBytes: chunkBytes)
    }

     
     
     
     
     
     
     
     
     
    static func values(keeping: @escaping (String) -> Bool, nested: [String: Set<String>] = [:], in url: URL, maximumBytes: Int,
                       maximumValueBytes: Int, chunkBytes: Int = AdBlockTopLevelJSON.chunkBytes, eachChunk: ((Data) -> Void)? = nil,
                       valueBytes: ((Int) -> Void)? = nil) -> Outcome {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .missing }
        defer { try? handle.close() }
        var scanner = Scanner(keeping: keeping, nested: nested, maximumValueBytes: maximumValueBytes)
        var total = 0
        var shaped = true
        switch AdBlockChunkedRead.each(handle, chunkBytes: chunkBytes, { chunk in
            total += chunk.count
            guard total <= maximumBytes else { return false }
            eachChunk?(chunk)
            if shaped { shaped = chunk.withUnsafeBytes { buffer in buffer.allSatisfy { scanner.take($0) } } }
            return shaped || eachChunk != nil
        }) {
        case .failed: return .missing
        case .stopped: return total > maximumBytes ? .tooLarge : .notAnObject
        case .end: break
        }
        guard shaped, scanner.phase == .done else { return .notAnObject }
        valueBytes?(scanner.wanted)
        return .values(scanner.found, oversized: scanner.oversized)
    }

     
    static func object(_ values: [String: Data]) -> Data {
        var out = Data("{".utf8)
        for (index, key) in values.keys.sorted().enumerated() {
            if index > 0 { out.append(UInt8(ascii: ",")) }
            out.append(contentsOf: Array("\"\(key)\":".utf8))
            out.append(values[key] ?? Data())
        }
        out.append(UInt8(ascii: "}"))
        return out
    }

    struct Scanner {
        enum Phase { case start, firstKey, key, colon, value, done }

        let keeping: (String) -> Bool
        let nested: [String: Set<String>]
        let maximumValueBytes: Int
        var phase = Phase.start
         
        private var inner: [Scanner] = []
        private var innerFailed = false
        private(set) var found: [String: Data] = [:]
        private(set) var oversized: Set<String> = []
        private var depth = 0
        private var inString = false
        private var escaped = false
        private var key: [UInt8] = []
        private var currentKey = ""
        private var capture: [UInt8]?
         
        private var kept = 0
         
        private var wantedValue = false
         
        private(set) var wanted = 0

        init(keeping: @escaping (String) -> Bool, nested: [String: Set<String>] = [:], maximumValueBytes: Int) {
            self.keeping = keeping
            self.nested = nested
            self.maximumValueBytes = maximumValueBytes
        }

         
        mutating func take(_ byte: UInt8) -> Bool {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                if depth == 1, phase == .key {
                    if inString {
                         
                        if key.count <= 64 { key.append(byte) }
                    } else {
                        phase = .colon
                    }
                    return true
                }
                keep(byte)
                return true
            }
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                if depth > 1 { keep(byte) }
                return true
            }
            switch depth {
            case 0:
                guard phase == .start, byte == UInt8(ascii: "{") else { return false }
                depth = 1
                phase = .firstKey
                return true
            case 1:
                switch phase {
                case .firstKey, .key:
                    if byte == UInt8(ascii: "\"") {
                        inString = true
                        key = []
                        phase = .key
                        return true
                    }
                    guard phase == .firstKey, byte == UInt8(ascii: "}") else { return false }
                    depth = 0
                    phase = .done
                    return true
                case .colon:
                    guard byte == UInt8(ascii: ":") else { return false }
                    currentKey = String(decoding: key, as: UTF8.self)
                    if let keys = nested[currentKey] {
                        inner = [Scanner(keeping: { keys.contains($0) }, maximumValueBytes: maximumValueBytes)]
                        innerFailed = false
                        wantedValue = false
                        capture = nil
                    } else {
                        wantedValue = keeping(currentKey)
                        capture = wantedValue ? [] : nil
                    }
                    phase = .value
                    return true
                case .value:
                    if byte == UInt8(ascii: ",") || byte == UInt8(ascii: "}") {
                        if let scanner = inner.first {
                             
                            if !innerFailed, scanner.phase == .done, scanner.oversized.isEmpty {
                                let object = AdBlockTopLevelJSON.object(scanner.found)
                                 
                                wanted += object.count
                                if kept + object.count <= maximumValueBytes {
                                    found[currentKey] = object
                                    kept += object.count
                                } else {
                                    oversized.insert(currentKey)
                                }
                            }
                            inner = []
                        }
                        if let capture {
                            found[currentKey] = Data(capture)
                            kept += capture.count
                        }
                        capture = nil
                        wantedValue = false
                        if byte == UInt8(ascii: "}") {
                            depth = 0
                            phase = .done
                        } else {
                            phase = .key
                        }
                        return true
                    }
                    open(byte)
                    keep(byte)
                    return true
                case .start, .done:
                    return false
                }
            default:
                open(byte)
                if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") { depth -= 1 }
                keep(byte)
                return true
            }
        }

        private mutating func open(_ byte: UInt8) {
            if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                depth += 1
            }
        }

        private mutating func keep(_ byte: UInt8) {
            if !inner.isEmpty {
                if !innerFailed, !inner[0].take(byte) { innerFailed = true }
                return
            }
            guard wantedValue else { return }
            wanted += 1
            guard capture != nil else { return }
            guard kept + capture!.count < maximumValueBytes else {
                oversized.insert(currentKey)
                capture = nil
                return
            }
            capture!.append(byte)
        }
    }
}
#endif
