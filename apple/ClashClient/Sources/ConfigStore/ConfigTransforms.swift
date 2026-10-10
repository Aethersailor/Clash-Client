import CryptoKit
import Foundation
import Clash

 
 
struct RemoteResourcePlan: Decodable {
    struct Provider: Decodable {
        let name, kind, behavior, type, url, path, format: String
        let headers: [String: [String]]
        let proxy: String
         
        let resourceKey: String?
         
         
        let updateIntervalSeconds: Int64
         
         
         
        let maximumBytes: Int64

        init(
            name: String,
            kind: String,
            behavior: String,
            type: String,
            url: String,
            path: String,
            format: String,
            headers: [String: [String]],
            proxy: String,
            resourceKey: String?,
            updateIntervalSeconds: Int64 = 0,
            maximumBytes: Int64 = 0
        ) {
            self.name = name
            self.kind = kind
            self.behavior = behavior
            self.type = type
            self.url = url
            self.path = path
            self.format = format
            self.headers = headers
            self.proxy = proxy
            self.resourceKey = resourceKey
            self.updateIntervalSeconds = updateIntervalSeconds
            self.maximumBytes = maximumBytes
        }

        private enum CodingKeys: String, CodingKey {
            case name, kind, behavior, type, url, path, format, headers, proxy, resourceKey
            case updateIntervalSeconds
            case maximumBytes
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decode(String.self, forKey: .name)
            kind = try values.decode(String.self, forKey: .kind)
            behavior = try values.decode(String.self, forKey: .behavior)
            type = try values.decode(String.self, forKey: .type)
            url = try values.decode(String.self, forKey: .url)
            path = try values.decode(String.self, forKey: .path)
            format = try values.decode(String.self, forKey: .format)
            headers = try values.decode([String: [String]].self, forKey: .headers)
            proxy = try values.decode(String.self, forKey: .proxy)
            resourceKey = try values.decodeIfPresent(String.self, forKey: .resourceKey)
            updateIntervalSeconds = try values.decodeIfPresent(
                Int64.self,
                forKey: .updateIntervalSeconds
            ) ?? 0
            maximumBytes = try values.decodeIfPresent(
                Int64.self,
                forKey: .maximumBytes
            ) ?? 0
        }
    }
    struct Geo: Decodable {
        let kind, url: String
    }
    struct Failure: Decodable {
        let field, reason: String
    }

    let providers: [Provider]
    let geodata: [Geo]
    let notices: [String]

     
     
     
     
     
     
     
     
    let structuredNotices: [StructuredNotice]?

     
     
     
    init(
        providers: [Provider] = [],
        geodata: [Geo] = [],
        notices: [String] = [],
        structuredNotices: [StructuredNotice]? = [],
        errors: [Failure] = []
    ) {
        self.providers = providers
        self.geodata = geodata
        self.notices = notices
        self.structuredNotices = structuredNotices
        self.errors = errors
    }

    struct StructuredNotice: Decodable {
        let kind: String
        let field: String?
        let value: String?
        let count: Int?
        let ruleKind: String?
         
         
        let text: String
    }
    let errors: [Failure]
}

enum ConfigTransformsError: LocalizedError {
    case bridgeReturnedNil(String)
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .bridgeReturnedNil(let operation):
            return "The configuration operation \(operation) did not return a result."
        case .invalidConfiguration(let reason):
            return "The downloaded configuration is invalid: \(Self.readable(reason))"
        }
    }

     
     
     
     
     
     
     
     
     
     
     
     
    static func readable(_ reason: String) -> String {
        var text = reason
        let frames = ["clash", "clash", "parse config", "collect config deviations",
                      "finalize", "plan resources", "validate"]
        while let range = text.range(of: ": "), range.lowerBound != text.startIndex {
            let head = String(text[text.startIndex..<range.lowerBound])
            guard frames.contains(head.lowercased()) else { break }
            let rest = String(text[range.upperBound...])
             
             
             
            guard !rest.isEmpty, !frames.contains(rest.lowercased()) else { break }
            text = rest
        }
        return text
    }
}

 
 
 
 
 
 
 
 
 
 
 
 
let clashAppleRuntimeProfileName: String = {
#if os(macOS)
    "macosPacketTunnel"
#elseif os(tvOS)
    "tvosPacketTunnel"
#else
    "iosPacketTunnel"
#endif
}()

enum ConfigTransforms {

     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
    static func validateSource(_ yaml: String) throws {
        let digest = AcceptedSources.digest(yaml)
         
        if !Task.isCancelled, AcceptedSources.shared.contains(digest) { return }
        var error: NSError?
        guard AppCore.validateConfigShape(yaml, &error) else {
             
             
            if let error, (error as Error) is CancellationError { throw CancellationError() }
            throw ConfigTransformsError.invalidConfiguration(
                error?.localizedDescription ?? "the core rejected the YAML"
            )
        }
        AcceptedSources.shared.insert(digest)
    }

     
     
