import Clash
import ClashClientKit
import CryptoKit
import Foundation

 
 
 
 
 
 
 
 
 
 
 
 
 
 
enum PublishedPresentation {
    static let fileName = "published-presentation.json"

     
     
     
    static var largeSourceBytes: Int { NodesInventoryProjection.wholeReadBytes }

    struct Record: Codable, Equatable {
        let revision: String
        let inputs: String
    }

     
    struct Settings {
        var global: OverrideSpec
        var runtime: OverrideSpec
        var configScriptEnabled: Bool
        var configScriptBody: String
        var scripts: [ConfigScript]
        var udpFallback: String

         
        static func live() -> Settings {
            Settings(
                global: GlobalConfig.load(),
                runtime: FlClashRuntimeConfig.load(),
                configScriptEnabled: ScriptSettings.enabled(),
                configScriptBody: ScriptSettings.body(),
                scripts: ScriptLibrary.load(),
                udpFallback: String(describing: UDPFallbackSettings.policy())
            )
        }
    }

     
     
     
     
    static func buildFacts(of profile: Profile) -> Profile {
        var facts = profile
        facts.selectedMap = [:]
        facts.currentGroupName = nil
        facts.unfoldedGroups = nil
        facts.order = 0
        facts.activeRevision = nil
        facts.subscriptionInfo = nil
        facts.lastUpdatedAt = nil
        facts.subscriptionETag = nil
        facts.subscriptionLastModified = nil
        facts.providerDefinitionNotices = nil
        return facts
    }

     
     
