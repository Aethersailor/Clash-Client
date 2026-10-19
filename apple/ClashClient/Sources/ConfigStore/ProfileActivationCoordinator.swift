import CryptoKit
import Foundation
import ClashClientKit
import ClashClientUI

enum PipelineError: LocalizedError {
    case planRejected([RemoteResourcePlan.Failure])
    case externalResources([IOSExternalResourceFinding])
    case sourceUnavailable(String)
    case notModifiedWithoutActive
    case preflightFailed(String)
    case providerNotFound(String)
     
     
     
     
     
     
    case activationReadback
     
     
     
    case sourceSuperseded

    var errorDescription: String? {
        switch self {
        case .planRejected(let failures):
            return failures.map { "\($0.field): \($0.reason)" }.joined(separator: "; ")
        case .externalResources(let findings):
            return findings.compactMap(\.errorDescription).joined(separator: " ")
        case .sourceUnavailable(let reason):
            return reason
        case .notModifiedWithoutActive:
            return "The profile URL was not modified, but this profile has no active revision."
        case .preflightFailed(let reason):
            return "Configuration validation failed: \(reason)"
        case .providerNotFound(let name):
            return "Provider '\(name)' is no longer present in this profile."
        case .activationReadback:
            return "The activated revision could not be read back after publication."
        case .sourceSuperseded:
            return "The source changed while it was downloaded; the newer one is kept."
        }
    }

     
     
     
     
     
     
     
    var authoredText: AuthoredText {
        switch self {
        case .planRejected, .externalResources, .sourceUnavailable:
            return .app(errorDescription ?? "")
        case .notModifiedWithoutActive:
            return .app("The profile URL was not modified, but this profile has no active revision.")
        case .preflightFailed(let reason):
            return .app("Configuration validation failed: %@", arguments: [reason])
        case .providerNotFound(let name):
            return .app("Provider '%@' is no longer present in this profile.", arguments: [name])
        case .activationReadback:
            return .app("The activated revision could not be read back after publication.")
        case .sourceSuperseded:
            return .app("The source changed while it was downloaded; the newer one is kept.")
        }
    }
}

struct ProviderRuntimeUpdate: Equatable {
    let name: String
    let kind: String
    let payload: Data
     
     
     
    var publishedIn: ActiveConfigurationPointer? = nil
}

struct ProviderRefreshResult: Equatable {
    let pointer: ActiveConfigurationPointer
     
     
    let runtimeUpdate: ProviderRuntimeUpdate?
}

private struct ProfilePublicationResult {
    let pointer: ActiveConfigurationPointer
     
    var previous: ActiveConfigurationPointer? = nil
    let runtimeUpdates: [String: ProviderRuntimeUpdate]
     
    var firstLoadPending: [String] = []
    var publishedRouteNames: Set<String> = []
}

 
 
 
 
enum ProfileRuntimeConfigBuilder {
    static func buildProduction(
        raw: String,
        profile: Profile,
        runtimeOverride: OverrideSpec = FlClashRuntimeConfig.load(),
        applyProviderDefinitions: Bool = true,
        applyProxyChain: Bool = true,
        applyLegacyRelayMigration: Bool = true
    ) throws -> String {
        try buildProductionStages(
            raw: raw,
            profile: profile,
            runtimeOverride: runtimeOverride,
            applyProviderDefinitions: applyProviderDefinitions,
            applyProxyChain: applyProxyChain,
            applyLegacyRelayMigration: applyLegacyRelayMigration
        ).finished()
    }

     
     
     
     
     
     
     
     
    static func buildProductionStages(
        raw: String,
        profile: Profile,
        runtimeOverride: OverrideSpec = FlClashRuntimeConfig.load(),
        globalOverride: OverrideSpec = GlobalConfig.load(),
        applyProviderDefinitions: Bool = true,
        applyProxyChain: Bool = true,
        applyLegacyRelayMigration: Bool = true
    ) throws -> RuntimeBuildStages {
        try ProfilePostMergeScriptOwnershipPolicy.validate(
            postMergeScriptID: profile.postMergeScriptID,
            legacyGlobalScriptEnabled: ScriptSettings.enabled()
        )
        return try buildStages(
            raw: raw,
            profile: profile,
            globalOverride: globalOverride,
            runtimeOverride: runtimeOverride,
            profileScript: { try ScriptLibrary.apply(id: $0, to: $1, profileName: $2) },
            configScript: { try ScriptSettings.apply(toConfigYAML: $0, profileName: $1) },
            postMergeScript: { try ScriptLibrary.apply(id: $0, to: $1, profileName: $2) },
            applyProviderDefinitions: applyProviderDefinitions,
            applyProxyChain: applyProxyChain,
            applyLegacyRelayMigration: applyLegacyRelayMigration
        )
    }

     
     
     
     
     
    static func udpFallbackGuardInput(
        raw: String,
        profile: Profile,
        runtimeOverride: OverrideSpec = FlClashRuntimeConfig.load()
    ) throws -> ConfigTransforms.UDPFallbackGuardInput {
        try ConfigTransforms.udpFallbackGuardInput(
            buildProductionStages(
                raw: raw, profile: profile, runtimeOverride: runtimeOverride
            ).beforeClientRuntimePolicy
        )
    }

     
     
     
     
     
     
     
     
    struct RuntimeBuildStages {
         
         
        let afterClientTransforms: String
         
         
        let beforeClientRuntimePolicy: String
         
        let udpFallback: UDPFallbackPolicy
         
         
         
        var excludeAPNsRoute = false
         
         
         
         
        var providerMerge = ProviderDefinitionMergeReport()
         
         
         
         
         
         
        var profileLogLevel: String?
         
         
         
         
        var beforeClientRuntimePolicyJSON: String?
         
         
         
         
         
        var nodesJSON: String?

         
        func finished() throws -> String {
            try ConfigTransforms.applyClientRuntimePolicy(
                beforeClientRuntimePolicy,
                udpFallback: udpFallback,
                excludeAPNsRoute: excludeAPNsRoute,
                json: beforeClientRuntimePolicyJSON
            )
        }
    }

     
     
     
     
     
     
     
    static func finishedReading(_ stages: RuntimeBuildStages) throws -> (yaml: String, root: [String: Any]?) {
        let reading = try ConfigTransforms.applyClientRuntimePolicyReading(
            stages.beforeClientRuntimePolicy,
            udpFallback: stages.udpFallback,
            excludeAPNsRoute: stages.excludeAPNsRoute,
            json: stages.beforeClientRuntimePolicyJSON
        )
        func readWhole() -> [String: Any]? { (try? ConfigTransforms.foundationRoot(ofYAML: reading.yaml)) ?? nil }
        guard var root = (try? ConfigTransforms.foundationRoot(ofJSON: reading.json)) ?? nil else {
            return (reading.yaml, readWhole())
        }
        if reading.omitsNodes {
            guard let nodesJSON = stages.nodesJSON,
                  let nodes = (try? ConfigTransforms.foundationRoot(ofJSON: nodesJSON)) ?? nil else {
                return (reading.yaml, readWhole())
            }
            root["proxies"] = nodes["proxies"]
        }
        return (reading.yaml, root)
    }

    static func build(
        raw: String,
        profile: Profile,
        globalOverride: OverrideSpec,
        runtimeOverride: OverrideSpec = OverrideSpec(),
        profileScript: (String?, String, String) throws -> String,
        configScript: (String, String) throws -> String,
        postMergeScript: (String?, String, String) throws -> String = { _, yaml, _ in yaml },
        applyProviderDefinitions: Bool = true,
        applyProxyChain: Bool = true,
        applyLegacyRelayMigration: Bool = true,
        logLevelDirective: ClashLogSettings.LevelDirective? = nil
    ) throws -> String {
        try buildStages(
            raw: raw,
            profile: profile,
            globalOverride: globalOverride,
            runtimeOverride: runtimeOverride,
            profileScript: profileScript,
            configScript: configScript,
            postMergeScript: postMergeScript,
            applyProviderDefinitions: applyProviderDefinitions,
            applyProxyChain: applyProxyChain,
            applyLegacyRelayMigration: applyLegacyRelayMigration,
            logLevelDirective: logLevelDirective
        ).finished()
    }