    final class AcceptedSources: @unchecked Sendable {
        static let shared = AcceptedSources()
        struct Digest: Equatable {
            let sha256: SHA256.Digest
            let length: Int
        }

        static func digest(_ yaml: String) -> Digest {
            var copy = ConfigTransforms.nativeText(yaml)
            return copy.withUTF8 { Digest(sha256: SHA256.hash(data: $0), length: $0.count) }
        }

        private let lock = NSLock()
        private var accepted: [Digest] = []
        private let capacity = 8

        func contains(_ digest: Digest) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return accepted.contains(digest)
        }

        func insert(_ digest: Digest) {
            lock.lock(); defer { lock.unlock() }
            accepted.removeAll { $0 == digest }
            accepted.append(digest)
            if accepted.count > capacity { accepted.removeFirst(accepted.count - capacity) }
        }

        func removeAll() {
            lock.lock(); accepted.removeAll(); lock.unlock()
        }
    }

     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
    static func invalidDomainSites(
        in yaml: String, runtimeProfile: String
    ) -> [InvalidDomainSite]? {
        var error: NSError?
        guard let box = AppCore.invalidDomainPatternsJSON(yaml, runtimeProfile, &error),
            error == nil
        else { return nil }
        return InvalidDomainSite.sites(fromJSON: box.value ?? "")
    }

    static func mergeOverride(raw: String, overrideJSON: String) throws -> String {
        var error: NSError?
        guard let box = AppCore.mergeOverride(raw, overrideJSON, &error) else {
            throw error ?? ConfigTransformsError.bridgeReturnedNil("MergeOverrideForIOS")
        }
        return nativeText(box.value)
    }

     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
    static func configDeviationsJSON(configContent: String, targetProfile: String,
                                     lanSharingOn: Bool? = nil) throws -> String {
        ClashSetAllowLanPermitted(lanSharingOn ?? LocalNetworkPermission.isPermitted(
            UserDefaults(suiteName: ClashAppIdentifiers.appGroup)
        ))
        var error: NSError?
        guard let box = AppCore.configDeviationsJSON(configContent, targetProfile, &error) else {
            throw error ?? ConfigTransformsError.bridgeReturnedNil("ConfigDeviationsJSON")
        }
        return box.value
    }

     
     
     
     
     
     
     
     
     
     
    static func planResources(
        mergedYAML: String,
        targetProfile: String = clashAppleRuntimeProfileName
    ) throws -> RemoteResourcePlan {
        var error: NSError?
        guard let box = AppCore.planResources(mergedYAML, targetProfile, &error) else {
            throw error ?? ConfigTransformsError.bridgeReturnedNil("PlanResourcesForProfile")
        }
        return try JSONDecoder().decode(RemoteResourcePlan.self, from: Data(box.value.utf8))
    }

     
     
     
     
     
     
     
     
    static func providerAgeSecretKeys(mergedYAML: String) throws -> [String: String] {
        try providerAgeSecretKeys(root: foundationRoot(ofYAML: mergedYAML))
    }

     
     
    static func providerAgeSecretKeys(root: [String: Any]?) -> [String: String] {
        guard let providers = root?["proxy-providers"] as? [String: Any] else {
            return [:]
        }
        var keys: [String: String] = [:]
        for (name, raw) in providers {
            guard let definition = raw as? [String: Any],
                  (definition["type"] as? String)?.lowercased() == "http",
                  let key = definition["age-secret-key"] as? String,
                  !key.isEmpty else { continue }
            keys["proxy:\(name)"] = key
        }
        return keys
    }

     
     
     
     
     
     
     
    static func routeSetProviderNames(mergedYAML: String) throws -> Set<String> {
        try routeSetProviderNames(root: foundationRoot(ofYAML: mergedYAML))
    }

     
     
    static func routeSetProviderNames(root: [String: Any]?) -> Set<String> {
        guard let tun = root?["tun"] as? [String: Any] else {
            return []
        }
        var names: Set<String> = []
        for key in ["route-address-set", "route-exclude-address-set"] {
            for case let name as String in (tun[key] as? [Any]) ?? [] where !name.isEmpty {
                names.insert(name)
            }
        }
        return names
    }

     
     
     
     
    static func proxyCatalog(
        configContent: String,
        resourceMapJSON: String,
        selectionsJSON: String
    ) throws -> String {
        var error: NSError?
        guard let box = AppCore.proxyCatalog(configContent, resourceMapJSON, selectionsJSON, &error) else {
            throw error ?? ConfigTransformsError.bridgeReturnedNil("ProxyCatalogForIOS")
        }
        return box.value
    }

     
     
    static func syntaxCatalog(targetProfile: String) throws -> String {
        var error: NSError?
        guard let box = AppCore.syntaxCatalog(targetProfile, &error) else {
            throw error ?? ConfigTransformsError.bridgeReturnedNil("SyntaxCatalogForIOS")
        }
        return box.value
    }

     
     
    static func yamlOutline(original: String) throws -> String {
        var error: NSError?
        guard let box = AppCore.yamlOutline(original, &error) else {
            throw error ?? ConfigTransformsError.bridgeReturnedNil("YAMLOutlineForIOS")
        }
        return nativeText(box.value)
    }

     
     
     
     
    static func ruleProviderCatalog(
        configContent: String,
        resourceMapJSON: String,
        compileRuleSets: Bool
    ) throws -> String {
        var error: NSError?
        guard let box = AppCore.ruleProviderCatalog(configContent, resourceMapJSON, compileRuleSets, &error) else {
            throw error ?? ConfigTransformsError.bridgeReturnedNil("RuleProviderCatalogForIOS")
        }
        return box.value
    }

    static func finalize(
        mergedYAML: String,
        providerPaths: [String: String],
        providerReadPaths: [String: String]? = nil,
        seeds: ProviderSeedFacts = ProviderSeedFacts()
    ) throws -> String {
        let mapJSON = try resourceMapJSON(providerPaths: providerPaths, providerReadPaths: providerReadPaths, seeds: seeds)
        var error: NSError?
        guard let box = AppCore.finalize(mergedYAML, mapJSON, &error) else {
            throw error ?? ConfigTransformsError.bridgeReturnedNil("FinalizeForIOS")
        }
        return nativeText(box.value)
    }

     
     
     
     
    struct FinalizedPublication {
        let text: String
        let preflight: PreflightOutcome
         
        let geodataMode: Bool?
         
         
        let listenerPorts: ProfileListenerPorts?
        let listenerPortsAnswered: Bool
         
        let notices: [String]?
    }

     
     
     
     
     
     
     
     
     
    static func finalizeForPublication(
        mergedYAML: String,
        providerPaths: [String: String],
        providerReadPaths: [String: String]? = nil,
        seeds: ProviderSeedFacts = ProviderSeedFacts(),
        orderReference: String? = nil,
        container: URL,
        settings: IPStackSettings? = nil
    ) throws -> FinalizedPublication {
        let mapJSON = try resourceMapJSON(providerPaths: providerPaths, providerReadPaths: providerReadPaths, seeds: seeds)
        var options: [String: Any] = [
            "targetProfile": clashAppleRuntimeProfileName,
            "plan": true, "intent": true, "geodataMode": true,
            "topLevelKeys": ProfileListenerPorts.topLevelKeys,
        ]
        if let orderReference { options["orderReference"] = orderReference }
        let optionsJSON = String(decoding: try JSONSerialization.data(withJSONObject: options), as: UTF8.self)
        var setUp = false
        do {
            return try AppCoreSetup.withConfiguration(container: container, settings: settings) {
                setUp = true
                var error: NSError?
                guard let box = AppCore.finalizeWithOptions(mergedYAML, mapJSON, optionsJSON, &error) else {
                    throw error ?? ConfigTransformsError.bridgeReturnedNil("FinalizeForIOSWithOptions")
                }
                return try decodePublication(box.value)
            }
        } catch where !setUp {
             
             
             
            let text = try finalize(mergedYAML: mergedYAML, providerPaths: providerPaths,
                                    providerReadPaths: providerReadPaths, seeds: seeds)
            return FinalizedPublication(
                text: text,
                preflight: PreflightOutcome(ok: false, intentJSON: nil, errorMessage: error.localizedDescription),
                geodataMode: nil, listenerPorts: nil, listenerPortsAnswered: false, notices: nil)
        }
    }

     
     
     
     
     
     
    struct ProviderSeedFacts: Equatable {
        var fetchedAt: [String: Int64] = [:]
        var subscriptionInfo: [String: String] = [:]
    }

     
    static func resourceMapJSON(providerPaths: [String: String], providerReadPaths: [String: String]?,
                                seeds: ProviderSeedFacts) throws -> String {
        var payload: [String: Any] = ["providerPaths": providerPaths]
        if let providerReadPaths { payload["providerReadPaths"] = providerReadPaths }
        if !seeds.fetchedAt.isEmpty { payload["providerFetchedAt"] = seeds.fetchedAt }
        if !seeds.subscriptionInfo.isEmpty { payload["providerSubscriptionInfo"] = seeds.subscriptionInfo }
        return String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
    }

    static func decodePublication(_ answer: String) throws -> FinalizedPublication {
        let members = JSONMembers.rawValues(["text", "plan", "intent", "intentError", "geodataMode", "topLevel"],
                                            in: answer)
        guard let text = JSONMembers.string(members["text"]) else {
            throw ConfigTransformsError.bridgeReturnedNil("FinalizeForIOSWithOptions")
        }
        let preflight: PreflightOutcome
        if let intent = members["intent"] {
            preflight = PreflightOutcome(ok: true, intentJSON: intent, errorMessage: nil)
        } else {
            preflight = PreflightOutcome(ok: false, intentJSON: nil,
                                         errorMessage: JSONMembers.string(members["intentError"]) ?? "intent extraction failed")
        }
         
         
        var keys: [String: Any] = [:]
        if let topLevel = members["topLevel"] {
            keys = try JSONSerialization.jsonObject(with: Data(topLevel.utf8)) as? [String: Any] ?? [:]
        }
        var notices: [String]?
        if let plan = members["plan"] {
            notices = try JSONDecoder().decode(RemoteResourcePlan.self, from: Data(plan.utf8)).notices
        }
        return FinalizedPublication(text: text, preflight: preflight,
                                    geodataMode: members["geodataMode"].map { $0 == "true" },
                                    listenerPorts: ProfileListenerPorts.parse(topLevel: keys),
                                    listenerPortsAnswered: true, notices: notices)
    }

     
     
     
     
     
     
     
     
     
    static let maximumConfigurationDepth = 60

     
     
    static func jsonNestingDepth(_ json: String) -> Int {
        var depth = 0, deepest = 0
        var inString = false, escaped = false
        for byte in json.utf8 {
            if escaped { escaped = false; continue }
            switch byte {
            case UInt8(ascii: "\\"): if inString { escaped = true }
            case UInt8(ascii: "\""): inString.toggle()
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                if !inString { depth += 1; deepest = max(deepest, depth) }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if !inString { depth -= 1 }
            default: break
            }
        }
        return deepest
    }

     
     
     
     
     
     
     
     
     
     
     
    static func parsedRoot(forYAML yaml: String) -> ParsedConfiguration? {
        ParsedConfigurationCache.shared.parsed(for: yaml)
    }

     
     
     
     
     
    static func foundationRoot(ofYAML yaml: String) throws -> [String: Any]? {
        let json = try yamlToJSON(yaml)
        return try PerfLedger.measure("JSONSerialization root") {
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        }
    }

    struct ParsedConfiguration {
         
         
        let json: String
         
         
        let root: [String: Any]
         
         
         
        let derivations = ParsedConfigurationDerivations()

         
         
         
         
         
        func memo<T>(_ key: String, _ compute: () -> T) -> T {
            derivations.value(for: key, compute)
        }
    }

    static func yamlToJSON(
        _ yaml: String,
        caller: StaticString = #fileID,
        line: UInt = #line
    ) throws -> String {
         
         
         
        if let known = KnownDocuments.shared.document(for: yaml) { return known }



        var error: NSError?
        guard let box = PerfLedger.measure("yamlToJSON \(caller):\(line)", { ClashYamlToJSON(yaml, &error) }) else {
            throw error ?? ConfigTransformsError.bridgeReturnedNil("YamlToJSON")
        }
         
         
         
         
         
         
         
        let json = nativeText(box.value)
        try checkNesting(json)
         
         
         
        if yaml.utf8.count >= KnownYAML.rememberedFromBytes {
            KnownDocuments.shared.remember(json, for: yaml, nestingChecked: true)
        }
        return json
    }

     
     
    static func checkNesting(_ json: String) throws {
        let depth = jsonNestingDepth(json)
        if depth > Self.maximumConfigurationDepth {
            throw ConfigTransformsError.invalidConfiguration(
                "it nests \(depth) levels deep; \(Self.maximumConfigurationDepth) is the most a configuration can mean"
            )
        }
    }

     
     
     
     
     
     
     
    final class KnownDocuments: @unchecked Sendable {
        static let shared = KnownDocuments()

        private let lock = NSLock()
        private var slots: [(digest: AcceptedSources.Digest, json: String)] = []
         
         
         
         
        private let capacity = 4

         
         
         
        func remember(_ json: String, for text: String, nestingChecked: Bool = false) {
            guard nestingChecked || (try? ConfigTransforms.checkNesting(json)) != nil else { return }
            let digest = AcceptedSources.digest(text)
            let native = ConfigTransforms.nativeText(json)
            lock.lock(); defer { lock.unlock() }
            slots.removeAll { $0.digest == digest }
            slots.append((digest, native))
            if slots.count > capacity { slots.removeFirst(slots.count - capacity) }
        }

        func document(for text: String) -> String? {
             
             
             
            let length = text.utf8.count
            lock.lock()
            let candidate = slots.contains { $0.digest.length == length }
            lock.unlock()
            guard candidate else { return nil }
            let digest = AcceptedSources.digest(text)
            lock.lock(); defer { lock.unlock() }
            return slots.last { $0.digest == digest }?.json
        }

        func removeAll() {
            lock.lock(); slots.removeAll(); lock.unlock()
        }
    }

     
     
     
     
     
     
     
     
     
     
    static func nativeText(_ text: String) -> String {
        if text.isContiguousUTF8 { return text }
        if let data = (text as NSString).data(using: String.Encoding.utf8.rawValue, allowLossyConversion: false) {
            return String(decoding: data, as: UTF8.self)
        }
        var copy = text
        copy.makeContiguousUTF8()
        return copy
    }

     
     
     
     
     
     
    final class KnownYAML: @unchecked Sendable {
        static let shared = KnownYAML()
         
        static let rememberedFromBytes = 64 * 1024

        private let lock = NSLock()
        private var slots: [(digest: AcceptedSources.Digest, yaml: String)] = []
        private let capacity = 4

        func remember(_ yaml: String, for json: String) {
            guard json.utf8.count >= Self.rememberedFromBytes else { return }
            let digest = AcceptedSources.digest(json)
            let native = ConfigTransforms.nativeText(yaml)
            lock.lock(); defer { lock.unlock() }
            slots.removeAll { $0.digest == digest }
            slots.append((digest, native))
            if slots.count > capacity { slots.removeFirst(slots.count - capacity) }
        }

        func text(for json: String) -> String? {
             
             
            let length = json.utf8.count
            guard length >= Self.rememberedFromBytes else { return nil }
            lock.lock()
            let candidate = slots.contains { $0.digest.length == length }
            lock.unlock()
            guard candidate else { return nil }
            let digest = AcceptedSources.digest(json)
            lock.lock(); defer { lock.unlock() }
            return slots.last { $0.digest == digest }?.yaml
        }

        func removeAll() {
            lock.lock(); slots.removeAll(); lock.unlock()
        }
    }

     
     
     
     
     
    static func validatedJSON(_ yaml: String, caller: StaticString = #fileID, line: UInt = #line) throws -> String {
        let digest = AcceptedSources.digest(yaml)
        if !Task.isCancelled, AcceptedSources.shared.contains(digest) {
            return try yamlToJSON(yaml, caller: caller, line: line)
        }
        return try combinedValidation(yaml, digest: digest, caller: caller, line: line)
    }

     
     
     
     
    static func validateSourceRemembering(_ yaml: String) throws {
        let digest = AcceptedSources.digest(yaml)
        if !Task.isCancelled, AcceptedSources.shared.contains(digest) { return }
        _ = try combinedValidation(yaml, digest: digest, caller: #fileID, line: #line)
    }

    private static func combinedValidation(_ yaml: String, digest: AcceptedSources.Digest,
                                           caller: StaticString, line: UInt) throws -> String {
        var error: NSError?
        guard let box = AppCore.yamlToJSONWithOptions(yaml, #"{"validateShape":true}"#, &error) else {
            if let error, (error as Error) is CancellationError { throw CancellationError() }
            throw error ?? ConfigTransformsError.bridgeReturnedNil("YamlToJSONWithOptions")
        }
        let members = JSONMembers.rawValues(["document", "documentError", "shapeError"], in: box.value)
        if let shapeError = JSONMembers.string(members["shapeError"]) {
            throw ConfigTransformsError.invalidConfiguration(shapeError)
        }
        AcceptedSources.shared.insert(digest)
         
         
        guard members["documentError"] == nil, let json = members["document"] else {
            return try yamlToJSON(yaml, caller: caller, line: line)
        }
        try checkNesting(json)
        KnownDocuments.shared.remember(json, for: yaml, nestingChecked: true)
        return json
    }

     
     
     
     
     
     
     
     
     
     
     
     
     
    struct ParsedDocument {
        var root: [String: Any]
         
         
         
         
         
         
         
         
         
         
         
         
         
         
         
         
         
        private var writtenOrder: OrderedJSON? {
            json.flatMap { try? OrderedJSON.parse($0) }
        }

         
         
        let json: String?

        init(root: [String: Any]) {
            self.root = root
            self.json = nil
        }

        init(yaml: String) throws {
            let json = try ConfigTransforms.yamlToJSON(yaml)
            guard let root = try JSONSerialization
                .jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                throw ConfigTransformsError.invalidConfiguration(
                    "the configuration's root is not a mapping"
                )
            }
            self.root = root
            self.json = json
        }

         
         
         
         
        func serialized() throws -> String {
            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.sortedKeys]
            )
            let sorted = String(decoding: data, as: UTF8.self)
             
             
             
             
            guard let writtenOrder,
                  let tree = try? OrderedJSON.parse(sorted) else {
                return try ConfigTransforms.jsonToYAML(sorted)
            }
            let restored = tree.reorderingMappings(following: writtenOrder)
            return try ConfigTransforms.jsonToYAML(restored.serialized())
        }
    }

     
     
    static func jsonToYAML(
        _ json: String,
        caller: StaticString = #fileID,
        line: UInt = #line
    ) throws -> String {



         
        if let known = KnownYAML.shared.text(for: json) { return known }
        var error: NSError?
        guard let box = PerfLedger.measure("jsonToYAML \(caller):\(line)", { ClashJSONToYaml(json, &error) }) else {
            throw error ?? ConfigTransformsError.bridgeReturnedNil("JSONToYaml")
        }
        let yaml = nativeText(box.value)
        KnownYAML.shared.remember(yaml, for: json)
        return yaml
    }

     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
    static let dnsBootstrapFallbacks = ["223.5.5.5", "119.29.29.29"]

    static func applyDNSBootstrapInsurance(_ yaml: String) throws -> String {
        let json = try yamlToJSON(yaml)
        var root = try OrderedJSON.parse(json)
        guard case .object = root,
              case var .object(dns)? = root.topLevelValue("dns")
        else { return yaml }
        func appended(_ list: OrderedJSON?) -> OrderedJSON {
            var items: [OrderedJSON]
            if case let .array(existing)? = list { items = existing }
            else { items = [] }
            for ip in dnsBootstrapFallbacks
                where !items.contains(.string(ip)) && !items.contains(.scalar(ip))
            {
                items.append(.string(ip))
            }
            return .array(items)
        }
        for key in ["proxy-server-nameserver", "default-nameserver"] {
            let value = appended(
                dns.first(where: { $0.key == key })?.value
            )
            if let index = dns.firstIndex(where: { $0.key == key }) {
                dns[index] = (key: key, value: value)
            } else {
                dns.append((key: key, value: value))
            }
        }
        root = root.settingTopLevel("dns", to: .object(dns))
        return try jsonToYAML(root.serialized())
    }

     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
    static func restoringMappingOrder(of transformed: String, following source: String) -> String {
        guard transformed != source,
              let sourceJSON = try? yamlToJSON(source),
              let transformedJSON = try? yamlToJSON(transformed),
              let sourceTree = try? OrderedJSON.parse(sourceJSON),
              let transformedTree = try? OrderedJSON.parse(transformedJSON)
        else { return transformed }
        let restored = transformedTree.reorderingMappings(following: sourceTree)
        guard restored != transformedTree,
              let yaml = try? jsonToYAML(restored.serialized())
        else { return transformed }
        return yaml
    }

     
     
     
    static func applyClientRuntimePolicy(
        _ yaml: String,
        udpFallback: UDPFallbackPolicy,
        excludeAPNsRoute: Bool = false,
        json: String? = nil
    ) throws -> String {
        var root = try clientRuntimeRootBeforeUDPFallbackGuard(yaml, json: json)
        try appendUDPFallbackGuard(udpFallback, to: &root)
        if excludeAPNsRoute {
            appendAPNsFakeIPFilter(to: &root)
        }
        return try jsonToYAML(root.serialized())
    }

     
     
     
    static let kernelDefaultFakeIPFilter = [
        "dns.msftnsci.com", "www.msftnsci.com", "www.msftconnecttest.com",
    ]

     
     
     
     
     
    static let apnsFakeIPFilterEntry = "+.push.apple.com"

     
     
     
     
     
     
     
    private static func appendAPNsFakeIPFilter(to root: inout OrderedJSON) {
        let dns = root.topLevelValue("dns")
        if case let .string(mode)? = dns?.topLevelValue("fake-ip-filter-mode"),
           mode.lowercased() == "whitelist" {
            return
        }
        let entry = OrderedJSON.string(apnsFakeIPFilterEntry)
        var filter: [OrderedJSON]
        if case let .array(existing)? = dns?.topLevelValue("fake-ip-filter") {
            filter = existing
        } else {
            filter = kernelDefaultFakeIPFilter.map { .string($0) }
        }
        guard !filter.contains(entry) else { return }
        filter.append(entry)
        root = root.setting(path: ["dns", "fake-ip-filter"], to: .array(filter))
    }

     
     
     
     
     
     
     
     
     
     
     
     
     
     
    struct UDPFallbackGuardInput: Equatable {
        var rules: [String]
        var subRules: [String: [String]]
    }

    static func udpFallbackGuardInput(_ yaml: String) throws -> UDPFallbackGuardInput {
        let root = try clientRuntimeRootBeforeUDPFallbackGuard(yaml)
        var input = UDPFallbackGuardInput(rules: [], subRules: [:])
        if case let .array(rules)? = root.topLevelValue("rules") {
            input.rules = ruleTexts(rules)
        }
        if case let .object(lists)? = root.topLevelValue("sub-rules") {
            for entry in lists {
                if case let .array(list) = entry.value {
                    input.subRules[entry.key] = ruleTexts(list)
                }
            }
        }
        return input
    }

     
     
     
     
    private static func clientRuntimeRootBeforeUDPFallbackGuard(
        _ yaml: String,
        json known: String? = nil
    ) throws -> OrderedJSON {
        let json = try known ?? yamlToJSON(yaml)
         
         
         
         
         
         
         
         
         
         
         
        var root = try OrderedJSON.parse(json)
        guard case .object = root else {
            throw ConfigTransformsError.invalidConfiguration(
                "the runtime configuration root must be an object"
            )
        }

#if !os(macOS)
         
         
         
         
         
         
        root = root.settingTopLevel("find-process-mode", to: .string("off"))
#endif
         
         
         
         
         
         
         
         
         
         
         
         
         
         
         
         
         
         
         
         
         
        let dnsSection = root.topLevelValue("dns")
        let dnsEnabled = dnsSection?.topLevelValue("enable") == .scalar("true")
        if !dnsEnabled,
           case let .object(fields)? = dnsSection,
           fields.contains(where: { $0.key == "nameserver" }) {
            var updated = fields.filter { $0.key != "enable" }
            updated.insert((key: "enable", value: .scalar("true")), at: 0)
            root = root.settingTopLevel("dns", to: .object(updated))
        }

         
         
         
         
         
         
         
        for key in iosUnsupportedTopLevelKeys {
            root = root.removingTopLevel(key)
        }

        return root
    }

     
     
    private static func appendUDPFallbackGuard(
        _ udpFallback: UDPFallbackPolicy,
        to root: inout OrderedJSON
    ) throws {
         
         
         
         
         
         
         
         
         
         
         
         
         
         
         
         
         
        if case let .array(existingRules)? = root.topLevelValue("rules"),
           let guarded = Self.appendingUDPFallback(
               udpFallback, to: existingRules
           ) {
            root = root.settingTopLevel("rules", to: .array(guarded))
        }

         
         
         
         
         
         
         
        if case let .object(lists)? = root.topLevelValue("sub-rules") {
            var updated = lists
            for (offset, entry) in lists.enumerated() {
                guard case let .array(subRules) = entry.value,
                      let guarded = Self.appendingUDPFallback(
                          udpFallback, to: subRules
                      )
                else { continue }
                updated[offset] = (key: entry.key, value: .array(guarded))
            }
            root = root.settingTopLevel("sub-rules", to: .object(updated))
        }
    }

     
     
    private static func appendingUDPFallback(
        _ policy: UDPFallbackPolicy,
        to rules: [OrderedJSON]
    ) -> [OrderedJSON]? {
        guard let rule = UDPFallbackGuard.ruleToInject(
            policy: policy, existingRules: ruleTexts(rules)
        ) else { return nil }
        return rules + [.string(rule)]
    }

     
     
    private static func ruleTexts(_ rules: [OrderedJSON]) -> [String] {
        rules.compactMap { item -> String? in
            if case let .string(text) = item { return text }
            return nil
        }
    }

     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
    static let iosUnsupportedTopLevelKeys: Set<String> = [
         
         
         
         
         
        "redir-port", "tproxy-port",
         
         
         
        "external-controller-pipe",
    ]

}

 
 
 
 
 
final class ParsedConfigurationDerivations: @unchecked Sendable {
    private let condition = NSCondition()
    private var values: [String: Any] = [:]
    private var inFlight: Set<String> = []

     
     
     
     
     
     
     
    func value<T>(for key: String, waits: Bool = !Thread.isMainThread, _ compute: () -> T) -> T {
        condition.lock()
        while true {
            if let known = values[key] as? T {
                condition.unlock()
                return known
            }
            if !inFlight.contains(key) { break }
            if !waits {
                condition.unlock()
                return compute()
            }
            condition.wait()
        }
        inFlight.insert(key)
        condition.unlock()

        let computed = compute()

        condition.lock()
        inFlight.remove(key)
        let result: T
        if let known = values[key] as? T {
            result = known
        } else {
            values[key] = computed
            result = computed
        }
        condition.broadcast()
        condition.unlock()
        return result
    }
}

 
 
 
 
