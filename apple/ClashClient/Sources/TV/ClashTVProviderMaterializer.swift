import Foundation
import Clash
import ClashClientKit

 
 
 
 
 
 
 
 
 
 
 
 
enum ClashTVProviderMaterializer {
    struct Outcome: Equatable {
         
         
         
         
         
         
         
         
         
        let paths: [String: String]
         
         
         
        let readPaths: [String: String]
        let warnings: [String]
         
         
         
        let catalog: ClashTVProviderCatalog
         
         
         
         
         
        let fetchedAt: [String: Int64]
         
         
         
        var contentChanged = false
    }

     
     
     
     
    static func resourceKey(for provider: RemoteResourcePlan.Provider) -> String {
        provider.resourceKey ?? "\(provider.kind):\(provider.name)"
    }

    enum MaterializeError: LocalizedError, Equatable {
        case proxyProviderUnavailable(name: String, reason: String)
        case tooLarge(name: String)
         
        case ageKeyMissing(name: String)
         
         
        case ageDecryptFailed(name: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .proxyProviderUnavailable(let name, let reason):
                String(localized: "The proxy provider “\(name)” could not be downloaded: \(reason)")
            case .tooLarge(let name):
                String(localized: "The provider “\(name)” is larger than this Apple TV accepts.")
            case .ageKeyMissing(let name):
                String(localized: "The proxy provider “\(name)” is encrypted and the profile carries no key for it.")
            case .ageDecryptFailed(let name, let reason):
                String(localized: "The proxy provider “\(name)” could not be decrypted: \(reason)")
            }
        }

         
         
         
         