    static func buildStages(
        raw: String,
        profile: Profile,
        globalOverride: OverrideSpec,
        runtimeOverride: OverrideSpec = OverrideSpec(),
         
         
         
         
        profileScript: (String?, String, String) throws -> String,
        configScript: (String, String) throws -> String,
        postMergeScript: (String?, String, String) throws -> String = { _, yaml, _ in yaml },
        applyProviderDefinitions: Bool = true,
        applyProxyChain: Bool = true,
        applyLegacyRelayMigration: Bool = true,
         
         
         
         
         
         
        logLevelDirective: ClashLogSettings.LevelDirective? = nil
    ) throws -> RuntimeBuildStages {
        let profileWorking: String
        switch profile.overwriteMode ?? .standard {
        case .standard, .script:
            var spec = profile.override
             
             
             
            spec.patchJSON = OverridePatch(
                patchJSON: spec.patchJSON
            ).profileOwnedPatch.patchJSON
             
             
            let muted = Set(spec.disabledAppendRules ?? [])
            var personalRules = spec.appendRules.filter { !muted.contains($0) }
            spec.appendRules = []
            let patched = try ConfigTransforms.mergeOverride(
                raw: raw,
                overrideJSON: overrideJSON(from: spec)
            )
             
             
             
            let scripted = profile.overwriteMode == .script
                ? try profileScript(profile.selectedScriptID, patched, profile.label)
                : patched
             
             
             
             
             
             
             
             
             
            personalRules = try resolvedFallbackTargets(personalRules, mergedInto: scripted)
            let kept = droppingUnknownTargets(personalRules, mergedInto: scripted).kept
            profileWorking = kept.isEmpty ? scripted : try ConfigTransforms.mergeOverride(
                raw: scripted,
                overrideJSON: overrideJSON(from: OverrideSpec(appendRules: kept, prependRules: spec.prependRules))
            )
        case .custom:
            let overwritten = try (profile.customOverwrite ?? CustomOverwriteSpec())
                .applyForFinalRuntimeMigration(to: raw)
             
             
             
             
             
            let listener = OverridePatch(patchJSON: profile.override.patchJSON)
                .retainingTopLevelKeys(OverridePatch.listenerKeys)
            profileWorking = listener.patchJSON.isEmpty ? overwritten : try ConfigTransforms.mergeOverride(
                raw: overwritten,
                overrideJSON: overrideJSON(from: OverrideSpec(patchJSON: listener.patchJSON))
            )
        }

        var effectiveGlobal = profile.migratedGlobalOverride ?? globalOverride
         
         
         
         
         
         
         
         
        if (profile.overwriteMode ?? .standard) != .standard {
            effectiveGlobal.appendRules = []
        }
        let disabledRules = Set(profile.override.disabledGlobalRules ?? [])
        effectiveGlobal.appendRules.removeAll { disabledRules.contains($0) }
        effectiveGlobal.appendRules = try resolvedFallbackTargets(
            effectiveGlobal.appendRules, mergedInto: profileWorking
        )
        effectiveGlobal.appendRules = droppingUnknownTargets(effectiveGlobal.appendRules, mergedInto: profileWorking).kept
        let merged = try ConfigTransforms.mergeOverride(
            raw: profileWorking,
            overrideJSON: overrideJSON(from: effectiveGlobal)
        )
        let profileScripted = try postMergeScript(
            profile.postMergeScriptID, merged, profile.label
        )
        let scripted = try configScript(profileScripted, profile.label)
        var providerMerge = ProviderDefinitionMergeReport()
        var profileLogLevel: String?
        var trimmedJSON: String?
        var trimmedNodesJSON: String?
        let trimmed = try applyClientTransforms(
            to: scripted,
            profile: profile,
            applyProviderDefinitions: applyProviderDefinitions,
            applyProxyChain: applyProxyChain,
            applyLegacyRelayMigration: applyLegacyRelayMigration,
            providerMerge: &providerMerge,
            inspectLogLevel: { _, level in
                profileLogLevel = level
            },
            unchangedJSON: { trimmedJSON = $0 },
            nodesJSON: { trimmedNodesJSON = $0 }
        )

        var effectiveRuntime = runtimeOverride
        var runtimePatch = OverridePatch(
            patchJSON: effectiveRuntime.patchJSON
        ).globalRuntimePatch
         
         
         
         
         
         
         
        if runtimeOverride.dnsOverridesProfiles != true,
           runtimePatch.hasDNSOverride,
           Self.hasEnabledOwnDNS(yaml: trimmed) {
            runtimePatch.clearDNS()
        }
         
         
         
         
         
        var ownLayerLogLevel: String?
         
         
         
        if var layer = Self.ownLayer(of: profile, over: trimmed) {
             
             
             
             
             
            if runtimePatch.mode != nil { layer.mode = nil }
            ownLayerLogLevel = layer.logLevel
            layer.logLevel = nil
            runtimePatch = runtimePatch.overlaying(layer)
        }
         
         
        if runtimePatch.mode == nil, let legacyMode = profile.outboundMode {
            runtimePatch.mode = legacyMode.rawValue
        }
         
         
         
         
         
         
         
        let directive = logLevelDirective ?? ClashLogSettings.levelDirective(
            from: UserDefaults(suiteName: ClashAppIdentifiers.appGroup) ?? .standard
        )
        switch directive {
        case .forced(let forcedLevel):
            runtimePatch.logLevel = forcedLevel.rawValue
        case .followProfile:
             
             
             
             
             
             
            if let ownLayerLogLevel {
                runtimePatch.logLevel = ownLayerLogLevel
                profileLogLevel = ownLayerLogLevel
            } else {
                runtimePatch.logLevel = nil
            }
        }
        effectiveRuntime.patchJSON = runtimePatch.patchJSON
        let disabledRuntimeRules = Set(
            profile.override.disabledGlobalRules ?? []
        )
        effectiveRuntime.appendRules.removeAll {
            disabledRuntimeRules.contains($0)
        }
        effectiveRuntime.appendRules = try resolvedFallbackTargets(
            effectiveRuntime.appendRules,
            mergedInto: trimmed
        )
        let runtimeOverrideJSON = try overrideJSON(from: effectiveRuntime)
        let runtimeApplied = try ConfigTransforms.mergeOverride(
            raw: trimmed,
            overrideJSON: runtimeOverrideJSON
        )
        return RuntimeBuildStages(
            afterClientTransforms: trimmed,
            beforeClientRuntimePolicy: runtimeApplied,
            udpFallback: UDPFallbackSettings.resolved(
                profile: profile.udpFallbackPolicy,
                global: UDPFallbackSettings.policy()
            ),
            excludeAPNsRoute: ClashTunnelRouteShaping.Switches.read(
                from: UDPFallbackSettings.appGroupDefaults
            ).excludeAPNsRoute,
            providerMerge: providerMerge,
            profileLogLevel: profileLogLevel,
             
             
            beforeClientRuntimePolicyJSON: trimmedJSON.flatMap { runtimeApplied == trimmed ? $0 : nil },
             
             
            nodesJSON: runtimeOverrideJSON.isEmpty || ConfigTransforms.overrideLeavesNodes(runtimeOverrideJSON)
                ? trimmedNodesJSON : nil
        )
    }

     
     
     
     
     
     
     
     
     
     
    static func applyClientTransforms(
        to scripted: String,
        profile: Profile,
        applyProviderDefinitions: Bool = true,
        applyProxyChain: Bool = true,
        applyLegacyRelayMigration: Bool = true
    ) throws -> String {
        var report = ProviderDefinitionMergeReport()
        return try applyClientTransforms(
            to: scripted,
            profile: profile,
            applyProviderDefinitions: applyProviderDefinitions,
            applyProxyChain: applyProxyChain,
            applyLegacyRelayMigration: applyLegacyRelayMigration,
            providerMerge: &report
        )
    }

    static func applyClientTransforms(
        to scripted: String,
        profile: Profile,
        applyProviderDefinitions: Bool = true,
        applyProxyChain: Bool = true,
        applyLegacyRelayMigration: Bool = true,
        providerMerge: inout ProviderDefinitionMergeReport,
        inspectLogLevel: ((Bool, String?) -> Void)? = nil,
         
         
         
        unchangedJSON: ((String) -> Void)? = nil,
         
         
         
        nodesJSON: ((String) -> Void)? = nil
    ) throws -> String {
         
         
         
         
         
         
         
         
         
         
         
         
         
         
         
        var document = try ConfigTransforms.ParsedDocument(yaml: scripted)
         
         
         
        let writtenNodes = document.root["proxies"].map { $0 as AnyObject }
        var touched = false
        if applyProviderDefinitions {
            let spec = profile.providerDefinitions ?? ProfileProviderDefinitionSpec()
            if !spec.isEmpty {
                providerMerge = try spec.apply(to: &document.root)
                touched = true
            }
        }
        let materialized = try CustomNodesGroupMaterializer.applyReportingChange(
            to: &document.root
        )
        touched = touched || materialized
        let overrides = profile.proxyNodeOverrides ?? ProxyNodeOverrideSpec()
        if !overrides.isEmpty {
            try overrides.apply(to: &document.root)
            touched = true
        }
        if applyProxyChain {
            let chain = profile.proxyChain ?? ProxyChainSpec()
            if !chain.assignments.isEmpty {
                try chain.apply(to: &document.root)
                touched = true
            }
        }
        if applyLegacyRelayMigration {
            touched = try LegacyRelayMigrationEngine.apply(
                profile.legacyRelayMigrations ?? [],
                to: &document.root
            ) || touched
        }
        touched = try (profile.memoryTrim ?? MemoryTrimSpec())
            .apply(to: &document.root) || touched
         
         
         
         
        touched = ConfigurationComposer.refreshingGeneratedGlobal(&document.root) || touched
        let docLogLevel = document.root["log-level"] as? String
        inspectLogLevel?(docLogLevel != nil && !(document.root["log-level"] is NSNull), docLogLevel)
         
         
         
         
        var trimmed = scripted
        if touched, let writtenNodes, let nodes = document.root["proxies"], (nodes as AnyObject) === writtenNodes,
           let json = document.json, let spliced = try document.serializedLeavingNodes(as: scripted) {
             
             
            trimmed = spliced
            nodesJSON?(json)
        } else if touched {
            let written = try document.serializedReading()
            trimmed = written.yaml
            nodesJSON?(written.json)
        } else if let json = document.json {
            nodesJSON?(json)
        }
         
        if profile.dnsBootstrapInsurance == true {
            trimmed = try ConfigTransforms.applyDNSBootstrapInsurance(trimmed)
        } else if !touched, let json = document.json {
            unchangedJSON?(json)
        }
         
         
         
         
         
        return trimmed
    }

     
     
     
     
     
    static func runtimePreview(
        raw: String,
        profile: Profile,
        runtimeOverride: OverrideSpec = FlClashRuntimeConfig.load()
    ) throws -> String {
        try buildProduction(
            raw: raw,
            profile: profile,
            runtimeOverride: runtimeOverride
        )
    }

     
     