final class ParsedConfigurationCache: @unchecked Sendable {
    static let shared = ParsedConfigurationCache()

    private let lock = NSLock()
    private var slots: [(yaml: String, parsed: ConfigTransforms.ParsedConfiguration)] = []
    private var parseCount = 0
    private let capacity = 2

    func parsed(for yaml: String) -> ConfigTransforms.ParsedConfiguration? {
        lock.lock()
        if let index = slots.firstIndex(where: { $0.yaml == yaml }) {
            let hit = slots.remove(at: index)
            slots.append(hit)
            lock.unlock()
            return hit.parsed
        }
        lock.unlock()
         
         
         
        guard let json = try? ConfigTransforms.yamlToJSON(yaml),
              let root = try? JSONSerialization.jsonObject(
                with: Data(json.utf8)
              ) as? [String: Any]
        else { return nil }
        let parsed = ConfigTransforms.ParsedConfiguration(json: json, root: root)
        lock.lock()
        parseCount += 1
        slots.removeAll { $0.yaml == yaml }
        slots.append((yaml, parsed))
        if slots.count > capacity {
            slots.removeFirst(slots.count - capacity)
        }
        lock.unlock()
        return parsed
    }

     
    var parses: Int {
        lock.lock(); defer { lock.unlock() }
        return parseCount
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        slots.removeAll()
        parseCount = 0
    }
}



 
 
 
 
 
 
 
 
 
 
 
enum JSONMembers {
     
     
     
