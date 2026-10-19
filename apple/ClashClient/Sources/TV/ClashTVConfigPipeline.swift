import CryptoKit
import Foundation
import Clash

 
 
 
 
 
 
 
enum ClashTVCore {
    static func ensureSetup(container: URL) throws {
        try AppCoreSetup.ensure(container: container)
    }
}

 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
final class ClashTVConfigPipeline {
    enum Phase: Equatable {
        case downloading
        case preparing
        case publishing
    }

    struct Activation: Equatable {
        let profileID: String
        let revision: String
        let finalYAML: String
        let providerCount: Int
        let warnings: [String]
        let userInfo: String?
         
         
        let panelName: String?
         
        let catalog: ClashTVProviderCatalog
         
         
        var changed = true
    }

    enum PipelineError: LocalizedError {
        case invalidConfiguration(String)
        case planRejected([String])
        case publishFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration(let reason):
                return String(localized: "Clash can't read this profile: \(reason)")
            case .planRejected(let reasons):
                let joined = reasons.joined(separator: "; ")
                return String(localized: "The configuration was refused: \(joined)")
            case .publishFailed(let reason):
                return String(localized: "The configuration could not be saved on this Apple TV: \(reason)")
            }
        }
    }

    let container: URL
    let session: URLSession

     
     
     
     
     
    let defaults: UserDefaults
    private let setupCore: ((URL) throws -> Void)?
    private let frozenSettings: IPStackSettings?

    init(
        container: URL,
        session: URLSession = ClashTVNetwork.session,
        defaults: UserDefaults = ClientUserAgent.appGroupDefaults,
        settings: IPStackSettings? = nil,
        setupCore: ((URL) throws -> Void)? = nil
    ) {
        self.defaults = defaults
        self.setupCore = setupCore
        self.frozenSettings = settings
        self.container = container
        self.session = session
    }

     
     
     
     
     
     
     
     
     
     
    static func refusal(_ error: Error) -> Error {
        Task.isCancelled || error is CancellationError ? CancellationError() : PipelineError.invalidConfiguration(error.localizedDescription)
    }

    static func profileID(for subscription: ClashTVSubscription) -> String {
        var identity = subscription.requestURL.absoluteString
        if subscription.effectiveRules != .own { identity += "\n" + subscription.effectiveRules.rawValue }
         
         
        if let script = subscription.scriptURL { identity += "\nscript:" + script.absoluteString }
        let digest = SHA256.hash(data: Data(identity.utf8))
        let bytes = Array(digest.prefix(16))
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid.uuidString.lowercased()
    }

    var userAgent: String {
        ClashTVSubscriptionFetcher.userAgent(defaults: defaults)
    }

    private func prepareEnvironment(settings: IPStackSettings) throws {
        let working = container.appendingPathComponent("working", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        if let setupCore { try setupCore(container) }
        else { try AppCoreSetup.ensure(container: container, settings: settings) }
        try BundledGeodataProvisioner.seedAllMissing(into: working)
    }

     
     
     
    func updateScript(for subscription: ClashTVSubscription) async throws -> Int {
        guard subscription.scriptURL != nil else {
            throw PipelineError.invalidConfiguration(ClashTVOverrideScript.noScript)
        }
        let source = try await fetchScript(for: subscription, profileID: Self.profileID(for: subscription))
        ClashLogStore.shared.append("tv override script updated  bytes=\(source.utf8.count)", stream: .app)
        return source.utf8.count
    }

    private func fetchScript(for subscription: ClashTVSubscription, profileID: String) async throws -> String {
        guard let scriptURL = subscription.scriptURL else {
            throw PipelineError.invalidConfiguration(ClashTVOverrideScript.noScript)
        }
        let script = try await ClashTVSubscriptionFetcher.fetchBody(scriptURL, session: session, userAgent: userAgent)
        guard let source = String(data: script.body, encoding: .utf8) else {
            throw PipelineError.invalidConfiguration(ClashTVOverrideScript.notText)
        }
        try ClashTVOverrideScriptStore.write(source, container: container, profileID: profileID)
        return source
    }

    func activate(
        subscription: ClashTVSubscription,
         
         
        tunnelRunning: Bool = false,
        progress: @escaping (Phase) -> Void
    ) async throws -> Activation {
        let settings = try frozenSettings ?? IPStackSettings.load(from: defaults)
        try prepareEnvironment(settings: settings)

        let profileID = Self.profileID(for: subscription)
        let sourceYAML: String
        let userInfo: String?
        let panelName: String?
        if let restored = ClashTVRestoredDocuments.read(container: container, profileID: profileID) {
             
             
             
            sourceYAML = restored
            userInfo = nil
            panelName = nil
        } else {
            progress(.downloading)
            let fetched = try await ClashTVSubscriptionFetcher.fetchBody(
                subscription.requestURL,
                session: session,
                userAgent: userAgent
            )
             
             
             
             
            let composed: String
            do {
                composed = try ClashTVComposedProfile.document(body: fetched.body, rules: subscription.effectiveRules)
            } catch let error as ClashTVSubscriptionFetcher.FetchError {
                throw error
            } catch {
                throw Self.refusal(error)
            }
             
             
             
             
             
            if subscription.scriptURL != nil {
                 
                 
                let source: String
                if let kept = ClashTVOverrideScriptStore.read(container: container, profileID: profileID) {
                    source = kept
                } else {
                    source = try await fetchScript(for: subscription, profileID: profileID)
                }
                do {
                    sourceYAML = try ClashTVOverrideScript.apply(script: source, toYAML: composed, profileName: subscription.title)
                } catch {
                    throw Self.refusal(error)
                }
                ClashLogStore.shared.append("tv override script applied  bytes=\(source.utf8.count)", stream: .app)
            } else {
                sourceYAML = composed
            }
            userInfo = fetched.userInfo
            panelName = fetched.panelName
        }
         
         
         
        try Task.checkCancellation()

        return try await prepare(sourceYAML: sourceYAML, profileID: profileID,
                                 userInfo: userInfo, panelName: panelName, tunnelRunning: tunnelRunning,
                                 progress: progress)
    }

     
     
     
     
     
    func recoverRules(expected: ActiveConfigurationPointer,
                      tunnelHashes: [String: Set<String>]? = nil,
                      verify: (@MainActor ([String: String]) async throws -> Bool)? = nil) async throws -> Activation? {
        let store = try ConfigResourceStore(containerURL: container)
        guard try store.activeIdentity() == expected,
              let directory = store.providersDirectory(profileID: expected.profileID, revision: expected.revision),
              let record = ClashTVRuleRecovery.read(from: directory) else { return nil }
         
        let settings = try frozenSettings ?? IPStackSettings.load(from: defaults)
        try prepareEnvironment(settings: settings)
        let plan = try ConfigTransforms.planResources(mergedYAML: record.sourceYAML)
        var snapshots = try ClashTVRuleRecovery.snapshots(sourceYAML: record.sourceYAML, plan: plan,
                                                       container: container, profileID: expected.profileID,
                                                       tunnelHashes: tunnelHashes)
         
        for provider in plan.providers where provider.kind == "rule" {
            let key = ClashTVProviderMaterializer.resourceKey(for: provider)
            if snapshots[key] == nil, record.hashes[key] != nil,
               let data = try? Data(contentsOf: directory.appendingPathComponent(provider.path)) {
                snapshots[key] = data
            }
        }
        guard ClashTVRuleRecovery.hashes(snapshots) != record.hashes else { return nil }
        if let verify {
            let hashes = ClashTVRuleRecovery.hashes(snapshots)
            guard try await verify(hashes) else { return nil }
        }
        return try await prepare(sourceYAML: record.sourceYAML, profileID: expected.profileID,
                                 userInfo: nil, panelName: nil, expected: expected,
                                 existingProxyDirectory: directory, snapshots: snapshots, progress: { _ in })
    }

    private func prepare(sourceYAML: String, profileID: String, userInfo: String?, panelName: String?,
                         expected: ActiveConfigurationPointer? = nil, existingProxyDirectory: URL? = nil,
                         snapshots suppliedSnapshots: [String: Data]? = nil, tunnelRunning: Bool = false,
                         progress: @escaping (Phase) -> Void) async throws -> Activation {
        progress(.preparing)
        do {
            try ConfigTransforms.validateSource(sourceYAML)
        } catch {
            throw Self.refusal(error)
        }
        let plan: RemoteResourcePlan
        do {
            plan = try ConfigTransforms.planResources(mergedYAML: sourceYAML)
        } catch {
            throw Self.refusal(error)
        }
        guard plan.errors.isEmpty else {
            throw PipelineError.planRejected(plan.errors.map { "\($0.field): \($0.reason)" })
        }
         
         
        let ageSecretKeys: [String: String]
        do {
            ageSecretKeys = try ConfigTransforms.providerAgeSecretKeys(mergedYAML: sourceYAML)
        } catch {
            throw Self.refusal(error)
        }

        let snapshots = try suppliedSnapshots ?? ClashTVRuleRecovery.snapshots(
            sourceYAML: sourceYAML, plan: plan, container: container, profileID: profileID)
        let runtimeSource = try ClashTVRuleRecovery.confinedSource(
            sourceYAML, plan: plan, container: container, profileID: profileID)
        let store = try ConfigResourceStore(containerURL: container)
        let previousDirectory = try? store.activeProvidersDirectory()
        let previous = previousDirectory.flatMap { ClashTVProviderCatalog.read(from: $0) }
        let sourceSHA256 = ClashTVRuleRecovery.sha256(Data(sourceYAML.utf8))
        let candidate = try store.beginCandidate(profileID: profileID)
        do {
            let materialized = try await ClashTVProviderMaterializer.materialize(
                plan: plan,
                candidate: candidate,
                session: session,
                userAgent: userAgent,
                ageSecretKeys: ageSecretKeys,
                ruleSnapshots: snapshots,
                routeSetNames: ClashTVRuleRecovery.routeSetNames(sourceYAML: sourceYAML, plan: plan),
                routeSeedDates: ClashTVRuleRecovery.tunnelCheckedAt(container: container),
                existingProxyDirectory: existingProxyDirectory,
                existingCatalog: existingProxyDirectory.flatMap { ClashTVProviderCatalog.read(from: $0) },
                tunnelRunning: tunnelRunning,
                unusableAddresses: ClashTVProviderMaterializer.notices(plan, kind: "provider-url-unusable"),
                localProviders: ClashTVProviderMaterializer.localProviders(sourceYAML: sourceYAML, plan: plan),
                previousProvidersDirectory: previousDirectory,
                sourceSHA256: sourceSHA256
            )
            try Task.checkCancellation()
            let finalYAML = try ConfigTransforms.finalize(
                mergedYAML: runtimeSource,
                providerPaths: materialized.paths,
                providerReadPaths: materialized.readPaths,
                seeds: .init(fetchedAt: materialized.fetchedAt)
            )
            if plan.providers.contains(where: { $0.kind == "rule" }) {
                try ClashTVRuleRecovery(sourceYAML: sourceYAML, hashes: ClashTVRuleRecovery.hashes(snapshots))
                    .write(to: candidate.stagingProvidersDirectory)
            }
            GeoSiteCompiler.prepare(finalYAML: finalYAML)
            GeoSiteCompiler.prepareRulePayloads(in: candidate.stagingProvidersDirectory, plan: plan)
            GeoIPCompiler.prepare(finalYAML: finalYAML)
            GeoIPCompiler.prepareRulePayloads(
                in: candidate.stagingProvidersDirectory,
                plan: plan,
                geodataMode: GeoIPCompiler.geodataModeEnabled(in: finalYAML)
            )

             
             
            try Task.checkCancellation()
            progress(.publishing)
            do {
                if let expected {
                    _ = try store.publishAndActivateIfCurrentMatches(candidate, finalData: Data(finalYAML.utf8), expectedActive: expected)
                } else {
                    _ = try store.publishAndActivate(candidate, finalData: Data(finalYAML.utf8))
                }
            } catch {
                throw PipelineError.publishFailed(error.localizedDescription)
            }
             
             
            if expected == nil {
                ProviderStagingPublisher.publish(
                    finalYAML: finalYAML,
                    providerCount: plan.providers.count,
                    compileRuleSets: false
                )
            }
             
             
            return Activation(
                profileID: profileID,
                revision: candidate.revision,
                finalYAML: finalYAML,
                providerCount: plan.providers.count,
                warnings: materialized.warnings,
                userInfo: userInfo,
                panelName: panelName,
                catalog: materialized.catalog,
                changed: previous?.sourceSHA256 != sourceSHA256 || materialized.contentChanged
            )
        } catch {
            try? store.discard(candidate)
            throw error
        }
    }
}

 
 