    static func inputs(source: String, profile: Profile, settings: Settings) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
         
         
        let scripts = settings.scripts.sorted { $0.id < $1.id }
        guard let profileFacts = try? encoder.encode(buildFacts(of: profile)),
              let global = try? encoder.encode(settings.global),
              let runtime = try? encoder.encode(settings.runtime),
              let scriptLibrary = try? encoder.encode(scripts)
        else { return nil }
        var hasher = SHA256()
        func add(_ data: Data) {
            withUnsafeBytes(of: UInt64(data.count).bigEndian) { hasher.update(bufferPointer: $0) }
            hasher.update(data: data)
        }
        var text = source
        let length = text.utf8.count
        withUnsafeBytes(of: UInt64(length).bigEndian) { hasher.update(bufferPointer: $0) }
        text.withUTF8 { hasher.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        add(profileFacts)
        add(global)
        add(runtime)
        add(Data([settings.configScriptEnabled ? 1 : 0]))
        add(Data(settings.configScriptBody.utf8))
        add(scriptLibrary)
        add(Data(settings.udpFallback.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func url(profileID: String, workingDirectory: URL) -> URL {
        ProfileSourceStore.runnableURL(workingDirectory: workingDirectory, profileID: profileID)
            .deletingLastPathComponent()
            .appendingPathComponent(fileName)
    }

     
     
    static func record(_ pointer: ActiveConfigurationPointer, inputs: String?, workingDirectory: URL) {
        let file = url(profileID: pointer.profileID, workingDirectory: workingDirectory)
        guard let inputs,
              let data = try? JSONEncoder().encode(Record(revision: pointer.revision, inputs: inputs))
        else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func read(profileID: String, workingDirectory: URL) -> Record? {
        guard let data = try? Data(contentsOf: url(profileID: profileID, workingDirectory: workingDirectory)) else {
            return nil
        }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

     
     
    static func isCurrent(
        _ pointer: ActiveConfigurationPointer,
        source: String,
        profile: Profile,
        workingDirectory: URL,
        settings: Settings = .live()
    ) -> Bool {
        guard pointer.profileID == profile.id,
              let record = read(profileID: pointer.profileID, workingDirectory: workingDirectory),
              record.revision == pointer.revision,
              let now = inputs(source: source, profile: profile, settings: settings)
        else { return false }
        return record.inputs == now
    }

     
     
    static func currentText(
        of pointer: ActiveConfigurationPointer,
        store: ConfigResourceStore,
        source: String,
        profile: Profile,
        workingDirectory: URL,
        settings: Settings = .live()
    ) -> String? {
        guard isCurrent(pointer, source: source, profile: profile, workingDirectory: workingDirectory, settings: settings),
              let text = try? store.loadConfiguration(profileID: pointer.profileID, revision: pointer.revision).text
        else { return nil }
        if let library = ConfigTransforms.nodeLibraryPath(in: text),
           !FileManager.default.fileExists(atPath: library) {
            return nil
        }
        return text
    }
}

extension PublishedPresentation {
    nonisolated(unsafe) private static var verdicts: [String: Bool] = [:]
    private static let verdictLock = NSLock()

     
     
     
     
     
     
     
     
     
    static func opensWhole(_ text: String, revision: String, source: String,
                           resourceMapJSON: String, selectionsJSON: String,
                           setupContainer: URL? = AppCoreSetup.applicationContainer) -> Bool {
        if let known = verdict(for: revision) { return known }
        guard let setupContainer else { return true }
        let verdict = measuresWhole(text, source: source, resourceMapJSON: resourceMapJSON,
                                    selectionsJSON: selectionsJSON, container: setupContainer)
        verdictLock.lock()
        verdicts[revision] = verdict
        verdictLock.unlock()
        if !verdict {
            ClashLogStore.shared.append("offline pages build from the source  reason=publication \(revision) does not open whole",
                                       stream: .app, level: .warning)
        }
        return verdict
    }

     
    static func verdict(for revision: String) -> Bool? {
        verdictLock.lock()
        defer { verdictLock.unlock() }
        return verdicts[revision]
    }

    private static func measuresWhole(_ text: String, source: String, resourceMapJSON: String, selectionsJSON: String,
                                      container: URL) -> Bool {
        let written = ConfigurationSections.writesNodes(in: source)
        do {
            let summary = try AppCoreSetup.withConfiguration(container: container) { () throws -> NodeSummary in
                OfflineProxyCatalogLoader.noteOpening(text, resourceMapJSON: resourceMapJSON, selectionsJSON: selectionsJSON,
                                                      holder: "probe", key: revision(of: text))
                var error: NSError?
                guard let catalog = AppCore.openNodeCatalog(text, resourceMapJSON, selectionsJSON, &error) else {
                    throw error ?? NodePageSourceError.unavailable
                }
                defer { catalog.close() }
                return try Data(catalog.summaryJSON().utf8).decoded(NodeSummary.self)
            }
            ClashLogStore.shared.append("offline catalog probe  nodes=\(summary.nodes) sourceWritesNodes=\(written)", stream: .app)
            return summary.nodes > 0 || !written
        } catch {
            ClashLogStore.shared.append("offline catalog probe  refused=\((error as NSError).localizedDescription)",
                                       stream: .app, level: .warning)
            return false
        }
    }

    private static func revision(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func resetVerdictsForTesting() {
        verdictLock.lock()
        verdicts = [:]
        verdictLock.unlock()
    }

     
     
     
    static func textForPages(
        source: String,
        profile: Profile,
        store: ConfigResourceStore?,
        workingDirectory: URL?
    ) -> String? {
        guard source.utf8.count > largeSourceBytes, let store, let workingDirectory,
              let pointer = try? store.activeIdentity(), pointer.profileID == profile.id,
              let text = currentText(of: pointer, store: store, source: source, profile: profile,
                                     workingDirectory: workingDirectory)
        else { return nil }
         
        if verdict(for: pointer.revision) == nil {
            _ = OfflineProxyCatalogLoader.input(containerURL: workingDirectory.deletingLastPathComponent(),
                                                preferredProfileID: profile.id)
        }
        return verdict(for: pointer.revision) == false ? nil : text
    }
}