    static let builtinPolicies: Set<String> = ConfigurationComposer.builtins.union(["MATCH"])

     
     
     
    static func knownPolicies(in yaml: String) -> Set<String>? {
         
         
         
         
        var error: NSError?
        let json = AppCore.policyNamesJSON(yaml, &error)
        guard error == nil,
              let names = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return nil }
        var known = builtinPolicies
        for key in ["proxies", "groups"] {
            for case let name as String in (names[key] as? [Any]) ?? [] { known.insert(name) }
        }
        return known
    }

     
     
    static func knownPolicies(root: [String: Any]) -> Set<String> {
        var names = builtinPolicies
        for key in ["proxies", "proxy-groups"] {
            for case let entry as [String: Any] in (root[key] as? [Any]) ?? [] {
                if let name = entry["name"] as? String { names.insert(name) }
            }
        }
        return names
    }

     
     
     
     
     
     
     
     
     
    static func droppingUnknownTargets(
        _ rules: [String],
        mergedInto yaml: String
    ) -> (kept: [String], dropped: [String]) {
        guard !rules.isEmpty, let known = knownPolicies(in: yaml) else { return (rules, []) }
        var kept: [String] = []
        var dropped: [String] = []
        for rule in rules {
            if let target = StructuredRule.parse(rule)?.target, !target.isEmpty, !known.contains(target) {
                dropped.append(rule)
            } else {
                kept.append(rule)
            }
        }
        return (kept, dropped)
    }

     
     
     
     
     
     
     
     
     
     
     
     
    static func personalRulesLeftOut(
        of yaml: String, root: [String: Any]? = nil, profile: Profile, globalOverride: OverrideSpec = GlobalConfig.load()
    ) -> [String] {
        guard let known = root.map(knownPolicies(root:)) ?? knownPolicies(in: yaml) else { return [] }
        var candidates: [String] = []
        switch profile.overwriteMode ?? .standard {
        case .standard, .script:
            let muted = Set(profile.override.disabledAppendRules ?? [])
            candidates += profile.override.appendRules.filter { !muted.contains($0) }
        case .custom:
            break
        }
        if (profile.overwriteMode ?? .standard) == .standard {
            let disabled = Set(profile.override.disabledGlobalRules ?? [])
            candidates += (profile.migratedGlobalOverride ?? globalOverride).appendRules.filter { !disabled.contains($0) }
        }
        return candidates.filter { rule in
            guard let target = StructuredRule.parse(rule)?.target, !target.isEmpty else { return false }
            return !known.contains(target)
        }
    }

     
     
     
     
     
     
     
     
     
    static func resolvedFallbackTargets(
        _ rules: [String],
        mergedInto yaml: String
    ) throws -> [String] {
        let needsResolution = rules.contains {
            StructuredRule.parse($0)?.target == "MATCH"
        }
        guard needsResolution else { return rules }
         
        let root = try ConfigTransforms.foundationRoot(ofYAML: yaml, omitting: ["proxies"])
         
         
        let sourceRules = (root?["rules"] as? [Any]) ?? []
        let fallback = sourceRules.lazy
            .compactMap { entry -> String? in
                guard let line = entry as? String,
                      let parsed = StructuredRule.parse(line),
                      parsed.action == .match, !parsed.target.isEmpty,
                      parsed.target != "MATCH" else { return nil }
                return parsed.target
            }
            .first ?? "DIRECT"
        return rules.map { rule in
            guard var parsed = StructuredRule.parse(rule),
                  parsed.target == "MATCH" else { return rule }
            parsed.target = fallback
            return parsed.rawValue
        }
    }

     
    static func hasEnabledOwnDNS(yaml: String) -> Bool {
         
        guard let root = (try? ConfigTransforms.foundationRoot(ofYAML: yaml, omitting: ["proxies"])) ?? nil,
              let dns = root["dns"] as? [String: Any] else {
            return false
        }
        return (dns["enable"] as? Bool) == true
    }

     
     
     
     
     
     
     
     
    static func ownLayer(of profile: Profile, over document: String) -> OverridePatch? {
        guard let legacy = profile.legacyRuntimePatchJSON, !legacy.isEmpty else { return nil }
        var layer = OverridePatch(patchJSON: legacy)
        if profile.legacyRuntimeDNSGated == true, layer.hasDNSOverride, hasEnabledOwnDNS(yaml: document) {
            layer.clearDNS()
        }
        return layer
    }

     
     
     
     
     
    static func applyingOwnLayer(of profile: Profile, to document: String) throws -> String {
        guard let layer = ownLayer(of: profile, over: document), !layer.topLevelKeys.isEmpty else { return document }
        return try ConfigTransforms.mergeOverride(
            raw: document,
            overrideJSON: overrideJSON(from: OverrideSpec(patchJSON: layer.patchJSON))
        )
    }

    private static func overrideJSON(from spec: OverrideSpec) throws -> String {
        if spec.patchJSON.isEmpty && spec.appendRules.isEmpty { return "" }
        var payload: [(key: String, value: OrderedJSON)] = []
        if !spec.patchJSON.isEmpty {
             
             
             
             
             
             
            payload.append((key: "patch", value: try OrderedJSON.parse(spec.patchJSON)))
        }
        if !spec.appendRules.isEmpty {
            payload.append((key: "appendRules", value: .array(spec.appendRules.map(OrderedJSON.string))))
            payload.append((key: "prependRules", value: .scalar(spec.prependRules ? "true" : "false")))
        }
        return OrderedJSON.object(payload).serialized()
    }

}

 
 
 
 
 
 
 
 
 
 
 
 
 
enum PublishedSourceLedger {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var digests: [String: String] = [:]
    nonisolated(unsafe) private static var order: [String: [String]] = [:]
     
    nonisolated(unsafe) private static var configurations: [String] = []
    static let keptPerConfiguration = 8
    static let keptConfigurations = 32

     
    static func retain(only profileIDs: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        for gone in configurations where !profileIDs.contains(gone) { forgetLocked(gone) }
    }

     
    static var count: Int { lock.lock(); defer { lock.unlock() }; return digests.count }

    private static func forgetLocked(_ profileID: String) {
        for slot in order[profileID] ?? [] { digests.removeValue(forKey: slot) }
        order.removeValue(forKey: profileID)
        configurations.removeAll { $0 == profileID }
    }

    private static func key(_ pointer: ActiveConfigurationPointer) -> String {
        pointer.profileID + "\n" + pointer.revision
    }

    static func resetForTesting() {
        lock.lock(); digests = [:]; order = [:]; configurations = []; lock.unlock()
    }

    static func digest(of source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

     
    static func record(_ pointer: ActiveConfigurationPointer, source: String?) {
        let sourceDigest = source.map { Self.digest(of: $0) }, slot = Self.key(pointer)
        lock.lock(); defer { lock.unlock() }
        var slots = order[pointer.profileID] ?? []
        slots.removeAll { $0 == slot }
        digests[slot] = sourceDigest
        if sourceDigest != nil { slots.append(slot) }
        while slots.count > keptPerConfiguration { digests.removeValue(forKey: slots.removeFirst()) }
        order[pointer.profileID] = slots
        configurations.removeAll { $0 == pointer.profileID }
        configurations.append(pointer.profileID)
        while configurations.count > keptConfigurations { forgetLocked(configurations[0]) }
    }

     
     
    static func published(_ pointer: ActiveConfigurationPointer, from source: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return digests[key(pointer)] == digest(of: source)
    }
}

 
 
 
 
 
final class ProfileActivationCoordinator {



     
     
     
     
    private(set) var firstLoadPendingOfLastPublication: [String] = []
     
     
     
     
    private(set) var lastPublicationPreflight: (pointer: ActiveConfigurationPointer, outcome: PreflightOutcome)?
     
     
     
     
    private(set) var lastPublicationNotices: (pointer: ActiveConfigurationPointer, notices: [String])?
     
     
     
     
     
    static let maxProviderBytes = Int.max
    static let maxGeodataBytes = Int.max
     
     
    nonisolated(unsafe) static var finalizeOrderReference = true

    private let store: ConfigResourceStore
    private let profileStore: ProfileStore
    private let credentials: CredentialStore
    private let coreHomeDir: URL
     
     
     