struct ClashTVRuleRecovery: Codable {
    static let fileName = "tv-rule-source.json"
     
    static let maximumCacheBytes = 16 * 1024 * 1024
    let sourceYAML: String
    let hashes: [String: String]

    var hasUnexpandedRoutes: Bool {
        guard let plan = try? ConfigTransforms.planResources(mergedYAML: sourceYAML) else { return false }
        let names = Self.routeSetNames(sourceYAML: sourceYAML, plan: plan)
        return plan.providers.contains {
            names.contains($0.name) && hashes[ClashTVProviderMaterializer.resourceKey(for: $0)] == nil
        }
    }

     
     
    static func routeSetNames(sourceYAML: String, plan: RemoteResourcePlan) -> Set<String> {
        guard let json = try? ConfigTransforms.yamlToJSON(sourceYAML),
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let tun = root["tun"] as? [String: Any] else { return [] }
        let names = Set((tun["route-address-set"] as? [String] ?? []) + (tun["route-exclude-address-set"] as? [String] ?? []))
        return Set(plan.providers.filter { $0.kind == "rule" && $0.behavior == "ipcidr" && names.contains($0.name) }.map(\.name))
    }

    func write(to directory: URL) throws {
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    static func read(from directory: URL) -> Self? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func hashes(_ snapshots: [String: Data]) -> [String: String] {
        snapshots.mapValues { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }

    static func cacheURL(for provider: RemoteResourcePlan.Provider, sourceYAML: String,
                         container: URL, profileID: String) throws -> URL {
        try cacheURLs(sourceYAML: sourceYAML, plan: .init(providers: [provider]),
                      container: container, profileID: profileID)[ClashTVProviderMaterializer.resourceKey(for: provider)]!
    }

    static func cacheURLs(sourceYAML: String, plan: RemoteResourcePlan,
                          container: URL, profileID: String) throws -> [String: URL] {
        let json = try ConfigTransforms.yamlToJSON(sourceYAML)
        let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        var urls: [String: URL] = [:]
        for provider in plan.providers where provider.kind == "rule" {
            let section = "rule-providers"
            var definition = (root[section] as? [String: [String: Any]])?[provider.name] ?? [:]
            definition.removeValue(forKey: "path")
             
             
            let identity: [String: Any] = ["profile": profileID, "kind": provider.kind,
                                         "name": provider.name, "definition": definition,
                                         "globalUA": root["global-ua"] ?? ""]
            let data = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            urls[ClashTVProviderMaterializer.resourceKey(for: provider)] =
                container.appendingPathComponent("working/tv-rule-cache/\(hash)")
        }
        return urls
    }

    static func confinedSource(_ source: String, plan: RemoteResourcePlan,
                               container: URL, profileID: String) throws -> String {
        var sections: [String: [String: [String: String]]] = [:]
        let urls = try cacheURLs(sourceYAML: source, plan: plan, container: container, profileID: profileID)
        for provider in plan.providers where provider.kind == "rule" {
            let section = "rule-providers"
            guard let url = urls[ClashTVProviderMaterializer.resourceKey(for: provider)] else { continue }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            sections[section, default: [:]][provider.name] = ["path": url.path]
        }
        guard !sections.isEmpty else { return source }
        let patch = try JSONSerialization.data(withJSONObject: ["patch": sections], options: [.sortedKeys])
        return try ConfigTransforms.mergeOverride(raw: source, overrideJSON: String(decoding: patch, as: UTF8.self))
    }

    static func snapshots(sourceYAML: String, plan: RemoteResourcePlan,
                          container: URL, profileID: String,
                          tunnelHashes: [String: Set<String>]? = nil) throws -> [String: Data] {
        var snapshots: [String: Data] = [:]
        let urls = try cacheURLs(sourceYAML: sourceYAML, plan: plan, container: container, profileID: profileID)
        for provider in plan.providers where provider.kind == "rule" {
            guard let url = urls[ClashTVProviderMaterializer.resourceKey(for: provider)] else { continue }
            let limit = provider.maximumBytes > 0
                ? Int(min(Int64(maximumCacheBytes), provider.maximumBytes)) : maximumCacheBytes
            guard let data = stableBytes(at: url, maximumBytes: limit) else { continue }
            if let tunnelHashes, tunnelHashes[provider.name]?.contains(sha256(data)) != true { continue }
             
            guard (try? ClashTVProviderMaterializer.coreInspector(provider.kind, provider.behavior, provider.format, data)) != nil else { continue }
            snapshots[ClashTVProviderMaterializer.resourceKey(for: provider)] = data
        }
        return snapshots
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

     
     
     
     
     
     
     
     
     
    static func tunnelContent(container: URL) -> [String: Set<String>] {
        var content: [String: Set<String>] = [:]
        for (name, entry) in runningRuleSets(container: container) {
            var hashes = Set<String>()
            if let source = entry.sourceSHA256, !source.isEmpty { hashes.insert(source) }
            if entry.result == "pendingApp", entry.pendingReason == "routes",
               let pending = entry.pendingSHA256, !pending.isEmpty {
                hashes.insert(pending)
            }
            if !hashes.isEmpty { content[name] = hashes }
        }
        return content
    }

     
     
     
     
    static func tunnelCheckedAt(container: URL) -> [String: Int64] {
        runningRuleSets(container: container).compactMapValues { entry in
            entry.lastCheckedAt.flatMap { $0 > 0 ? $0 : nil }
        }
    }

     
     
    private static func runningRuleSets(container: URL) -> [String: RefreshState.Entry] {
        let url = container.appendingPathComponent("working", isDirectory: true)
            .appendingPathComponent(ClashProviderRefreshDirectoryName, isDirectory: true)
            .appendingPathComponent(ClashProviderRefreshStateFileName)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(RefreshState.self, from: data), state.version == 2,
              let running = state.running?.providers else { return [:] }
        var sets: [String: RefreshState.Entry] = [:]
        for (key, requestKey) in running where key.hasPrefix("rule:") {
            if let entry = state.entries[requestKey] { sets[String(key.dropFirst("rule:".count))] = entry }
        }
        return sets
    }

     
    private struct RefreshState: Decodable {
        struct Running: Decodable { let providers: [String: String]? }
        struct Entry: Decodable {
            let result: String?
            let lastCheckedAt: Int64?
            let pendingReason: String?
            let sourceSHA256: String?
            let pendingSHA256: String?
        }
        let version: Int
        let running: Running?
        let entries: [String: Entry]
    }

     
     
    private static func stableBytes(at url: URL, maximumBytes: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= maximumBytes else { return nil }
        guard let data = try? handle.read(upToCount: maximumBytes + 1),
              data.count == before.st_size else { return nil }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { return nil }
        return data
    }
}