    static func rawValues(_ keys: Set<String>, in json: String) -> [String: String] {
        let copy = ConfigTransforms.nativeText(json)
        return copy.utf8.withContiguousStorageIfAvailable { scan($0, keys) } ?? [:]
    }

     
    static func string(_ literal: String?) -> String? {
        guard let literal else { return nil }
        return ((try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: [.fragmentsAllowed])) as? String)
            .map(ConfigTransforms.nativeText)
    }

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

     
    private static func stringEnd(_ base: UnsafePointer<UInt8>, _ end: Int, _ start: Int) -> Int {
        var from = start + 1
        while from < end {
            guard let hit = memchr(base + from, Int32(quote), end - from) else { return -1 }
            let at = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            var slashes = 0
            var before = at - 1
            while before > start, base[before] == backslash { slashes += 1; before -= 1 }
            if slashes % 2 == 0 { return at + 1 }
            from = at + 1
        }
        return -1
    }

     
    private static func valueEnd(_ base: UnsafePointer<UInt8>, _ end: Int, _ start: Int) -> Int {
        guard start < end else { return -1 }
        let first = base[start]
        if first == quote { return stringEnd(base, end, start) }
        if first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            var depth = 0
            var at = start
            while at < end {
                let byte = base[at]
                if byte == quote {
                    let past = stringEnd(base, end, at)
                    if past < 0 { return -1 }
                    at = past
                    continue
                }
                if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                    depth += 1
                } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                    depth -= 1
                    if depth == 0 { return at + 1 }
                }
                at += 1
            }
            return -1
        }
         
        var at = start
        while at < end {
            let byte = base[at]
            if byte == UInt8(ascii: ",") || byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") || isSpace(byte) { break }
            at += 1
        }
        return at
    }

    private static func scan(_ buffer: UnsafeBufferPointer<UInt8>, _ keys: Set<String>) -> [String: String] {
        guard let base = buffer.baseAddress else { return [:] }
        let end = buffer.count
        func text(_ from: Int, _ to: Int) -> String {
            String(decoding: UnsafeBufferPointer(start: base + from, count: to - from), as: UTF8.self)
        }
        var found: [String: String] = [:]
        var at = 0
        while at < end, isSpace(base[at]) { at += 1 }
        guard at < end, base[at] == UInt8(ascii: "{") else { return [:] }
        at += 1
        while found.count < keys.count {
            while at < end, isSpace(base[at]) { at += 1 }
            guard at < end, base[at] == quote else { break }
            let keyEnd = stringEnd(base, end, at)
            guard keyEnd > 0 else { break }
            let key = text(at + 1, keyEnd - 1)
            at = keyEnd
            while at < end, isSpace(base[at]) { at += 1 }
            guard at < end, base[at] == UInt8(ascii: ":") else { break }
            at += 1
            while at < end, isSpace(base[at]) { at += 1 }
            let valueStart = at
            let valueStop = valueEnd(base, end, valueStart)
            guard valueStop > 0 else { break }
            if keys.contains(key) { found[key] = text(valueStart, valueStop) }
            at = valueStop
            while at < end, isSpace(base[at]) { at += 1 }
            guard at < end, base[at] == UInt8(ascii: ",") else { break }
            at += 1
        }
        return found
    }
}