    private let compileRuleSets: Bool
    private let writesNodeLibrary: Bool
     
     
    private let deferRuleSetCompilation: Bool
    private let stagingPublisher: (String, Int, Bool) -> Void
    private let scheduleDeferredCompilation: (@escaping () -> Void) -> Void

     
     
     
    static let deferredCompilationQueue = DispatchQueue(
        label: "network.clash.provider-staging.compile", qos: .utility
    )

     
     
     
    static var scheduledCompiles: UInt64 { compileCount.value }
    private static let compileCount = CompileQueueCounter()

     
     
     
     
     
     
     
    @discardableResult
    static func drainDeferredCompilation(timeout: TimeInterval = 60) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = CompileQueueOnce()
            deferredCompilationQueue.async { if once.claim() { continuation.resume(returning: true) } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }

     
     
     
     
     
     
     
     
     
    static func onCompilationQueue<T>(deadline: TimeInterval, finished: @escaping () -> Void = {},
                                      _ body: @escaping () throws -> T) async throws -> T? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T?, Error>) in
            let run = CompileQueueRun()
            deferredCompilationQueue.async {
                guard run.start() else { finished(); return }
                let result = Result { try body() }
                finished()
                if run.answer() { continuation.resume(with: result.map { Optional($0) }) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline) {
                run.expire()
                if run.answer() { continuation.resume(returning: nil) }
            }
        }
    }

     
     
     
     
     
     
     
    private func publishStaging(finalYAML: String, providerCount: Int) {
        guard compileRuleSets, deferRuleSetCompilation else {
            stagingPublisher(finalYAML, providerCount, compileRuleSets)
            return
        }
        stagingPublisher(finalYAML, providerCount, false)
        scheduleCompile(finalYAML: finalYAML, providerCount: providerCount)
    }

     
    private func scheduleCompile(finalYAML: String, providerCount: Int) {
        Self.compileCount.increment()
        let staged = try? store.activeIdentity()
        let store = self.store
        let publish = self.stagingPublisher
        scheduleDeferredCompilation {
            guard (try? store.activeIdentity()) == staged else { return }
            publish(finalYAML, providerCount, true)
            AppCore.returnFreeMemory()
        }
    }

     
     
     
     
     
     
    private func compileUnchanged(finalYAML: String, providerCount: Int) {
        guard compileRuleSets else { return }
        if deferRuleSetCompilation {
            scheduleCompile(finalYAML: finalYAML, providerCount: providerCount)
        } else {
            stagingPublisher(finalYAML, providerCount, true)
        }
    }
    private let activationFetchBudget: ProviderFetchBudget
     
     
     
    private var activationReuseSource = "unset"
    private let globalOverride: () -> OverrideSpec
    private let runtimeOverride: () -> OverrideSpec
    private let profileScript: (String?, String, String) throws -> String
    private let configScript: (String, String) throws -> String
    private let postMergeScript: (String?, String, String) throws -> String
    private let activator: (URL) throws -> Void
    private let subscriptions: SubscriptionManager
    private let materializer: ProviderMaterializer
    private let geodata: GeodataManager
    private let preflight: (String) -> PreflightOutcome
     
     
     
     
    private let preflightIsCallers: Bool
    private let intentContainer: URL
    private let intentSettings: IPStackSettings?
     
     
     
     
     
    private let prepareCore: () throws -> Void
    private let now: () -> Date
     
     
     
     
    private let log: (String) -> Void

    init(store: ConfigResourceStore, profileStore: ProfileStore,
         credentials: CredentialStore, downloader: HTTPFetching,
         coreHomeDir: URL,
          
          
          
          
          
          
          
         compileRuleSets: Bool = false,
          
          
          
          
         writesNodeLibrary: Bool = true,
          
          
          
          
          
          
          
          
          
          
         deferRuleSetCompilation: Bool = false,
          
          
          
          
         activationFetchBudget: ProviderFetchBudget = .activation,
         globalOverride: @escaping () -> OverrideSpec = { GlobalConfig.load() },
         runtimeOverride: @escaping () -> OverrideSpec = {
             FlClashRuntimeConfig.load()
         },
          
          
          
          
          
          
          
          
         logDefaults: UserDefaults = UserDefaults(suiteName: ClashAppIdentifiers.appGroup) ?? .standard,
         profileScript: @escaping (String?, String, String) throws -> String = {
             try ScriptLibrary.apply(id: $0, to: $1, profileName: $2)
         },
         configScript: @escaping (String, String) throws -> String = {
             try ScriptSettings.apply(toConfigYAML: $0, profileName: $1)
         },
         postMergeScript: @escaping (String?, String, String) throws -> String = {
             try ScriptLibrary.apply(id: $0, to: $1, profileName: $2)
         },
         activator: @escaping (URL) throws -> Void,
         preflight: ((String) -> PreflightOutcome)? = nil,
          
          
          
          
         intentContainer: URL? = nil,
         intentSettings: IPStackSettings? = nil,
         prepareCore: @escaping () throws -> Void = {},
          
         stagingPublisher: @escaping (String, Int, Bool) -> Void = {
             ProviderStagingPublisher.publish(
                 finalYAML: $0, providerCount: $1, compileRuleSets: $2
             )
         },
          
          
         scheduleDeferredCompilation: @escaping (@escaping () -> Void) -> Void = {
             ProfileActivationCoordinator.deferredCompilationQueue.async(execute: $0)
         },
         now: @escaping () -> Date = Date.init,
         log: @escaping (String) -> Void = {
             ClashLogStore.shared.append($0, stream: .app)
         }) {
        self.store = store
        self.profileStore = profileStore
        self.credentials = credentials
        self.coreHomeDir = coreHomeDir
        self.compileRuleSets = compileRuleSets
        self.writesNodeLibrary = writesNodeLibrary
        self.deferRuleSetCompilation = deferRuleSetCompilation
        self.stagingPublisher = stagingPublisher
        self.scheduleDeferredCompilation = scheduleDeferredCompilation
        self.activationFetchBudget = activationFetchBudget
        self.globalOverride = globalOverride
        self.runtimeOverride = runtimeOverride
        self.logDefaults = logDefaults
        self.profileScript = profileScript
        self.configScript = configScript
        self.postMergeScript = postMergeScript
        self.activator = activator
        self.subscriptions = SubscriptionManager(downloader: downloader, credentials: credentials)
        self.materializer = ProviderMaterializer(downloader: downloader, credentials: credentials)
        self.geodata = GeodataManager(downloader: downloader)
        self.preflightIsCallers = preflight != nil
        let intentContainer = intentContainer ?? coreHomeDir.deletingLastPathComponent()
        self.intentContainer = intentContainer
        self.intentSettings = intentSettings
        self.preflight = preflight ?? { finalYAML in
            PreflightService.intent(finalYAML: finalYAML, container: intentContainer, settings: intentSettings)
        }
        self.prepareCore = prepareCore
        self.now = now
        self.log = log
    }

     
     
     
     
     
     
     
     
     
     
     
     
     
    private struct FailureRecord {
         
         
         
         
        let stage: String
        let error: String
        let cancelled: Bool

        init(_ error: Error) {
            cancelled = error is CancellationError
            switch error {
            case let pipeline as PipelineError:
                switch pipeline {
                case .sourceUnavailable: (stage, self.error) = ("source", "sourceUnavailable")
                case .notModifiedWithoutActive:
                    (stage, self.error) = ("source", "notModifiedWithoutActive")
                case .planRejected: (stage, self.error) = ("plan", "planRejected")
                case .providerNotFound: (stage, self.error) = ("plan", "providerNotFound")
                case .externalResources: (stage, self.error) = ("resources", "externalResources")
                case .preflightFailed: (stage, self.error) = ("preflight", "preflightFailed")
                case .activationReadback: (stage, self.error) = ("publish", "activationReadback")
                case .sourceSuperseded: (stage, self.error) = ("source", "sourceSuperseded")
                }
            case is CancellationError:
                (stage, self.error) = ("cancelled", "CancellationError")
            default:
                 
                 
                (stage, self.error) = ("unknown", String(describing: type(of: error)))
            }
        }
    }

     
     
     
     
     
    private func record(_ error: Error, profile: Profile, since start: Date) {
        let record = FailureRecord(error)
        let millis = Int((now().timeIntervalSince(start) * 1000).rounded())
        var line = "profile activation \(record.cancelled ? "cancelled" : "failed")  "
            + "id=\(profile.id) stage=\(record.stage) "
            + "error=\(record.error) after=\(millis)ms"
         
         
        if !record.cancelled {
            let reason = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            if !reason.isEmpty {
                 
                 
                 
                 
                let bounded = reason.count > 400
                    ? String(reason.prefix(400)) + "…(truncated)"
                    : reason
                line += "  reason=\(bounded)"
            }
        }
        log(line)
    }

    @discardableResult
     
     
     
     
     
    func activate(profile given: Profile, sourceYAML: String?,
                  onlyIfActive expected: ActiveConfigurationPointer? = nil) async throws -> ActiveConfigurationPointer {
         
         
         
        let startedAt = now()
         
         
         
         
         
         
         
        let stored = profileStore.load().first(where: { $0.id == given.id })
        let profile = stored ?? given
         
         
        guard stored != nil || expected == nil else {
            let gone = PipelineError.sourceUnavailable("the profile is no longer available")
            record(gone, profile: profile, since: startedAt)
            throw gone
        }
        do {
            try prepareCore()
            let pointer = try await activateResolved(
                given: given, sourceYAML: sourceYAML, forceFreshFetch: false, onlyIfActive: expected,
                firstActivation: stored == nil
            )
             
             
            log("profile activated  id=\(profile.id) rev=\(pointer.revision)")
            return pointer
        } catch let original {
             
             
             
             
             
             
            guard !(original is CancellationError), sourceYAML != nil,
                  !Self.lostToASwitch(original), !Self.superseded(original),
                   
                   
                  stored == nil || profileStore.load().contains(where: { $0.id == profile.id }),
                  case .url = profile.source else {
                record(original, profile: profile, since: startedAt)
                throw original
            }
            do {
                 
                 
                let pointer = try await activateResolved(
                    given: given, sourceYAML: nil, forceFreshFetch: true, onlyIfActive: expected,
                    firstActivation: stored == nil, healing: true
                )
                 
                 
                 
                 
                 
                log(
                    "profile activated  id=\(profile.id) rev=\(pointer.revision) "
                        + "healed=refetched"
                )
                return pointer
            } catch is CancellationError {
                record(CancellationError(), profile: profile, since: startedAt)
                throw CancellationError()
            } catch let yielded where Self.lostToASwitch(yielded) || Self.superseded(yielded) {
                 
                 
                record(yielded, profile: profile, since: startedAt)
                throw yielded
            } catch {
                 
                record(original, profile: profile, since: startedAt)
                throw original
            }
        }
    }

     
     
    static func lostToASwitch(_ error: Error) -> Bool {
        if case ConfigResourceStoreError.activeConfigurationChanged? = error as? ConfigResourceStoreError { return true }
        return false
    }

     
    static func superseded(_ error: Error) -> Bool {
        if case PipelineError.sourceSuperseded? = error as? PipelineError { return true }
        return false
    }

    private func activateResolved(
        given: Profile,
        sourceYAML: String?,
        forceFreshFetch: Bool,
        onlyIfActive expected: ActiveConfigurationPointer? = nil,
        firstActivation: Bool,
        healing: Bool = false
    ) async throws -> ActiveConfigurationPointer {
         
         
         
         
         
         
         
         
        let workingDirectory = coreHomeDir
        let sidecarPath = sidecarURL(profileID: given.id).path
        let (storedAtStart, identityAtStart) = ProfileStore.withWriteLock {
            () -> (Profile?, ProfileSourceIdentity?) in
            let record = profileStore.load().first(where: { $0.id == given.id })
            let judgesSource = sourceYAML == nil || !FileManager.default.fileExists(atPath: sidecarPath)
            return (record, judgesSource ? record.map { ProfileSourceIdentity($0, workingDirectory: workingDirectory) } : nil)
        }
        guard firstActivation || storedAtStart != nil else {
            throw PipelineError.sourceUnavailable("the profile is no longer available")
        }
        var profile = storedAtStart ?? given
         
        if healing { profile.usesLocalSourceOverride = false }
        func sourceIsAsItWas(_ current: Profile?) -> Bool {
            guard let current, let identityAtStart else { return false }
            return ProfileSourceIdentity(current, workingDirectory: workingDirectory) == identityAtStart
        }
        var fetchedBody = false
        var fetchedInfo: SubscriptionInfo?
        var fetchedETag: String?
        var fetchedLastModified: String?
        var fetchedName: String?
        let raw: String
        if let sourceYAML {
            raw = sourceYAML
        } else {
            guard case .url = profile.source else {
                throw PipelineError.sourceUnavailable(
                    "profile '\(profile.label)' has no stored YAML and no profile URL")
            }
            if let fetched = try await subscriptions.fetch(
                profile: profile,
                useConditionalValidators: !forceFreshFetch
            ) {
                raw = fetched.yaml
                fetchedBody = true
                fetchedInfo = fetched.subscriptionInfo
                fetchedETag = fetched.etag
                fetchedLastModified = fetched.lastModified
                fetchedName = fetched.suggestedName
            } else {
                 
                 
                 
                 
                 
                 
                try? profileStore.updateIfPresent(id: profile.id, when: sourceIsAsItWas) {
                    $0.lastUpdatedAt = Date()
                }
                 
                if let current = try store.activePointer(), current.profileID == profile.id {
                    return current
                }

                 
                 
                 
                 
                 
                 
                 
                if !forceFreshFetch, let cached = try? String(
                    contentsOf: sidecarURL(profileID: profile.id),
                    encoding: .utf8
                ), !cached.isEmpty {
                    raw = cached
                } else if let fetched = try await subscriptions.fetch(
                    profile: profile,
                    useConditionalValidators: false
                ) {
                    raw = fetched.yaml
                    fetchedBody = true
                    fetchedInfo = fetched.subscriptionInfo
                    fetchedETag = fetched.etag
                    fetchedLastModified = fetched.lastModified
                    fetchedName = fetched.suggestedName
                } else {
                    throw PipelineError.notModifiedWithoutActive
                }
            }
        }

         
         
         
         
        var laps = PerfLedger.Laps()
        try ConfigTransforms.validateSource(raw)
        laps.mark("activation.validate")
        let (prepared, preparedRoot) = try prepareConfigReading(raw: raw, profile: profile)
        laps.mark("activation.prepare")
         
         
         
         
         
         
        let (reusableProviders, reuseSource) = reusableProvidersDirectory(for: profile)
        activationReuseSource = reuseSource
        let profileStore = self.profileStore
        let publication = try await buildPublishActivate(
            profile: profile,
            merged: prepared,
            mergedRoot: preparedRoot,
            reuseDir: reusableProviders,
            reuseDirIsOwnRevision: reuseSource.hasPrefix("own"),
             
            replacing: expected,
             
             
             
             
            fetchBudget: activationFetchBudget,
             
             
             
            beforePublish: storedAtStart == nil ? nil : { [profileID = profile.id] in
                let current = profileStore.load().first(where: { $0.id == profileID })
                guard current != nil else {
                    throw PipelineError.sourceUnavailable("the profile is no longer available")
                }
                if sourceYAML == nil, !sourceIsAsItWas(current) {
                    throw PipelineError.sourceSuperseded
                }


            },
            source: raw
        )
        laps.mark("activation.publish")
        let pointer = publication.pointer
        ProviderFirstLoadRetry.noteActivation(
            pending: firstLoadPendingOfLastPublication, profileID: profile.id
        )

         
         
        for rule in ProfileRuntimeConfigBuilder.personalRulesLeftOut(of: prepared, root: preparedRoot, profile: profile,
                                                                     globalOverride: globalOverride()) {
             
            ClashLogStore.shared.append(
                "personal rule left out of the runtime: \(rule) names a policy this configuration does not define",
                stream: .app, level: .warning)
        }
         
         
         
         
         
        let merge = lastProviderMerge
        let unfrozen = merge.unfrozen
         
         
         
        func applyActivationOwned(_ current: inout Profile) {
            current.activeRevision = pointer.revision
            if !merge.notices.isEmpty {
                current.providerDefinitionNotices =
                    (current.providerDefinitionNotices ?? []) + merge.notices
            }
            if !unfrozen.isEmpty, let spec = current.providerDefinitions {
                let kept = spec.droppingUnfrozen(unfrozen, asInspectedIn: profile.providerDefinitions)
                current.providerDefinitions = kept.isEmpty ? nil : kept
            }
        }
         
        func applyFetchOwned(_ current: inout Profile, otherLabels: [String]) {
            guard sourceYAML == nil else { return }
            current.lastUpdatedAt = Date()
            if let fetchedInfo { current.subscriptionInfo = fetchedInfo }
             
             
             
             
            let asItWas = current
            ProfileLabelPolicy.adoptPanelName(
                fetchedName,
                into: &current,
                for: asItWas,
                otherLabels: otherLabels
            )
            current.subscriptionETag = fetchedETag ?? current.subscriptionETag
            current.subscriptionLastModified = fetchedLastModified ?? current.subscriptionLastModified
             
             
             
            if fetchedBody { current.usesLocalSourceOverride = false }
        }
         
         
         
        let stagedSidecar = (sourceYAML == nil || !FileManager.default.fileExists(atPath: sidecarURL(profileID: profile.id).path))
            ? try ProfileSourceStore.stage(document: raw, workingDirectory: coreHomeDir, profileID: profile.id)
            : nil
        var placedSidecar: ProfileSourceStore.Replaced?
        defer {
            if let placedSidecar { ProfileSourceStore.retire(placedSidecar) }
            else if let stagedSidecar { ProfileSourceStore.discard(stagedSidecar) }
        }
        func placeSidecar() throws {
            if let stagedSidecar {
                placedSidecar = try ProfileSourceStore.swapIn(stagedSidecar)
            } else {
                try writeSourceSidecar(raw, profileID: profile.id)
            }
        }
         
         
        let written: Bool = try ProfileStore.withWriteLock {
            let profiles = profileStore.load()
            let otherLabels = profiles.filter { $0.id != profile.id }.map(\.label)
            let sidecarExists = FileManager.default.fileExists(atPath: sidecarURL(profileID: profile.id).path)
            guard let current = profiles.first(where: { $0.id == profile.id }) else {
                 
                 
                 
                guard storedAtStart == nil else { return false }
                var fresh = profile
                applyActivationOwned(&fresh)
                applyFetchOwned(&fresh, otherLabels: otherLabels)
                try profileStore.upsert(fresh)
                if sourceYAML == nil || !sidecarExists {
                    try placeSidecar()
                }
                return true
            }
             
             
             
             
            let sourceUnchanged = sourceIsAsItWas(current)
            try profileStore.updateIfPresent(id: profile.id) { record in
                applyActivationOwned(&record)
                if sourceUnchanged { applyFetchOwned(&record, otherLabels: otherLabels) }
            }
             
             
             
             
             
             
             
             
             
            if sourceUnchanged, sourceYAML == nil || !sidecarExists {
                try placeSidecar()
            }
            return true
        }
        laps.mark("activation.record")
        guard written else {
             
             
             
             
            if let previous = publication.previous {
                _ = try? store.activateIfCurrentMatches(pointer, replacement: previous)
            } else {
                _ = try? store.deactivateIfCurrentMatches(pointer)
            }
            throw PipelineError.sourceUnavailable("the profile is no longer available")
        }
        return pointer
    }

     
     
     
     
     
     
    @discardableResult
    func regenerateRuntime(
        profile given: Profile,
        storedSourceYAML: String,
        sourceIsStoredSidecar: Bool = true,
        replacing previousRuntime: ActiveConfigurationPointer
    ) async throws -> ActiveConfigurationPointer {
        let profile = onDisk(given)
        try prepareCore()
        try ConfigTransforms.validateSource(storedSourceYAML)
        let prepared = try prepareConfig(raw: storedSourceYAML, profile: profile)
         
         
         
         
        let (reusableProviders, reuseSource) = reusableProvidersDirectory(for: profile)
        activationReuseSource = reuseSource
        let pointer = try await buildPublishActivate(
            profile: profile,
            merged: prepared,
            reuseDir: reusableProviders,
            reuseDirIsOwnRevision: reuseSource.hasPrefix("own"),
            replacing: previousRuntime,
            fetchBudget: activationFetchBudget,
            source: storedSourceYAML
        ).pointer
        ProviderFirstLoadRetry.noteActivation(
            pending: firstLoadPendingOfLastPublication, profileID: profile.id
        )

         
         
         
        ProfileStore.withWriteLock {
            recordRevision(pointer, of: profile)
            if !sourceIsStoredSidecar,
               !FileManager.default.fileExists(atPath: sidecarURL(profileID: profile.id).path) {
                 
                 
                 
                 
                try? writeSourceSidecar(storedSourceYAML, profileID: profile.id)
            }
        }
        return pointer
    }

     
     
     
     
     
    @discardableResult
    func refreshProvider(
        named name: String, profile given: Profile,
        fetchBudget: ProviderFetchBudget = .patient
    ) async throws -> ProviderRefreshResult {
        try prepareCore()
        let (inUse, profile) = try inUseAndOnDisk(given)
        guard let raw = try? String(contentsOf: sidecarURL(profileID: profile.id),
                                    encoding: .utf8) else {
            throw PipelineError.sourceUnavailable(
                "profile '\(profile.label)' has no cached source; update the profile once first")
        }
         
        try ConfigTransforms.validateSource(raw)
        let merged = try prepareConfig(raw: raw, profile: profile)

         
         
        let reuseDir = store.providersDirectory(profileID: inUse.profileID, revision: inUse.revision)

        let publication = try await buildPublishActivate(
            profile: profile, merged: merged,
            reuseDir: reuseDir, forceRefresh: [name],
            replacing: inUse,
            fetchBudget: fetchBudget,
            source: raw)
        recordRevision(publication.pointer, of: profile)
        announceProviderContent(of: profile)
        return ProviderRefreshResult(
            pointer: publication.pointer,
            runtimeUpdate: publication.runtimeUpdates[name]
        )
    }

     
     
     
     
     
     
     
     
     
     
     
     
    func providerRetryCatalog(profile given: Profile) throws -> ProviderCatalog {
        let profile = onDisk(given)
        let raw = try String(contentsOf: sidecarURL(profileID: profile.id), encoding: .utf8)
        let merged = try prepareConfig(raw: raw, profile: profile)
        let plan = try ConfigTransforms.planResources(mergedYAML: merged)
        guard plan.errors.isEmpty else { throw PipelineError.planRejected(plan.errors) }
        return ProviderCatalog.from(plan: plan,
            routeSetProviders: try ConfigTransforms.routeSetProviderNames(mergedYAML: merged))
    }

     
     
    func coreOwnedRouteRecoveryNames(profile given: Profile, current: ActiveConfigurationPointer) throws -> Set<String> {
        let profile = onDisk(given)
        guard current.profileID == profile.id,
              let directory = store.providersDirectory(profileID: current.profileID, revision: current.revision) else { return [] }
        let catalog = ProviderCatalog.load(providersDir: directory)
        if let catalog, let routes = catalog.routeSetProviders, let coreFetched = catalog.coreFetchedProviders,
           routes.isDisjoint(with: coreFetched) { return [] }
        let adopted = catalog?.coreRouteSeeds ?? []
        let raw = try String(contentsOf: sidecarURL(profileID: profile.id), encoding: .utf8)
        let merged = try prepareConfig(raw: raw, profile: profile)
        let plan = try ConfigTransforms.planResources(mergedYAML: merged)
        let names = try ConfigTransforms.routeSetProviderNames(mergedYAML: merged)
        let cache = try CoreOwnedRouteCache(mergedYAML: merged, plan: plan, routeSetProviders: names,
            profileID: profile.id, workingDirectory: coreHomeDir)
        guard !cache.paths.isEmpty else { return [] }
        let yaml = try store.loadConfiguration(profileID: current.profileID, revision: current.revision).text ?? ""
        let json = try ConfigTransforms.yamlToJSON(yaml)
        let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        let definitions = root["rule-providers"] as? [String: [String: Any]] ?? [:]
        return Set(plan.providers.compactMap { provider -> String? in
            guard let path = cache.paths[provider.name], provider.kind == "rule" else { return nil }
            let definition = definitions[provider.name]
             
             
             
             
            if !adopted.contains(provider.name), definition?["type"] as? String == "file",
               definition?["path"] as? String == directory.appendingPathComponent(provider.path).path { return nil }
             
             
             
             
            let written = (definition?["x-clash-refresh"] as? [String: Any])?["legacy-path"] as? String
                ?? definition?["path"] as? String
            if written != path { return provider.name }
            guard let bytes = cache.snapshots[provider.name] else { return nil }
            let old = try? Data(contentsOf: directory.appendingPathComponent(provider.path))
            return old == bytes ? nil : provider.name
        })
    }

    func refreshPendingProviders(
        profile given: Profile, names: [String], fetchBudget: ProviderFetchBudget,
        expectedActive: ActiveConfigurationPointer? = nil
    ) async throws -> (pointer: ActiveConfigurationPointer,
                       runtimeUpdates: [String: ProviderRuntimeUpdate],
                       stillPending: [String], publishedRouteNames: Set<String>) {
        try prepareCore()
        let (current, profile) = try inUseAndOnDisk(given, expected: expectedActive)
        guard current.profileID == profile.id else {
            throw ConfigResourceStoreError.activeConfigurationChanged
        }
        let expected = expectedActive ?? current
        guard let raw = try? String(contentsOf: sidecarURL(profileID: profile.id),
                                    encoding: .utf8) else {
            throw PipelineError.sourceUnavailable(
                "profile '\(profile.label)' has no cached source; update the profile once first")
        }
        try ConfigTransforms.validateSource(raw)
        let merged = try prepareConfig(raw: raw, profile: profile)
        let reuseDir = try store.providersDirectory(profileID: expected.profileID, revision: expected.revision)
        let publication = try await buildPublishActivate(
            profile: profile, merged: merged,
            reuseDir: reuseDir,
            replacing: expected,
            fetchBudget: fetchBudget,
            fetchOnly: Set(names),
            capturePayloads: Set(names),
            source: raw,
            overTheCatalogItRead: true)
         
         
        recordRevision(publication.pointer, of: profile)
        announceProviderContent(of: profile)
        return (publication.pointer,
                publication.runtimeUpdates.filter { names.contains($0.key) },
                publication.firstLoadPending.filter { names.contains($0) },
                publication.publishedRouteNames.intersection(names))
    }

     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
    func refreshProviders(
        named names: [String],
        profile given: Profile,
        fetchBudget: ProviderFetchBudget = .patient,
        expectedActive: ActiveConfigurationPointer? = nil,
        downloadRound: ProviderDownloadRound? = nil
    ) async throws -> (pointer: ActiveConfigurationPointer,
                       runtimeUpdates: [String: ProviderRuntimeUpdate]) {
        try prepareCore()
        let (inUse, profile) = try inUseAndOnDisk(given, expected: expectedActive)
        guard let raw = try? String(contentsOf: sidecarURL(profileID: profile.id),
                                    encoding: .utf8) else {
            throw PipelineError.sourceUnavailable(
                "profile '\(profile.label)' has no cached source; update the profile once first")
        }
        try ConfigTransforms.validateSource(raw)
        let merged = try prepareConfig(raw: raw, profile: profile)
        let reuseDir = store.providersDirectory(profileID: inUse.profileID, revision: inUse.revision)
        let publication = try await buildPublishActivate(
            profile: profile, merged: merged,
            reuseDir: reuseDir, forceRefresh: Set(names),
            replacing: inUse,
            fetchBudget: fetchBudget,
            downloadRound: downloadRound,
            source: raw,
            overTheCatalogItRead: true)
        recordRevision(publication.pointer, of: profile)
        announceProviderContent(of: profile)
        return (publication.pointer,
                publication.runtimeUpdates.filter { names.contains($0.key) })
    }

    @discardableResult
    func sideLoadProvider(
        named name: String,
        data: Data,
        profile given: Profile
    ) async throws -> ProviderRefreshResult {
        try prepareCore()
        let (inUse, profile) = try inUseAndOnDisk(given)
        guard let raw = try? String(
            contentsOf: sidecarURL(profileID: profile.id),
            encoding: .utf8
        ) else {
            throw PipelineError.sourceUnavailable(
                "profile '\(profile.label)' has no cached source; update the profile once first"
            )
        }
         
        try ConfigTransforms.validateSource(raw)
        let merged = try prepareConfig(raw: raw, profile: profile)
        let reuseDir = store.providersDirectory(profileID: inUse.profileID, revision: inUse.revision)
        let publication = try await buildPublishActivate(
            profile: profile,
            merged: merged,
            reuseDir: reuseDir,
            providerOverrides: [name: data],
            replacing: inUse,
            source: raw
        )
        recordRevision(publication.pointer, of: profile)
        announceProviderContent(of: profile)
        return ProviderRefreshResult(
            pointer: publication.pointer,
            runtimeUpdate: publication.runtimeUpdates[name]
        )
    }

     
     
     
     
     
     
     
     
     
     
    private var lastProviderMerge = ProviderDefinitionMergeReport()
     
     
    private var lastProfileLogLevel: String?
     
    private let logDefaults: UserDefaults

    private func prepareConfig(raw: String, profile: Profile) throws -> String {
        try prepareConfigReading(raw: raw, profile: profile).yaml
    }

     
     
     
     
     
     
     
    private func presentationInputs(source: String?, profile: Profile) -> String? {
        guard let source else { return nil }
        var settings = PublishedPresentation.Settings.live()
        settings.global = globalOverride()
        settings.runtime = runtimeOverride()
        return PublishedPresentation.inputs(source: source, profile: profile, settings: settings)
    }

    private func prepareConfigReading(raw: String, profile: Profile) throws -> (yaml: String, root: [String: Any]?) {
        var laps = PerfLedger.Laps()
        let stages = try ProfileRuntimeConfigBuilder.buildStages(
            raw: raw,
            profile: profile,
            globalOverride: globalOverride(),
            runtimeOverride: runtimeOverride(),
            profileScript: profileScript,
            configScript: configScript,
             
             
             
             
             
             
             
             
             
            postMergeScript: postMergeScript,
            logLevelDirective: ClashLogSettings.levelDirective(from: logDefaults)
        )
        lastProviderMerge = stages.providerMerge
        lastProfileLogLevel = stages.profileLogLevel
        laps.mark("prepare.chain")
         
         
        let (runtime, root) = try ProfileRuntimeConfigBuilder.finishedReading(stages)
        laps.mark("prepare.policy")
        laps.mark("prepare.read")
        noteExternalResources(in: root, profile: profile)
        laps.mark("prepare.noteResources")
        return (runtime, root)
    }

     
     
     
     
     
     
     
    static func providerAgeSecretKeys(in mergedYAML: String) throws -> [String: String] {
         
         
        try ConfigTransforms.providerAgeSecretKeys(mergedYAML: mergedYAML)
    }

     
     
     
     
     
     
     
     
     
     
     
    private func noteExternalResources(in runtimeRoot: [String: Any]?, profile: Profile) {
        guard let runtimeRoot else { return }
        let source: IOSExternalResourceSource
        switch profile.source {
        case .url: source = .subscription
        case .file: source = .localFile
        case .clipboard: source = .clipboard
        }
         
         
        let requirements = IOSExternalResourceCatalog.requirements(root: runtimeRoot)
        var externalResources = IOSExternalResourceCatalog.inspect(
            root: runtimeRoot,
            source: source,
            requirements: requirements
        )
         
         
        externalResources.removeAll { $0.resolution == .managedRuntimeStateRequired }
        let references = profile.externalResources ?? []
        var allowed: [String: Int] = [:]
        for requirement in requirements
        where requirement.capability.disposition == .publicFileOrInline {
            let digest = ProfileExternalResourceImporter.sha256(
                Data(requirement.rawValue.utf8)
            )
            if references.contains(where: {
                $0.capabilityID == requirement.capability.id
                    && $0.proxy == requirement.proxyName
                    && $0.fieldPath == requirement.capability.fieldPath
                    && $0.sourceValueSHA256 == digest
            }) {
                allowed[requirement.capability.id, default: 0] += 1
            }
        }
        externalResources.removeAll { finding in
            guard (finding.resolution == .localImportRequired
                    || finding.resolution == .subscriptionCannotReadFile),
                  let count = allowed[finding.capabilityID], count > 0 else {
                return false
            }
            allowed[finding.capabilityID] = count - 1
            return true
        }
        for finding in externalResources {
            log("external resource left to the kernel  id=\(profile.id) capability=\(finding.capabilityID) resolution=\(finding.resolution)")
        }
    }

     
     
     
     
     
     
     
     
     
     
     
    private func reusableProvidersDirectory(for profile: Profile) -> (URL?, String) {
         
         
         
         
         
        let recorded = profileStore.load().first { $0.id == profile.id }?.activeRevision
        for revision in [recorded, profile.activeRevision].compactMap({ $0 }) {
            if let own = store.providersDirectory(profileID: profile.id, revision: revision),
               FileManager.default.fileExists(atPath: own.path) {
                return (own, "own(\(fileCount(in: own)))")
            }
        }
        if let newest = store.newestProvidersDirectory(profileID: profile.id) {
            return (newest, "newest(\(fileCount(in: newest)))")
        }
        if let active = try? store.activeProvidersDirectory() {
            return (active, "active(\(fileCount(in: active)))")
        }
        return (nil, "none")
    }

    private func fileCount(in directory: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.count ?? -1
    }

    private func buildPublishActivate(
        profile: Profile, merged: String,
         
         
        mergedRoot: [String: Any]? = nil,
        reuseDir: URL? = nil,
        reuseDirIsOwnRevision: Bool = true,
        forceRefresh: Set<String> = [],
        providerOverrides: [String: Data] = [:],
        replacing previousRuntime: ActiveConfigurationPointer? = nil,
        fetchBudget: ProviderFetchBudget = .patient,
         
         
         
         
        fetchOnly: Set<String>? = nil,
        capturePayloads: Set<String> = [],
         
         
         
        beforePublish: (() throws -> Void)? = nil,
        downloadRound: ProviderDownloadRound? = nil,
         
        source: String? = nil,
         
         
         
         
        overTheCatalogItRead: Bool = false
    ) async throws -> ProfilePublicationResult {
        var laps = PerfLedger.Laps()
         
         
         
        let presentationAtStart = presentationInputs(source: source, profile: profile)
         
         
        let catalogAsRead = overTheCatalogItRead ? previousRuntime.map { store.catalogData(of: $0) } : nil
        let candidate = try store.beginCandidate(profileID: profile.id)
        let previous: ActiveConfigurationPointer?
         
        var unchanged: ActiveConfigurationPointer?
        var publishedPreflight: PreflightOutcome?
        var publishedNotices: [String]?
        var runtimeUpdates: [String: ProviderRuntimeUpdate] = [:]
        var firstLoadPending: [String] = []
        var publishedRouteNames: Set<String> = []
        do {
            let materializedMerged = try ProfileExternalResourceMaterializer.materialize(
                yaml: merged,
                root: mergedRoot,
                profile: profile,
                coreHomeDir: coreHomeDir,
                candidate: candidate
            )
            laps.mark("publish.materialize")
            let plan = try ConfigTransforms.planResources(mergedYAML: materializedMerged)
            laps.mark("publish.plan")
            guard plan.errors.isEmpty else {
                throw PipelineError.planRejected(plan.errors)
            }
             
             
             
             
             
            let materializedRoot = (mergedRoot != nil && materializedMerged == merged)
                ? mergedRoot : try ConfigTransforms.foundationRoot(ofYAML: materializedMerged)
            let ageSecretKeys = ConfigTransforms.providerAgeSecretKeys(root: materializedRoot)
             
             
            let routeSetProviders = ConfigTransforms.routeSetProviderNames(root: materializedRoot)
            laps.mark("publish.readPlanned")
            let coreRouteCache = try CoreOwnedRouteCache(
                mergedYAML: materializedMerged, plan: plan, routeSetProviders: routeSetProviders,
                profileID: profile.id, workingDirectory: coreHomeDir)
            var reusedCoreFilePaths: Set<String> = []
            if fetchOnly != nil, plan.providers.contains(where: { ProviderFetchedByCore.applies(toProxy: $0.proxy) }),
               let previousRuntime, let reuseDir,
               let previousYAML = try store.loadConfiguration(
                    profileID: previousRuntime.profileID, revision: previousRuntime.revision).text {
                let json = try ConfigTransforms.yamlToJSON(previousYAML)
                let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
                 
                 
                let adopted = ProviderCatalog.load(providersDir: reuseDir)?.coreRouteSeeds ?? []
                 
                 
                 
                reusedCoreFilePaths = Set(plan.providers.compactMap { provider in
                    guard ProviderFetchedByCore.applies(toProxy: provider.proxy),
                          !adopted.contains(provider.name) else { return nil }
                    let section = provider.kind == "rule" ? "rule-providers" : "proxy-providers"
                    let definition = (root[section] as? [String: [String: Any]])?[provider.name]
                    guard definition?["type"] as? String == "file",
                          definition?["path"] as? String == reuseDir.appendingPathComponent(provider.path).path
                    else { return nil }
                    return provider.path
                })
            }
             
             
             
             
             
            for provider in plan.providers where provider.kind == "proxy" {
                if let resourceKey = provider.resourceKey {
                    try? credentials.remove("provider.age.\(profile.id).\(resourceKey)")
                }
            }
            let requestedProviders = forceRefresh.union(Set(providerOverrides.keys)).union(capturePayloads)
            for name in requestedProviders
            where !plan.providers.contains(where: { $0.name == name }) {
                throw PipelineError.providerNotFound(name)
            }
            let stages = ActivationStopwatch()
            let libraryFiles = ConfigurationCollectionContentBridge.cachedLibraryFiles(
                for: plan.providers, workingDirectory: coreHomeDir)
            let materialized = try await materializer.materializeDetailed(
                plan: plan,
                into: candidate.stagingProvidersDirectory,
                publishedProvidersDir: candidate.publishedProvidersDirectory,
                maxBytesEach: Self.maxProviderBytes,
                reuseDir: reuseDir,
                reuseDirIsOwnRevision: reuseDirIsOwnRevision,
                forceRefresh: forceRefresh,
                ageSecretKeys: ageSecretKeys,
                localOverrides: providerOverrides,
                cachedNodeFiles: libraryFiles.nodes,
                cachedRuleFiles: libraryFiles.rules,
                captureRefreshedPayloads: requestedProviders,
                userAgent: ClientUserAgent.resolved(
                    root: materializedRoot,
                    fallback: ClientUserAgent.resolved(profile: profile)
                ),
                routeSetProviders: routeSetProviders,
                coreRouteSnapshots: coreRouteCache.snapshots,
                coreRouteDates: coreRouteCache.dates,
                reusedCoreFilePaths: reusedCoreFilePaths,
                fetchOnly: fetchOnly,
                fetchBudget: fetchBudget,
                payloadStore: store.payloadStore,
                downloadRound: downloadRound
            )
             
             
             
             
             
            ConfigurationCollectionContentBridge.keepInLibrary(plan.providers.compactMap { provider in
                guard provider.kind == "proxy", materialized.downloadedNames.contains(provider.name),
                      let path = materialized.readPaths[provider.name] else { return nil }
                return (provider, URL(fileURLWithPath: path), materialized.entryCounts[provider.name] ?? 0,
                        materialized.subscriptionUserInfo[provider.name].flatMap { SubscriptionInfo.parse(header: $0) }
                            .map(ConfigurationCenterSourceBridge.subscriptionUsage))
            }, workingDirectory: coreHomeDir)
            firstLoadPending = materialized.firstLoadPending
            firstLoadPendingOfLastPublication = firstLoadPending
            publishedRouteNames = Set(plan.providers.filter {
                $0.kind == "rule" && $0.behavior.lowercased() == "ipcidr"
                    && routeSetProviders.contains($0.name) && materialized.readPaths[$0.name] != nil
            }.map(\.name))
            let providerPaths = materialized.paths
             
             
             
             
             
             
             
            let providerKinds = Dictionary(
                plan.providers.map { ($0.name, $0.kind) },
                uniquingKeysWith: { first, _ in first }
            )
            runtimeUpdates = Dictionary(
                uniqueKeysWithValues: materialized.refreshedPayloads.compactMap { name, payload in
                    guard let kind = providerKinds[name] else { return nil }
                    return (name, ProviderRuntimeUpdate(
                        name: name, kind: kind, payload: payload,
                        publishedIn: ActiveConfigurationPointer(profileID: profile.id, revision: candidate.revision)))
                }
            )
             
             
             
             
             
             
             
            let providerReadPaths = materialized.readPaths
             
             
            let reusedEntries = reuseDir.flatMap {
                ProviderCatalog.load(providersDir: $0)
            }?.entries ?? []
            var subscriptionInfo = Dictionary(
                reusedEntries
                    .compactMap { entry in
                        entry.subscriptionInfo.map { (entry.name, $0) }
                    },
                uniquingKeysWith: { first, _ in first }
            )
            var lastUpdatedAt: [String: Date] = [:]
            for entry in reusedEntries {
                if let timestamp = entry.lastUpdatedAt {
                    lastUpdatedAt[entry.name] = timestamp
                } else if let reuseDir,
                          let attributes = try? FileManager.default.attributesOfItem(
                            atPath: reuseDir.appendingPathComponent(entry.path).path
                          ),
                          let timestamp = attributes[.modificationDate] as? Date {
                     
                     
                    lastUpdatedAt[entry.name] = timestamp
                }
            }
             
             
             
             
             
            for name in materialized.firstLoadPending { lastUpdatedAt.removeValue(forKey: name) }
            let refreshedAt = now()
            for name in materialized.refreshedNames {
                 
                 
                lastUpdatedAt[name] = materialized.libraryCopyDates[name] ?? refreshedAt
                 
                guard materialized.libraryCopyDates[name] == nil else { continue }
                subscriptionInfo.removeValue(forKey: name)
                if let header = materialized.subscriptionUserInfo[name],
                   let parsed = SubscriptionInfo.parse(header: header) {
                    subscriptionInfo[name] = parsed
                }
            }
             
             
             
             
             
             
            for name in materialized.libraryCopyDates.keys {
                if let usage = libraryFiles.nodeUsage[name] { subscriptionInfo[name] = usage }
            }
            try ProviderCatalog.from(
                plan: plan,
                entryCounts: materialized.entryCounts,
                subscriptionInfo: subscriptionInfo,
                lastUpdatedAt: lastUpdatedAt,
                notes: Dictionary(
                    materialized.validationWarnings.map { ($0.provider, $0.note) },
                    uniquingKeysWith: { first, _ in first }
                ),
                 
                 
                notedAt: Dictionary(
                    materialized.validationWarnings.map { ($0.provider, $0.notedAt ?? refreshedAt) },
                    uniquingKeysWith: { first, _ in first }
                ),
                payloadSourceURLs: materialized.payloadSourceURLs,
                payloadRequests: materialized.payloadRequests,
                acquiredAt: materialized.acquiredAt,
                routeSetProviders: routeSetProviders,
                coreRouteSeeds: materialized.coreRouteSeeds,
                seedPaths: materialized.seedPaths
            ).write(providersDir: candidate.stagingProvidersDirectory)
            stages.mark(
                "providers",
                count: plan.providers.count,
                detail: "reused=\(materialized.reusedCount) fetched=\(materialized.fetchedCount) "
                    + "from=\(activationReuseSource)"
                     
                     
                     
                    + (materialized.staleFallbacks.isEmpty
                        ? ""
                        : " kept-old=\(materialized.staleFallbacks.count)")
            )
             
             
             
            try await geodata.stage(
                plan: plan,
                homeDir: coreHomeDir,
                maxBytesEach: Self.maxGeodataBytes,
                preferBundled: true,
                reuseExisting: true
            )

            stages.mark("geodata")
            laps.mark("publish.providers")
             
             
             
             
             
             
             
             
             
             
            var seeds = ConfigTransforms.ProviderSeedFacts()
            for provider in plan.providers {
                let key = provider.kind + ":" + provider.name
                if let at = materialized.acquiredAt[provider.path] { seeds.fetchedAt[key] = Int64(at.timeIntervalSince1970) }
                if provider.kind == "proxy", let info = materialized.subscriptionUserInfo[provider.name] {
                    seeds.subscriptionInfo[key] = info
                }
            }
             
             
             
             
            let nodeLibraryDirectory = writesNodeLibrary
                ? NodeLibraries.directory(container: coreHomeDir.deletingLastPathComponent())
                : nil
            let publication: ConfigTransforms.FinalizedPublication
            if preflightIsCallers {
                let text = try ConfigTransforms.finalize(
                    mergedYAML: coreRouteCache.runtimeYAML,
                    providerPaths: providerPaths,
                    providerReadPaths: providerReadPaths,
                    seeds: seeds,
                    nodeLibraryDirectory: nodeLibraryDirectory)
                publication = .init(text: text, preflight: preflight(text), geodataMode: nil,
                                    listenerPorts: nil, listenerPortsAnswered: false, notices: nil)
            } else {
                publication = try ConfigTransforms.finalizeForPublication(
                    mergedYAML: coreRouteCache.runtimeYAML,
                    providerPaths: providerPaths,
                    providerReadPaths: providerReadPaths,
                    seeds: seeds,
                    orderReference: Self.finalizeOrderReference ? merged : nil,
                    container: intentContainer,
                    settings: intentSettings,
                    nodeLibraryDirectory: nodeLibraryDirectory)
            }
            let finalYAML = publication.text

            stages.mark("finalize")
            laps.mark("publish.finalize")
            let outcome = publication.preflight
            stages.mark("preflight")
            laps.mark("publish.preflight")
            guard outcome.ok else {
                throw PipelineError.preflightFailed(outcome.errorMessage ?? "preflight failed")
            }
            publishedPreflight = outcome
            publishedNotices = publication.notices

             
             
             
             
             
             
             
             
             
             
            GeoSiteCompiler.prepare(finalYAML: finalYAML)
             
             
             
             
             
             
            GeoSiteCompiler.prepareRulePayloads(
                in: candidate.stagingProvidersDirectory,
                plan: plan,
                readPaths: materialized.seedPaths
            )
             
             
             
             
             
             
             
             
             
             
             
             
             
            let geodataMode = publication.geodataMode ?? GeoIPCompiler.geodataModeEnabled(in: finalYAML)
            GeoIPCompiler.prepare(finalYAML: finalYAML, geodataMode: geodataMode)
            GeoIPCompiler.prepareRulePayloads(
                in: candidate.stagingProvidersDirectory,
                plan: plan,
                geodataMode: geodataMode,
                readPaths: materialized.seedPaths
            )
            stages.mark("geosite")
            stages.report()
            laps.mark("publish.compileCaches")

             
             
             
             
            let store = self.store
            let finalData = Data(finalYAML.utf8)
            let expectation: ConfigResourceStore.ActiveExpectation = previousRuntime.map { previous in
                catalogAsRead.map { .matchesWithCatalog(previous, catalog: $0) } ?? .matches(previous)
            } ?? .unconstrained
            if let inUse = store.adoptIfEquivalentToActive(
                candidate, finalData: finalData, expectation: expectation) {
                 
                 
                 
                 
                 
                 
                if let beforePublish { try ProfileStore.withWriteLock { try beforePublish() } }
                try? store.discard(candidate)
                previous = inUse
                unchanged = inUse
                laps.mark("publish.unchanged")
                ClashLogSettings.setActiveProfileLogLevel(lastProfileLogLevel, in: logDefaults)
                 
                 
                 
                 
                let inUseText = (try? store.loadConfiguration(profileID: inUse.profileID, revision: inUse.revision).text)
                    ?? finalYAML.replacingOccurrences(of: candidate.revision, with: inUse.revision)
                compileUnchanged(finalYAML: inUseText, providerCount: plan.providers.count)
                AppCore.returnFreeMemory()
            } else {
                let staged = try store.stage(candidate, finalData: finalData)
                do {
                    if let beforePublish {
                         
                         
                         
                         
                         
                         
                         
                         
                         
                         
                        var activated: ActiveConfigurationPointer??
                        for _ in 0..<200 where activated == nil {
                            activated = try ProfileStore.withWriteLock { () -> ActiveConfigurationPointer?? in
                                try beforePublish()
                                switch try store.activateStagedIfLockFree(staged, expectation: expectation) {
                                case .activated(let before): return .some(before)
                                case .busy: return nil
                                }
                            }
                            if activated == nil { try store.waitUntilLockIsFree() }
                        }
                        guard let settled = activated else { throw ConfigResourceStoreError.lockTimedOut }
                        previous = settled
                    } else {
                        previous = try store.activateStaged(staged, expectation: expectation)
                    }
                } catch {
                    store.discardStaged(staged)
                    throw error
                }
                store.finishActivation(staged)
                laps.mark("publish.stage")
                 
                 
                 
                NodeLibraries.prune(container: coreHomeDir.deletingLastPathComponent())
                 
                 
                 
                ClashLogSettings.setActiveProfileLogLevel(lastProfileLogLevel, in: logDefaults)
                 
                 
                 
                 
                 
                 
                 
                publishStaging(finalYAML: finalYAML, providerCount: plan.providers.count)
                laps.mark("publish.listenersAndStaging")
                 
                 
                AppCore.returnFreeMemory()
                 
                 
                 
                 
                if let intentJSON = outcome.intentJSON {
                    PublishedTunIntent.publish(
                        intentJSON: intentJSON,
                        defaults: UserDefaults(suiteName: ClashAppIdentifiers.appGroup)
                    )
                }
            }
        } catch {
             
            try? store.discard(candidate)
            throw error
        }

        defer { laps.mark("publish.activator") }
        do {
            try activator(store.activeConfigURL)
        } catch {
             
             
             
             
             
            do {
                try store.restoreActive(previous)
            } catch {
                _ = try? store.recoverCurrentFromLastKnownGood()
            }
            throw error
        }

        let published = unchanged ?? ActiveConfigurationPointer(profileID: profile.id, revision: candidate.revision)
        PublishedSourceLedger.record(published, source: source)
        let presentationNow = presentationInputs(source: source, profile: profile)
        PublishedPresentation.record(
            published,
            inputs: presentationNow == presentationAtStart ? presentationNow : nil,
            workingDirectory: coreHomeDir
        )
        lastPublicationPreflight = publishedPreflight.map { (published, $0) }
        lastPublicationNotices = publishedNotices.map { (published, $0) }
        return ProfilePublicationResult(
            pointer: published,
            previous: previous,
            runtimeUpdates: runtimeUpdates,
            firstLoadPending: firstLoadPending,
            publishedRouteNames: publishedRouteNames
        )
    }

     
     
     
     
     
     
     
    private func revisionInUse(of profile: Profile,
                               expected: ActiveConfigurationPointer? = nil) throws -> ActiveConfigurationPointer {
         
         
         
         
        guard let current = store.activeIdentityWithoutLock(), current.profileID == profile.id,
              expected == nil || current == expected else {
            throw ConfigResourceStoreError.activeConfigurationChanged
        }
        return current
    }

     
     
     
     
     
    private func inUseAndOnDisk(_ given: Profile, expected: ActiveConfigurationPointer? = nil) throws
        -> (ActiveConfigurationPointer, Profile) {
        try ProfileStore.withWriteLock {
            (try revisionInUse(of: given, expected: expected), onDisk(given))
        }
    }

     
     
     
    private func onDisk(_ profile: Profile) -> Profile {
        profileStore.load().first(where: { $0.id == profile.id }) ?? profile
    }

     
     
     
     
    private func recordRevision(_ pointer: ActiveConfigurationPointer, of profile: Profile) {
        _ = try? profileStore.updateIfPresent(id: profile.id) { $0.activeRevision = pointer.revision }
    }

     
     
     
     
     
     
     
     
     
     
     
    private func announceProviderContent(of profile: Profile) {
        let profileID = profile.id
        let workingDirectory = coreHomeDir.standardizedFileURL.path
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .clashProviderContentChanged, object: nil,
                                            userInfo: ["profileID": profileID, "workingDirectory": workingDirectory])
        }
    }

    private func sidecarURL(profileID: String) -> URL {
        coreHomeDir.appendingPathComponent("store/\(profileID)/source.yaml")
    }


    private func writeSourceSidecar(_ yaml: String, profileID: String) throws {
        let url = sidecarURL(profileID: profileID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(yaml.utf8).write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

}

 
 
final class CompileQueueRun: @unchecked Sendable {
    private let lock = NSLock()
    private var startable = true
    private var answered = false
     
    func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return startable
    }
     
    func expire() {
        lock.lock(); startable = false; lock.unlock()
    }
     
    func answer() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if answered { return false }
        answered = true
        return true
    }
}

 
final class CompileQueueCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: UInt64 = 0
    var value: UInt64 { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count &+= 1; lock.unlock() }
}

 
final class CompileQueueOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