        var isAboutTheSeal: Bool {
            switch self {
            case .ageKeyMissing, .ageDecryptFailed: true
            case .proxyProviderUnavailable, .tooLarge: false
            }
        }
    }

     
    static let ageArmorPrefix = "-----BEGIN AGE ENCRYPTED FILE-----"

     
    static let maximumBytes = 8 * 1024 * 1024

     
     
    typealias Inspector = (_ kind: String, _ behavior: String, _ format: String, _ payload: Data) throws -> Void

    static let coreInspector: Inspector = { kind, behavior, format, payload in
        var count = 0
        var error: NSError?
        let readable = AppCore.inspectProvider(kind, behavior, format, payload, &count, &error)
        if !readable {
            if let error { throw error }
            throw AuthoredFailure(text: .app(unreadablePayload))
        }
    }

     
    static let unreadablePayload = "Clash could not read this content."
    static let unopenablePayload = "Clash could not open the encrypted content."

     
    struct AuthoredFailure: LocalizedError, Equatable {
        let text: AuthoredText
        var errorDescription: String? { text.text }
    }

     
     
     
    struct LocalProvider: Equatable {
        let kind: String
        let name: String
         
        let vehicle: String
         
         
        let notice: String?
    }

     
     
    struct DownloadKey: Hashable {
        let url: String
        let headers: [String: [String]]
        let proxy: String

        init(_ provider: RemoteResourcePlan.Provider) {
            url = provider.url
            headers = provider.headers
            proxy = provider.proxy
        }
    }

    static func materialize(
        plan: RemoteResourcePlan,
        candidate: ConfigurationCandidate,
        session: URLSession,
        userAgent: String,
        maximumBytes: Int = maximumBytes,
        inspect: Inspector = coreInspector,
         
         
         
        ageSecretKeys: [String: String] = [:],
        ruleSnapshots: [String: Data] = [:],
         
         
        routeSetNames: Set<String> = [],
         
         
        routeSeedDates: [String: Int64] = [:],
        existingProxyDirectory: URL? = nil,
         
         
         
        existingCatalog: ClashTVProviderCatalog? = nil,
         
         
        tunnelRunning: Bool = false,
         
        unusableAddresses: [String: String] = [:],
        localProviders: [LocalProvider] = [],
         
         
        previousProvidersDirectory: URL? = nil,
        sourceSHA256: String? = nil,
        now: @escaping () -> Date = Date.init
    ) async throws -> Outcome {
        var paths: [String: String] = [:]
        var readPaths: [String: String] = [:]
        var warnings: [String] = []
        var entries: [ClashTVProviderCatalog.Entry] = []
        var fetchedAt: [String: Int64] = [:]
        var contentChanged = false
         
         
         
         
         
         
         
         
         
        var downloads: [DownloadKey: Result<Data, Error>] = [:]
        for provider in plan.providers {
            let key = Self.resourceKey(for: provider)
             
             
            if provider.kind == "rule" {
                let payload = ruleSnapshots[key]
                if let payload {
                    let target = candidate.stagingProvidersDirectory.appendingPathComponent(provider.path)
                    try payload.write(to: target, options: .atomic)
                    readPaths[key] = target.path
                     
                     
                     
                     
                     
                     
                     
                     
                     
                     
                     
                    if routeSetNames.contains(provider.name) {
                        paths[key] = candidate.publishedProvidersDirectory.appendingPathComponent(provider.path).path
                        if let date = routeSeedDates[provider.name] { fetchedAt[key] = date }
                    }
                }
                 
                 
                entries.append(.init(kind: provider.kind, name: provider.name, url: provider.url,
                                     updatedAt: nil, note: payload == nil ? .tunnelFetches : nil))
                continue
            }
            let reused = existingCatalog?.entries.first { $0.kind == provider.kind && $0.name == provider.name }
             
             
            if existingProxyDirectory != nil, let reused, reused.pending {
                entries.append(reused)
                continue
            }
            if existingProxyDirectory == nil {
                let target = ProviderUpdateTarget(kind: provider.kind, name: provider.name, vehicle: "http",
                                                  url: provider.url, outbound: provider.proxy,
                                                  unusableAddress: unusableAddresses[key] != nil)
                switch ProviderUpdateRoute.decide(target, tunnelRunning: tunnelRunning) {
                case .appSeed:
                    break
                case .tunnel, .awaitingConnection:
                     
                     
                    entries.append(.init(kind: provider.kind, name: provider.name, url: provider.url, updatedAt: nil,
                                         note: target.fetchedByCore ? .fetchedByCore(outbound: provider.proxy) : .tunnelFetches))
                    continue
                case .notUpdatable:
                    entries.append(.init(kind: provider.kind, name: provider.name, url: provider.url, updatedAt: nil,
                                         note: .unreadable(.verbatim(unusableAddresses[key] ?? provider.url))))
                    continue
                }
            }
            let target = candidate.stagingProvidersDirectory.appendingPathComponent(provider.path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let published = candidate.publishedProvidersDirectory.appendingPathComponent(provider.path).path
            let payload: Data
            var failure: AuthoredText?
            var downloaded = false
            do {
                let downloadKey = DownloadKey(provider)
                let rawPayload: Data
                if let existingProxyDirectory {
                    rawPayload = try Data(contentsOf: existingProxyDirectory.appendingPathComponent(provider.path))
                } else if let shared = downloads[downloadKey] {
                    rawPayload = try shared.get()
                    downloaded = true
                } else {
                    do {
                        rawPayload = try await download(provider, session: session, userAgent: userAgent, maximumBytes: maximumBytes)
                        downloads[downloadKey] = .success(rawPayload)
                        downloaded = true
                    } catch {
                         
                         
                         
                        if !Task.isCancelled { downloads[downloadKey] = .failure(error) }
                        throw error
                    }
                }
                let bytes = Self.slimmedForRuntime(
                    kind: provider.kind,
                    payload: try Self.unsealed(rawPayload, provider: provider, ageSecretKeys: ageSecretKeys)
                )
                payload = bytes
                do {
                    try inspect(provider.kind, provider.behavior, provider.format, bytes)
                } catch {
                     
                     
                    warnings.append("\(provider.name): \(error.localizedDescription)")
                    failure = (error as? AuthoredFailure)?.text ?? .verbatim(error.localizedDescription)
                }
            } catch let refusal as MaterializeError where refusal.isAboutTheSeal {
                throw refusal
            } catch {
                 
                 
                if Task.isCancelled { throw CancellationError() }
                 
                 
                 
                if existingProxyDirectory != nil {
                    throw MaterializeError.proxyProviderUnavailable(name: provider.name, reason: error.localizedDescription)
                }
                let reason: AuthoredText
                if case ClashTVBoundedDownload.Failure.tooLarge = error {
                    reason = .verbatim(MaterializeError.tooLarge(name: provider.name).localizedDescription)
                } else {
                    reason = .verbatim(error.localizedDescription)
                }
                warnings.append("\(provider.name): \(reason.text)")
                entries.append(.init(kind: provider.kind, name: provider.name, url: provider.url,
                                     updatedAt: nil, note: .downloadFailed(reason)))
                continue
            }
            if downloaded,
               previousProvidersDirectory.flatMap({ try? Data(contentsOf: $0.appendingPathComponent(provider.path)) }) != payload {
                contentChanged = true
            }
            try payload.write(to: target, options: .atomic)
            paths[key] = published
            readPaths[key] = target.path
            if downloaded { fetchedAt[key] = Int64(now().timeIntervalSince1970) }
             
             
             
             
            entries.append(ClashTVProviderCatalog.Entry(
                kind: provider.kind,
                name: provider.name,
                url: provider.url,
                updatedAt: downloaded ? now() : reused?.updatedAt,
                note: failure.map { ClashTVProviderNote.unreadable($0) } ?? (downloaded ? nil : reused?.note)
            ))
        }
        for local in localProviders {
            entries.append(.init(kind: local.kind, name: local.name, updatedAt: nil,
                                 note: local.vehicle == "inline" ? .inline
                                    : local.notice.map { .unreadable(.verbatim($0)) }))
        }
        let catalog = ClashTVProviderCatalog(entries: entries, sourceSHA256: sourceSHA256)
         
         
         
        try catalog.write(to: candidate.stagingProvidersDirectory)
        return Outcome(paths: paths, readPaths: readPaths, warnings: warnings, catalog: catalog, fetchedAt: fetchedAt,
                       contentChanged: contentChanged)
    }

     
     
    static func notices(_ plan: RemoteResourcePlan, kind: String) -> [String: String] {
        var named: [String: String] = [:]
        for notice in plan.structuredNotices ?? [] where notice.kind == kind {
            guard let field = notice.field else { continue }
            let parts = field.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2, let dot = parts[1].lastIndex(of: ".") else { continue }
            let name = String(parts[1][..<dot])
            switch parts[0] {
            case "proxy-providers": named["proxy:\(name)"] = notice.text
            case "rule-providers": named["rule:\(name)"] = notice.text
            default: continue
            }
        }
        return named
    }

     
    static func localProviders(sourceYAML: String, plan: RemoteResourcePlan) -> [LocalProvider] {
        guard let json = try? ConfigTransforms.yamlToJSON(sourceYAML),
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [] }
        let inert = notices(plan, kind: "provider-file-inert")
        var found: [LocalProvider] = []
        for (section, kind) in [("proxy-providers", "proxy"), ("rule-providers", "rule")] {
            guard let providers = root[section] as? [String: Any] else { continue }
            for (name, value) in providers {
                guard let definition = value as? [String: Any],
                      let type = (definition["type"] as? String)?.lowercased(), type == "inline" || type == "file"
                else { continue }
                found.append(.init(kind: kind, name: name, vehicle: type, notice: inert["\(kind):\(name)"]))
            }
        }
        return found.sorted { ($0.kind, $0.name) < ($1.kind, $1.name) }
    }

     
     
     
     
     
     
     
     
     
     
    static func slimmedForRuntime(kind: String, payload: Data) -> Data {
        guard kind == "proxy" else { return payload }
        if payload.starts(with: Data(#"{"proxies":"#.utf8)) {
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let proxies = object["proxies"] as? [Any], !proxies.isEmpty,
                  let slim = try? JSONSerialization.data(
                      withJSONObject: ["proxies": proxies],
                      options: [.withoutEscapingSlashes, .sortedKeys]
                  )
            else { return payload }
            return slim
        }
        guard let text = String(data: payload, encoding: .utf8),
              let json = try? ConfigTransforms.yamlToJSON(text),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let proxies = object["proxies"] as? [Any], !proxies.isEmpty,
              let slim = try? JSONSerialization.data(
                  withJSONObject: ["proxies": proxies],
                  options: [.withoutEscapingSlashes, .sortedKeys]
              )
        else { return payload }
        return slim
    }

     
     
     
     
     
     
     
    private static func unsealed(
        _ payload: Data,
        provider: RemoteResourcePlan.Provider,
        ageSecretKeys: [String: String]
    ) throws -> Data {
        guard provider.kind == "proxy", payload.starts(with: Data(ageArmorPrefix.utf8)) else { return payload }
        guard let key = ageSecretKeys[resourceKey(for: provider)], !key.isEmpty else {
            throw MaterializeError.ageKeyMissing(name: provider.name)
        }
        var error: NSError?
        guard let plaintext = AppCore.decryptAge(payload, key, &error) else {
            throw MaterializeError.ageDecryptFailed(
                name: provider.name,
                reason: error?.localizedDescription ?? unopenablePayload.localizedForTelevision
            )
        }
        return plaintext
    }

    private static func download(
        _ provider: RemoteResourcePlan.Provider,
        session: URLSession,
        userAgent: String,
        maximumBytes: Int
    ) async throws -> Data {
        guard let url = URL(string: provider.url) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (field, values) in provider.headers {
            for value in values {
                request.addValue(value, forHTTPHeaderField: field)
            }
        }
        return try await ClashTVBoundedDownload.data(for: request, session: session, maximumBytes: maximumBytes)
    }
}
