import Combine
import ClashClientUI
import SwiftUI
import UniformTypeIdentifiers

extension ProviderValidationWarning {
     
     
     
     
     
    static func displayText(_ reason: String) -> ClashDisplayText {
        if isClientAuthored(reason) { return .copy(reason) }
        if let detail = undecryptableDetail(in: reason) { return .format(MaterializeError.undecryptableFormat, [detail]) }
        return .verbatim(reason)
    }
}

 
enum ProviderInventory {
    struct Entry: Equatable {
        let name: String
        let sizeBytes: Int?
        let updatedAt: Date?
    }

    static func scan(providersDir: URL) -> [Entry] {
        guard let names = try? FileManager.default
            .contentsOfDirectory(atPath: providersDir.path) else { return [] }
        return names.sorted()
            .filter { $0 != "providers.json" }   
            .map { name in
                let attributes = try? FileManager.default.attributesOfItem(
                    atPath: providersDir.appendingPathComponent(name).path)
                return Entry(name: name,
                             sizeBytes: (attributes?[.size] as? NSNumber)?.intValue,
                             updatedAt: attributes?[.modificationDate] as? Date)
            }
    }
}

 
 
 
 
 
 
@MainActor
final class ProvidersModel: ObservableObject {
    struct Row: Equatable, Identifiable {
        let name: String        
        let kind: String?       
        let sizeBytes: Int?
        let updatedAt: Date?
        let count: Int?
        let subscriptionInfo: SubscriptionInfo?
        let canRefresh: Bool
         
         
         
         
         
        var loadFailure: String? = nil
        var runtime: ProviderRuntimeSummary? = nil
        var id: String { name }

         
         
         
         
         
         
         
         
        var loadFailureText: ClashDisplayText? {
            loadFailure.map(ProviderValidationWarning.displayText)
        }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var activeProfile: Profile?
    @Published private(set) var busy = false
    @Published private(set) var busyProvider: String?
     
     
     
     
     
    @Published private(set) var syncingProviders: Set<String> = []
    @Published private(set) var healthCheckingProvider: String?
    @Published private(set) var runtimeLoading = false
    @Published private(set) var runtimeStatus = ""
    @Published private(set) var status = "" { didSet { statusText = nil; statusIsNotice = false } }
     
     
     
    @Published private(set) var statusText: ClashDisplayText?
     
     
    @Published private(set) var statusIsNotice = false
    @Published private(set) var lastFailure: ConfigurationFailure?
    @Published private(set) var batchReport: BatchUpdateReport?

    private let vpn: VPNController
    private let command: ClashCommandClient
    private var localRows: [Row] = []
    private var runtimeCatalog: ProviderRuntimeCatalog?
    private var runtimeTask: Task<Void, Never>?
    private var runtimeGeneration: UInt64 = 0
    private var retryOperation: RetryOperation?
    private var batchTask: Task<Void, Never>?
     
     
     
     
    private var requestedRefresh = 0
    private var honoredRefresh = 0
    private var hasLoaded = false

    private enum RetryOperation {
        case all
        case provider(String)
    }

    init(vpn: VPNController, command: ClashCommandClient) {
        self.vpn = vpn
        self.command = command
    }

    private var container: URL? {
        ClashAppIdentifiers.appGroupContainer
    }

     
     
    var providerNotices: [ProviderDefinitionMergeNotice] {
        activeProfile?.providerDefinitionNotices ?? []
    }

     
     
    func acknowledgeProviderNotices() {
        guard let container, let profile = activeProfile else { return }
        let store = ProfileStore(
            fileURL: container.appendingPathComponent("working/store/profiles.json"))
        Self.acknowledgeProviderNotices(in: store, profileID: profile.id)
        load()
    }

     
     
    static func acknowledgeProviderNotices(in store: ProfileStore, profileID: String) {
        _ = try? store.updateIfPresent(id: profileID, when: { $0.providerDefinitionNotices != nil }) {
            $0.providerDefinitionNotices = nil
        }
    }

    func load() {
        runtimeTask?.cancel()
        runtimeGeneration &+= 1
        runtimeCatalog = nil
        guard let container,
              let store = try? ConfigResourceStore(containerURL: container) else { return }
        if let dir = try? store.activeProvidersDirectory() {
            localRows = Self.rows(providersDir: dir)
        } else {
            localRows = []
        }
        rows = localRows
        let profiles = ProfileStore(
            fileURL: container.appendingPathComponent("working/store/profiles.json")).load()
         
         
         
         
         
         
         
        let activeID = (try? store.activeIdentity())?.profileID
        activeProfile = profiles.first { $0.id == activeID }
        refreshRuntimeCatalog()
        hasLoaded = true
        fireRequestedRefreshIfReady()
    }

     
    func honorRefreshRequest(_ token: Int) {
        requestedRefresh = token
        fireRequestedRefreshIfReady()
    }

    private func fireRequestedRefreshIfReady() {
        guard ProvidersRefreshRequestPolicy.fires(
            requested: requestedRefresh, honored: honoredRefresh, loaded: hasLoaded
        ) else { return }
        honoredRefresh = requestedRefresh
        refreshAll()
    }

    static func rows(providersDir: URL) -> [Row] {
        if let catalog = ProviderCatalog.load(providersDir: providersDir) {
            return catalog.entries
                .sorted { $0.name < $1.name }
                .map { entry in
                    let attributes = try? FileManager.default.attributesOfItem(
                        atPath: providersDir.appendingPathComponent(entry.path).path)
                    return Row(name: entry.name, kind: entry.kind,
                               sizeBytes: (attributes?[.size] as? NSNumber)?.intValue,
                               updatedAt: entry.lastUpdatedAt
                                   ?? attributes?[.modificationDate] as? Date,
                               count: entry.count,
                               subscriptionInfo: entry.subscriptionInfo,
                               canRefresh: true,
                               loadFailure: entry.loadFailure)
                }
        }
         
        return ProviderInventory.scan(providersDir: providersDir).map {
            Row(name: $0.name, kind: nil, sizeBytes: $0.sizeBytes,
                updatedAt: $0.updatedAt, count: nil,
                subscriptionInfo: nil, canRefresh: false)
        }
    }

     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
    nonisolated static func unreadableRuleSets(
        providersDir: URL
    ) -> [Row] {
        guard let catalog = ProviderCatalog.load(providersDir: providersDir)
        else { return [] }
        return catalog.entries
            .filter { $0.kind == "rule" && $0.loadFailure != nil }
            .sorted { $0.name < $1.name }
            .map {
                Row(name: $0.name, kind: $0.kind, sizeBytes: nil,
                    updatedAt: $0.lastUpdatedAt, count: $0.count,
                    subscriptionInfo: nil, canRefresh: true,
                    loadFailure: $0.loadFailure)
            }
    }

    static func mergingRuntime(
        _ runtime: ProviderRuntimeCatalog,
        into localRows: [Row]
    ) -> [Row] {
        localRows.map { row in
            var merged = row
            merged.runtime = runtime.summary(name: row.name, kind: row.kind)
            return merged
        }
    }

    func refreshRuntimeCatalog() {
        runtimeTask?.cancel()
        runtimeGeneration &+= 1
        let token = runtimeGeneration
        guard command.isConnected else {
            runtimeLoading = false
            runtimeCatalog = nil
            rows = localRows
            runtimeStatus = "Connect Clash to view live provider status."
            return
        }
        runtimeLoading = true
        runtimeStatus = "Loading live provider status…"
        runtimeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let catalog = try await self.command.providerRuntimeCatalog()
                guard !Task.isCancelled, token == self.runtimeGeneration else { return }
                self.runtimeCatalog = catalog
                self.rows = Self.mergingRuntime(catalog, into: self.localRows)
                self.runtimeStatus = "Live provider status is up to date."
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, token == self.runtimeGeneration else { return }
                self.runtimeCatalog = nil
                self.rows = self.localRows
                self.runtimeStatus = "Live provider status is unavailable."
            }
            guard token == self.runtimeGeneration else { return }
            self.runtimeLoading = false
            self.runtimeTask = nil
        }
    }

    func checkHealth(provider name: String) {
        guard !busy,
              healthCheckingProvider == nil,
              command.isConnected,
              rows.contains(where: {
                  $0.name == name && $0.kind?.lowercased() == "proxy"
              }) else { return }
        healthCheckingProvider = name
        runtimeStatus = "Checking proxy provider health…"
        Task { [weak self] in
            guard let self else { return }
            defer { self.healthCheckingProvider = nil }
            do {
                let provider = try await self.command.healthCheckProxyProvider(named: name)
                var catalog = self.runtimeCatalog ?? .empty
                catalog.proxyProviders[name] = provider
                self.runtimeCatalog = catalog
                self.rows = Self.mergingRuntime(catalog, into: self.localRows)
                self.runtimeStatus = "Proxy provider health check completed."
            } catch {
                self.runtimeStatus = "Proxy provider health check failed."
            }
        }
    }

    func refreshAll() {
        guard !busy, let container, let profile = activeProfile,
              let store = try? ConfigResourceStore(containerURL: container) else { return }
        let refreshable = rows.filter(\.canRefresh)
        guard !refreshable.isEmpty else {
            refreshLegacyRevision(profile: profile, store: store, container: container)
            return
        }
        batchReport = BatchUpdateReport(
            title: "Provider Sync",
            expectedCount: refreshable.count
        )
        busy = true
        clearFailure()
        status = "Refreshing providers…"
         
         
        let expected = store.activeIdentityOrNil()
        batchTask = Task { [weak self] in
            guard let self else { return }
            var published: ActiveConfigurationPointer?
             
             
             
             
             
             
            let coreFetched = await ProviderRefreshService.coreFetchedProviders(
                in: (try? store.activeProvidersDirectory()).flatMap { ProviderCatalog.load(providersDir: $0) },
                profile: profile, store: store, container: container, vpn: self.vpn)
            let byCore = refreshable.filter { coreFetched.contains($0.name) }
            let names = refreshable.map(\.name).filter { !coreFetched.contains($0) }
             
             
            self.syncingProviders = Set(names)
            var cutShort = false
            do {
                let many = try await ProviderRefreshService.publishMany(
                    names: names, profile: profile, store: store,
                    container: container, vpn: self.vpn, expectedActive: expected)
                published = many.pointer
                self.recordBatchItems(Self.publicationItems(many, names: names, cancelled: Task.isCancelled))
            } catch where Task.isCancelled && Self.isCancellation(error) {
                 
                cutShort = true
            } catch {
                for name in names { self.recordBatchFailure(error, name: name) }
            }
            self.syncingProviders = []
            let tunnelRunning = self.vpn.status == "connected" || self.vpn.status == "reasserting"
            let profileID = profile.id
            let stillInUse = { @MainActor in store.activeIdentityOrNil()?.profileID == profileID }
             
             
             
             
            let coreTargets = stillInUse() && !cutShort && !Task.isCancelled ? byCore : []
            self.syncingProviders = Set(coreTargets.map(\.name))
            let coreFailures = await ProviderRefreshService.updateByCore(
                coreTargets.map { ($0.kind ?? "rule", $0.name) }, tunnelRunning: tunnelRunning,
                stillInUse: stillInUse)
            self.syncingProviders = []
            self.recordBatchItems(Self.coreItems(coreTargets.map(\.name), outcome: coreFailures,
                                                 tunnelRunning: tunnelRunning, cancelled: Task.isCancelled))
             
            if cutShort || Task.isCancelled { self.markBatchCancelled() }
            self.busyProvider = nil
             
             
             
            if let published {
                let vpn = self.vpn
                Task { await PublishedRuntimeHandover.apply(vpn: vpn, profileID: published.profileID) }
            }
            self.busy = false
            self.batchTask = nil
            self.load()
            if let report = self.batchReport {
                self.status = report.wasCancelled
                    ? "Provider sync cancelled"
                    : "Provider sync finished"
            }
        }
    }

    func refresh(provider name: String) {
        guard !busy, let container, let profile = activeProfile,
              let store = try? ConfigResourceStore(containerURL: container) else { return }
        busy = true
        clearFailure()
        busyProvider = name
        status = "Updating \(name)…"
        statusText = .format("Updating %@…", [name])
        let before = store.activeIdentityOrNil()
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.busy = false
                self.busyProvider = nil
                self.load()
            }
            do {
                let publication = try await self.performProviderRefresh(
                    name: name,
                    profile: profile,
                    store: store,
                    container: container
                )
                await PublishedRuntimeHandover.apply(vpn: self.vpn, profileID: publication.pointer.profileID)
                 
                 
                let after = publication.pointer
                let changed = await Task.detached(priority: .userInitiated) {
                    Self.providerBytesChanged(name, store: store, before: before, after: after)
                }.value
                self.status = "\(name) updated"
                self.statusText = changed == false ? .format("%@ is up to date", [name]) : .format("%@ updated", [name])
                self.clearFailure()
            } catch PipelineError.sourceUnavailable {
                self.status = "No cached source; run “Refresh all providers” once first"
            } catch where ProfileActivationCoordinator.lostToASwitch(error) {
                 
                 
                 
                 
                 
                 
                self.status = name
                self.statusText = .format("The configuration changed meanwhile; %@ was not updated.", [name])
                self.statusIsNotice = true
                self.clearFailure()
            } catch {
                self.recordFailure(error, operation: .provider(name))
            }
        }
    }

     
     
    func refreshAllAwaiting() async {
        refreshAll()
        await batchTask?.value
    }

     
     
     
     
    var canCancelBatch: Bool { busy && batchTask != nil }

    func cancelBatchRefresh() {
        batchTask?.cancel()
    }

    func dismissBatchReport() {
        guard !busy else { return }
        batchReport = nil
    }

    func retryBatchItem(id: String) {
        guard !busy, rows.contains(where: { $0.id == id }),
              let container, let profile = activeProfile,
              let store = try? ConfigResourceStore(containerURL: container) else { return }
        busy = true
        busyProvider = id
        batchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let publication = try await self.performProviderRefresh(
                    name: id,
                    profile: profile,
                    store: store,
                    container: container
                )
                await PublishedRuntimeHandover.apply(vpn: self.vpn, profileID: publication.pointer.profileID)
                self.recordBatchItem(
                    name: id,
                    state: .updated,
                    message: "Published for complete configuration apply."
                )
            } catch is CancellationError {
                self.markBatchCancelled()
            } catch {
                self.recordBatchFailure(error, name: id)
            }
            self.busy = false
            self.busyProvider = nil
            self.batchTask = nil
            self.load()
        }
    }

    func sideLoad(provider name: String, fileURL: URL) {
        guard !busy, let container, let profile = activeProfile,
              let store = try? ConfigResourceStore(containerURL: container) else { return }
        busy = true
        clearFailure()
        busyProvider = name
        status = "Loading local file for \(name)…"
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.busy = false
                self.busyProvider = nil
                self.load()
            }
            let accessed = fileURL.startAccessingSecurityScopedResource()
            defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }
            do {
                let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                if let size = values.fileSize,
                   size > ProfileActivationCoordinator.maxProviderBytes {
                    throw DownloadError.tooLarge(size)
                }
                let data = try Data(
                    contentsOf: fileURL,
                    options: [.mappedIfSafe, .uncached]
                )
                let coordinator = try vpn.activationCoordinator(store: store, container: container)
                let publication = try await coordinator.sideLoadProvider(
                    named: name,
                    data: data,
                    profile: profile
                )
                await PublishedRuntimeHandover.apply(vpn: self.vpn, profileID: publication.pointer.profileID)
                self.status = "\(name) loaded from local file"
                self.clearFailure()
            } catch PipelineError.sourceUnavailable {
                self.status = "No cached source; activate the profile once first"
            } catch where ProfileActivationCoordinator.lostToASwitch(error) {
                self.status = ""
                self.clearFailure()
            } catch {
                self.recordFailure(error, context: .localImport, operation: nil)
            }
        }
    }

    func reportImportFailure(_ error: Error) {
        recordFailure(error, context: .localImport, operation: nil)
    }

    func retryLastFailure() {
        guard let retryOperation else { return }
        switch retryOperation {
        case .all: refreshAll()
        case .provider(let name): refresh(provider: name)
        }
    }

     
     
    func updateActiveProfile(_ profile: Profile) throws {
        guard let container else { return }
        let store = ProfileStore(
            fileURL: container.appendingPathComponent("working/store/profiles.json")
        )
         
         
         
         
        let settings = ProfileSettingsFacade()
        guard let written = try store.updateIfPresent(id: profile.id, {
            $0 = settings.applying(settings.snapshot(for: profile), to: $0)
        }) else { return }
        activeProfile = written
         
         
        NotificationCenter.default.post(name: .clashProfileEditedOutsideTheModel, object: nil,
                                        userInfo: ["profileID": profile.id])
    }

    private func clearFailure() {
        lastFailure = nil
        retryOperation = nil
    }

     
     
    nonisolated static func providerBytesChanged(_ name: String, store: ConfigResourceStore,
                                                before: ActiveConfigurationPointer?,
                                                after: ActiveConfigurationPointer) -> Bool? {
        guard let before, before.profileID == after.profileID,
              let old = store.providersDirectory(profileID: before.profileID, revision: before.revision),
              let new = store.providersDirectory(profileID: after.profileID, revision: after.revision),
              let entry = ProviderCatalog.load(providersDir: new)?.entries.first(where: { $0.name == name }),
              let previous = try? Data(contentsOf: old.appendingPathComponent(entry.path)),
              let current = try? Data(contentsOf: new.appendingPathComponent(entry.path)) else { return nil }
        return previous != current
    }

    private func performProviderRefresh(
        name: String,
        profile: Profile,
        store: ConfigResourceStore,
        container: URL
    ) async throws -> ProviderRefreshResult {
        try await ProviderRefreshService.publish(
            name: name,
            profile: profile,
            store: store,
            container: container,
            vpn: vpn
        )
    }

     
     
     
    private func refreshLegacyRevision(
        profile: Profile,
        store: ConfigResourceStore,
        container: URL
    ) {
         
         
         
        guard let expected = store.activeIdentityOrNil(), expected.profileID == profile.id else { return }
        busy = true
        clearFailure()
        batchReport = nil
        status = "Re-materializing providers…"
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.busy = false
                self.load()
            }
            do {
                let coordinator = try self.vpn.activationCoordinator(
                    store: store,
                    container: container
                )
                _ = try await coordinator.activate(
                    profile: profile,
                    sourceYAML: self.sidecarYAML(for: profile),
                    onlyIfActive: expected
                )
                await self.applyToTunnel(store: store)
                self.status = "Providers refreshed"
                self.clearFailure()
            } catch where ProfileActivationCoordinator.superseded(error)
                            || ProfileActivationCoordinator.lostToASwitch(error) {
                 
                 
                self.status = ""
                self.clearFailure()
            } catch {
                self.recordFailure(error, operation: .all)
            }
        }
    }

    private func recordBatchFailure(_ error: Error, name: String) {
        if let item = Self.failureItem(error, name: name) { recordBatchItems([item]) }
    }

     
     
     
     
    static func publicationItems(_ many: ProviderRefreshService.ManyResult, names: [String],
                                 cancelled: Bool) -> [BatchUpdateItem] {
        var items = many.published.map {
            BatchUpdateItem(id: $0, label: $0, state: .updated, message: "Published for complete configuration apply.")
        }
        for failure in many.failed where !(cancelled && isCancellation(failure.error)) {
            if let item = failureItem(failure.error, name: failure.name) { items.append(item) }
        }
        if many.superseded {
             
             
            items += names.compactMap { failureItem(ConfigResourceStoreError.activeConfigurationChanged, name: $0) }
        }
        return items
    }

     
     
    static func coreItems(_ names: [String], outcome: ProviderRefreshService.CoreUpdateOutcome,
                          tunnelRunning: Bool, cancelled: Bool) -> [BatchUpdateItem] {
        names.compactMap { name in
            if let failure = outcome.failed.first(where: { $0.name == name }) {
                if cancelled && isCancellation(failure.error) { return nil }
                 
                 
                 
                return BatchUpdateItem(id: name, label: name, state: .failed, message: failure.error.localizedDescription)
            } else if !outcome.skipped.contains(name) {
                return BatchUpdateItem(id: name, label: name, state: .updated, message: "Updated by the running core.")
            } else if !tunnelRunning {
                 
                 
                return BatchUpdateItem(id: name, label: name, state: .unchanged,
                                       message: "Updated by the core on its own schedule.")
            }
            return nil
        }
    }

     
     
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        if let many = error as? ProviderDownloadFailuresError {
            return !many.failures.isEmpty && many.failures.allSatisfy { isCancellation($0.underlying) }
        }
        return false
    }

    private static func failureItem(_ error: Error, name: String) -> BatchUpdateItem? {
        guard let failure = ConfigurationFailureClassifier.classify(
            error,
            context: .provider,
            preservesLastKnownGood: true
        ) else { return nil }
        return BatchUpdateItem(id: name, label: name, state: .failed, message: failure.message, failure: failure)
    }

    private func recordBatchItems(_ items: [BatchUpdateItem]) {
        for item in items {
            recordBatchItem(name: item.id, state: item.state, message: item.message, failure: item.failure)
        }
    }

    private func recordBatchItem(
        name: String,
        state: BatchUpdateState,
        message: String?,
        failure: ConfigurationFailure? = nil
    ) {
        guard var report = batchReport else { return }
        report.wasCancelled = false
        report.record(BatchUpdateItem(
            id: name,
            label: name,
            state: state,
            message: message,
            failure: failure
        ))
        batchReport = report
    }

    private func markBatchCancelled() {
        guard var report = batchReport else { return }
        report.wasCancelled = true
        batchReport = report
    }

    private func recordFailure(
        _ error: Error,
        context: ConfigurationFailureContext = .provider,
        operation: RetryOperation?
    ) {
        guard let failure = ConfigurationFailureClassifier.classify(
            error,
            context: context,
            preservesLastKnownGood: true
        ) else {
            clearFailure()
            return
        }
        lastFailure = failure
        retryOperation = operation
        status = failure.title
    }

     
     
     
     
     
    private func applyToTunnel(store: ConfigResourceStore) async {
        await PublishedRuntimeHandover.apply(vpn: vpn, profileID: nil)
    }

    private func sidecarYAML(for profile: Profile) -> String? {
        if case .url = profile.source { return nil }
        guard let container else { return nil }
        let sidecar = container
            .appendingPathComponent("working/store/\(profile.id)/source.yaml")
        return try? String(contentsOf: sidecar, encoding: .utf8)
    }
}

enum ProviderDisplayScope: Equatable {
    case all
    case proxy
    case rule

    var title: String {
        switch self {
        case .all: return "Providers"
        case .proxy: return "Proxy Sources"
        case .rule: return "Rule Sets"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: return "No materialized providers are available in the active revision."
        case .proxy: return "No materialized proxy sources are available in the active revision."
        case .rule: return "No materialized rule sets are available in the active revision."
        }
    }

    func filtered(_ rows: [ProvidersModel.Row]) -> [ProvidersModel.Row] {
        switch self {
        case .all:
            return rows
        case .proxy:
            return rows.filter { $0.kind?.lowercased() == "proxy" }
        case .rule:
            return rows.filter { $0.kind?.lowercased() == "rule" }
        }
    }
}

 
 
 
 
 
 
struct ProviderNoticesSection: View {
    @Environment(\.locale) private var locale
    let notices: [ProviderDefinitionMergeNotice]
    let acknowledge: () -> Void

    var body: some View {
        Section {
            ForEach(notices) { notice in
                VStack(alignment: .leading, spacing: ClashTheme.Spacing.tight) {
                    Text(verbatim: notice.provider)
                        .font(.body)
                    Text(clash: ProviderNoticeCopy.line(for: notice, locale: locale))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("providers.notice.\(notice.id)")
            }
            Button {
                acknowledge()
            } label: {
                Text("Got It")
            }
            .accessibilityIdentifier("providers.notices.gotIt")
        } header: {
             
             
             
             
             
            Label(
                "Profile URL changes touched your edits",
                systemImage: ClashSymbol.exclamationmarkTriangle.rawValue
            )
            .accessibilityIdentifier("providers.notices")
        } footer: {
            Text(clash: ProviderNoticeCopy.summary(count: notices.count))
        }
    }
}

struct ProvidersView: View {
     
     
    @Environment(\.clashProvidersRefreshRequests) private var refreshRequests
    @Environment(\.locale) private var locale
    @StateObject private var model: ProvidersModel
    @ObservedObject private var command: ClashCommandClient
    private let scope: ProviderDisplayScope
    @State private var importProvider: ProvidersModel.Row?
    @State private var isImporterPresented = false
    @State private var overridingProfile: Profile?
     
     
    @State private var editedConfiguration: EditedConfiguration?
    private let vpn: VPNController

    struct EditedConfiguration: Identifiable {
        let id: String
    }

    init(
        vpn: VPNController,
        command: ClashCommandClient,
        scope: ProviderDisplayScope = .all
    ) {
        _command = ObservedObject(wrappedValue: command)
        self.scope = scope
        self.vpn = vpn
        _model = StateObject(
            wrappedValue: ProvidersModel(vpn: vpn, command: command)
        )
    }

    var body: some View {
        ClashMacSettingsContainer {
            if let profile = model.activeProfile {
                if !model.providerNotices.isEmpty {
                    ProviderNoticesSection(notices: model.providerNotices) {
                        model.acknowledgeProviderNotices()
                    }
                }
                Section {
                     
                     
                     
                     
                     
                     
                     
                     
                    HStack(spacing: ClashTheme.Spacing.compact) {
                        Label {
                            Text(clash: .copy(
                                model.runtimeStatus.isEmpty
                                    ? "Connect Clash to view live provider status."
                                    : model.runtimeStatus
                            ))
                        } icon: {
                            Image(systemName: ClashSymbol.network.name)
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(.secondary)
                        Spacer()
                        if model.runtimeLoading {
                            ProgressView()
                        }
                    }
                    .accessibilityIdentifier("providers.runtime.status")
                    if !model.status.isEmpty {
                        if let failure = model.lastFailure {
                            ConfigurationFailureView(
                                failure: failure,
                                recover: { action in
                                    switch action {
                                    case .retry:
                                        model.retryLastFailure()
                                    case .editProfile:
#if os(iOS)
                                        editedConfiguration = model.activeProfile.map { EditedConfiguration(id: $0.id) }
#else
                                        overridingProfile = model.activeProfile
#endif
                                    case .editCredentials, .openProxyChains:
                                        overridingProfile = model.activeProfile
                                    case .viewDiagnostics:
                                        break
                                    }
                                }
                            )
                        } else {
                            ClashStatusMessage(text: model.statusText ?? .copy(model.status), kind: statusKind)
                        }
                    }
                } header: {
                    Text(clash: .format("Active profile · %@", [profile.label]))
                }
            }

            if visibleRows.isEmpty {
                Section {
                    ClashEmptyState(
                        title: "No Providers",
                        message: scope.emptyMessage,
                        symbol: .shippingbox
                    )
                    .listRowSeparator(.hidden)
                }
            } else {
                if scope != .rule {
                    providerSection(title: "Proxy Sources", rows: proxyRows)
                }
                if scope != .proxy {
                    providerSection(title: "Rule Sets", rows: ruleRows)
                }
                if scope == .all {
                    providerSection(title: "Other Providers", rows: otherRows)
                }
            }
        }
        .clashInsetGroupedListStyle()
        .clashPageTitle(.copy(scope.title))
         
         
         
         
         
        .clashToolbarUnlessInPanel {
            ToolbarItem(placement: .primaryAction) {
                 
                 
                 
                 
                 
                if model.canCancelBatch {
                    ControlGroup {
                        Button {
                            model.cancelBatchRefresh()
                        } label: {
                            Label("Cancel", systemImage: ClashSymbol.xmark.name)
                        }
                    }
                    .clashReaderControlGroupStyle()
                    .accessibilityIdentifier("providers.refresh.cancel")
                } else {
                    ControlGroup {
                        Button {
                            model.refreshAll()
                        } label: {
                            Label(
                                "Refresh all providers",
                                systemImage: ClashSymbol.arrowTriangle2Circlepath.name
                            )
                        }
                        .disabled(model.busy || model.rows.allSatisfy { !$0.canRefresh })
                    }
                    .clashReaderControlGroupStyle()
                    .accessibilityIdentifier("providers.refreshAll")
                }
            }
        }
        .refreshable { await model.refreshAllAwaiting() }
        .clashDetailPageInsets()
        .onAppear {
            model.load()
             
             
            if let refreshRequests { model.honorRefreshRequest(refreshRequests.token) }
        }
        .onReceive(
            refreshRequests?.$token.eraseToAnyPublisher()
                ?? Empty<Int, Never>().eraseToAnyPublisher()
        ) { token in
             
             
            model.honorRefreshRequest(token)
        }
        .onChange(of: command.isConnected) { _ in
            model.refreshRuntimeCatalog()
        }
        .sheet(item: $overridingProfile) { profile in
            ProfileOverrideView(profile: profile, rawYAML: nil) {
                try model.updateActiveProfile($0)
            }
            .clashModalPresentation(.page)
        }
#if os(iOS)
        .sheet(item: $editedConfiguration) { edited in
            ConfigurationEditorHost(vpn: vpn, profileID: edited.id, selections: command)
                .clashModalPresentation(.page)
        }
#endif
        .sheet(isPresented: Binding(
            get: { model.batchReport != nil },
            set: { if !$0 { model.dismissBatchReport() } }
        )) {
            Group {
                if let report = model.batchReport {
                    BatchUpdateReportView(
                        report: report,
                        isRunning: model.busy,
                        cancel: { model.cancelBatchRefresh() },
                        retry: { model.retryBatchItem(id: $0) },
                        dismiss: { model.dismissBatchReport() },
                        inFlight: model.syncingProviders.sorted()
                    )
                }
            }
            .clashModalPresentation(.page)
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let row = importProvider, let url = urls.first else { return }
                model.sideLoad(provider: row.name, fileURL: url)
            case .failure(let error):
                model.reportImportFailure(error)
            }
            importProvider = nil
        }
    }

    private var visibleRows: [ProvidersModel.Row] {
        scope.filtered(model.rows)
    }

    private var proxyRows: [ProvidersModel.Row] {
        model.rows.filter { $0.kind?.lowercased() == "proxy" }
    }

    private var ruleRows: [ProvidersModel.Row] {
        model.rows.filter { $0.kind?.lowercased() == "rule" }
    }

    private var otherRows: [ProvidersModel.Row] {
        model.rows.filter {
            guard let kind = $0.kind?.lowercased() else { return true }
            return kind != "proxy" && kind != "rule"
        }
    }

    private var statusKind: ClashStatusKind {
         
        if model.statusIsNotice { return .information }
        let normalized = model.status.lowercased()
        if normalized.contains("failed") || normalized.hasPrefix("no ") { return .error }
        if normalized.contains("updating") || normalized.contains("materializing")
            || normalized.contains("loading") { return .information }
         
         
        if normalized.contains("cancelled") { return .information }
        return .success
    }

    @ViewBuilder
    private func providerSection(title: String, rows: [ProvidersModel.Row]) -> some View {
        if !rows.isEmpty {
             
             
            Section {
                ForEach(rows) { row in
                    ProviderRow(
                        row: row,
                        status: statusLine(row),
                        isBusy: model.busyProvider == row.name
                            || model.syncingProviders.contains(row.name)
                            || model.healthCheckingProvider == row.name,
                        canCheckHealth: command.isConnected
                            && row.runtime?.healthCheckAvailable == true,
                        canConfigure: true,
                        checkHealth: { model.checkHealth(provider: row.name) },
                        sideLoad: {
                            importProvider = row
                            isImporterPresented = true
                        },
                        refresh: { model.refresh(provider: row.name) }
                    )
                    .disabled(
                        (model.busy && model.busyProvider != row.name && !model.syncingProviders.contains(row.name))
                            || (model.healthCheckingProvider != nil
                                && model.healthCheckingProvider != row.name)
                    )
                }
            } header: {
                Text(clash: .copy(title))
            }
        }
    }

    private func statusLine(_ row: ProvidersModel.Row) -> String {
        ProviderRowSummary.text(for: row, locale: locale, now: Date())
    }
}

 
 
 
 
enum ProviderRowSummary {
    static func text(for row: ProvidersModel.Row, locale: Locale, now: Date) -> String {
        var parts: [String] = []
        let isRule = row.kind?.lowercased() == "rule"
        if let count = row.runtime?.entryCount ?? row.count {
            parts.append(ClashCopy.format(isRule ? "%@ rules" : "%@ proxies", locale: locale, String(count)))
        }
        if let size = row.sizeBytes { parts.append(ByteCountFormatter.string(Int64(size))) }
        if let updatedAt = row.runtime?.updatedAt ?? row.updatedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            formatter.locale = locale
            parts.append(formatter.localizedString(for: updatedAt, relativeTo: now))
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

struct ProviderRow: View {
    let row: ProvidersModel.Row
    let status: String
    let isBusy: Bool
    let canCheckHealth: Bool
    let canConfigure: Bool
    let checkHealth: () -> Void
    let sideLoad: () -> Void
    let refresh: () -> Void

    private var isRule: Bool { row.kind?.lowercased() == "rule" }

    var body: some View {
        HStack(alignment: .top, spacing: ClashTheme.Spacing.row) {
            ClashIconWell(
                symbol: isRule ? .listBulletRectangle : .serverRack,
                tint: isRule ? .orange : .purple
            )

            VStack(alignment: .leading, spacing: ClashTheme.Spacing.tight) {
                Text(row.name)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text(status)
                    .font(ClashPlatformLayout.pageUsesSystemSettingsIdiom ? ClashMacSettingsType.value : .caption)
                    .foregroundStyle(.secondary)
                if let failure = row.loadFailureText {
                     
                     
                     
                     
                     
                    Label {
                        Text(clash: failure)
                    } icon: {
                        Image(systemName: ClashSymbol.exclamationmarkTriangle.name)
                    }
                    .font(ClashPlatformLayout.pageUsesSystemSettingsIdiom ? ClashMacSettingsType.value : .caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("providers.row.loadFailure.\(row.name)")
                }
                if !isRule, let runtime = row.runtime, let health = Self.healthText(runtime) {
                    Label {
                        Text(clash: health)
                    } icon: {
                        Image(systemName: healthSymbol(runtime).name)
                    }
                        .font(ClashPlatformLayout.pageUsesSystemSettingsIdiom ? ClashMacSettingsType.value : .caption)
                        .foregroundStyle(healthColor(runtime))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let info = row.subscriptionInfo {
                    SubscriptionInfoView(info: info)
                }
                 
                 
                 
                if let kind = row.kind,
                   !ClashPlatformLayout.pageUsesSystemSettingsIdiom {
                    ClashStatusBadge(
                        title: kind.capitalized,
                        tint: isRule ? .orange : .purple,
                        role: .category
                    )
                }
            }

            Spacer(minLength: ClashTheme.Spacing.compact)

            if isBusy {
                ProgressView()
                    .frame(
                        width: ClashClientUI.ClashTheme.Control
                            .minimumHitTarget,
                        height: ClashClientUI.ClashTheme.Control
                            .minimumHitTarget
                    )
            } else if canConfigure || (!isRule && canCheckHealth),
                      !ClashPlatformLayout.pageUsesSystemSettingsIdiom {
                 
                 
                 
                 
                 
                Menu {
                    rowActions
                } label: {
                    Image(systemName: ClashSymbol.ellipsisCircle.name)
                        .font(.title3)
                        .frame(
                            width: ClashClientUI.ClashTheme.Control
                                .minimumHitTarget,
                            height: ClashClientUI.ClashTheme.Control
                                .minimumHitTarget
                        )
                }
                .accessibilityLabel("Actions for \(row.name)")
                .accessibilityIdentifier("provider.menu.\(row.name)")
            }
        }
        .contextMenu {
             
             
             
            if !isBusy, ClashPlatformLayout.pageUsesSystemSettingsIdiom, canConfigure || (!isRule && canCheckHealth) {
                rowActions
            }
        }
        .padding(.vertical, ClashTheme.Spacing.tight)
    }

     
     
    @ViewBuilder
    private var rowActions: some View {
                if !isRule {
                    Button(action: checkHealth) {
                        Label("Check health", systemImage: ClashSymbol.waveformPathEcg.name)
                    }
                    .disabled(!canCheckHealth)
                    .accessibilityIdentifier("provider.health.\(row.name)")
                    if canConfigure { Divider() }
                }
                if canConfigure, row.canRefresh {
                    Button(action: refresh) {
                        Label("Sync provider", systemImage: ClashSymbol.arrowClockwise.name)
                    }
                    .accessibilityLabel("Refresh \(row.name)")
                    .accessibilityIdentifier("provider.refresh.\(row.name)")
                }
                if canConfigure {
                    Button(action: sideLoad) {
                        Label("Load local file", systemImage: ClashSymbol.squareAndArrowDown.name)
                    }
                    .accessibilityIdentifier("provider.sideload.\(row.name)")
                }
    }

     
     
     
    static func healthText(_ runtime: ProviderRuntimeSummary) -> ClashDisplayText? {
        guard runtime.healthCheckAvailable, runtime.entryCount > 0 else { return nil }
        return .format(
            "%@ available · %@ unavailable",
            [String(runtime.healthyCount ?? 0), String(runtime.unhealthyCount ?? 0)]
        )
    }

    private func healthSymbol(_ runtime: ProviderRuntimeSummary) -> ClashSymbol {
        guard runtime.healthCheckAvailable else { return .infoCircle }
        return (runtime.unhealthyCount ?? 0) == 0 ? .checkmarkCircleFill : .exclamationmarkTriangleFill
    }

    private func healthColor(_ runtime: ProviderRuntimeSummary) -> Color {
        guard runtime.healthCheckAvailable else { return .secondary }
        return (runtime.unhealthyCount ?? 0) == 0 ? .green : .orange
    }
}

 
 
 
 
 
 
 
struct CoreControlSessionUnavailable: LocalizedError {
     
    var locale: Locale = .current
    var errorDescription: String? {
        ClashCopy.string("The tunnel is running but its control session is not available. Try again in a moment.",
                         locale: locale)
    }
}

 
 
 
 
 
@MainActor
enum CoreProviderUpdate {
     
     
     
    static var perform: ((_ kind: String, _ name: String, _ stillInUse: @escaping @MainActor () -> Bool) async throws -> Void)?
}

enum ProviderRefreshService {
     
     
    @MainActor
    static func publish(
        name: String,
        profile: Profile,
        store: ConfigResourceStore,
        container: URL,
        vpn: VPNController
    ) async throws -> ProviderRefreshResult {
        try Task.checkCancellation()
        let coordinator = try vpn.activationCoordinator(
            store: store,
            container: container
        )
        return try await coordinator.refreshProvider(
            named: name,
            profile: profile
        )
    }

     
     
     
     
     
    struct ManyResult {
        var pointer: ActiveConfigurationPointer?
        var published: [String] = []
        var failed: [(name: String, error: Error)] = []
         
         
        var superseded = false
         
        var switched = false
    }

     
     
     
     
     
     
     
     
     
     
     
     
     
    @MainActor
    static func publishMany(
        names: [String],
        republishingAnyway: Bool = false,
        profile: Profile,
        store: ConfigResourceStore,
        container: URL,
        vpn: VPNController,
        expectedActive: ActiveConfigurationPointer?,
        downloadRound: ProviderDownloadRound = ProviderDownloadRound()
    ) async throws -> ManyResult {
        try await publishMany(
            names: names, republishingAnyway: republishingAnyway, profile: profile, store: store,
            coordinator: try vpn.activationCoordinator(store: store, container: container),
            expectedActive: expectedActive, downloadRound: downloadRound)
    }

     
    @MainActor
    static func publishMany(
        names: [String],
        republishingAnyway: Bool = false,
        profile: Profile,
        store: ConfigResourceStore,
        coordinator: ProfileActivationCoordinator,
        expectedActive: ActiveConfigurationPointer?,
        downloadRound: ProviderDownloadRound = ProviderDownloadRound()
    ) async throws -> ManyResult {
        var expected = expectedActive
        for attempt in 0..<3 {
            do {
                return try await publishMany(names: names, republishingAnyway: republishingAnyway) { remaining in
                    try await coordinator.refreshProviders(
                        named: remaining, profile: profile, expectedActive: expected,
                        downloadRound: downloadRound).pointer
                }
            } catch where ProfileActivationCoordinator.lostToASwitch(error) {
                var result = ManyResult()
                guard let now = store.activeIdentityOrNil(), now.profileID == profile.id else {
                    result.switched = true
                    return result
                }
                 
                 
                 
                guard attempt < 2 else {
                    result.superseded = true
                    return result
                }
                expected = now
            }
        }
        var result = ManyResult()
        result.superseded = true
        return result
    }

     
     
     
     
     
    static func publishMany(
        names: [String],
        republishingAnyway: Bool = false,
        publish: ([String]) async throws -> ActiveConfigurationPointer
    ) async throws -> ManyResult {
        var result = ManyResult()
        var remaining = names
        guard republishingAnyway || !remaining.isEmpty else { return result }
        while true {
            try Task.checkCancellation()
            do {
                result.pointer = try await publish(remaining)
                result.published = remaining
                return result
            } catch let failures as ProviderDownloadFailuresError {
                let named = Set(failures.failures.map(\.provider)).intersection(remaining)
                guard !named.isEmpty else { throw failures }
                for failure in failures.failures where named.contains(failure.provider) {
                    result.failed.append((failure.provider, failure.underlying))
                }
                remaining.removeAll { named.contains($0) }
            } catch let failure as ProviderValidationFailure {
                guard remaining.contains(failure.provider) else { throw failure }
                result.failed.append((failure.provider, failure.underlying))
                remaining.removeAll { $0 == failure.provider }
            }
            if remaining.isEmpty && !republishingAnyway { return result }
        }
    }

     
     
     
     
     
     
    @MainActor
     
     
    static func updateByCore(_ providers: [(kind: String, name: String)],
                             tunnelRunning: Bool, locale: Locale = .current,
                             stillInUse: @escaping @MainActor () -> Bool) async -> CoreUpdateOutcome {
        var outcome = CoreUpdateOutcome()
        guard !providers.isEmpty else { return outcome }
        guard let update = CoreProviderUpdate.perform else {
            if tunnelRunning {
                outcome.failed = providers.map { ($0.name, CoreControlSessionUnavailable(locale: locale)) }
            } else {
                outcome.skipped = Set(providers.map(\.name))
            }
            return outcome
        }
        var failures: [(name: String, error: Error)] = []
        var skipped: Set<String> = []
        await withTaskGroup(of: (String, Error?).self) { group in
            var next = 0
            func start() {
                let provider = providers[next]
                next += 1
                group.addTask { @MainActor in
                     
                     
                     
                    if Task.isCancelled { return (provider.name, CancellationError()) }
                    guard stillInUse() else { return (provider.name, ConfigResourceStoreError.activeConfigurationChanged) }
                    do { try await update(provider.kind, provider.name, stillInUse); return (provider.name, nil) }
                    catch { return (provider.name, error) }
                }
            }
            while next < min(4, providers.count) { start() }
            for await (name, error) in group {
                if let error {
                    if error is CancellationError {
                         
                        skipped.insert(name)
                    } else if (error as? ProviderRuntimeCatalogError) == .unavailable {
                        if tunnelRunning { failures.append((name, CoreControlSessionUnavailable(locale: locale))) }
                        else { skipped.insert(name) }
                    } else if ProfileActivationCoordinator.lostToASwitch(error) {
                         
                        skipped.insert(name)
                    } else {
                        failures.append((name, error))
                    }
                }
                 
                 
                if next < providers.count, !Task.isCancelled { start() }
            }
             
            skipped.formUnion(providers[next...].map(\.name))
        }
        outcome.failed = failures.sorted { $0.name < $1.name }
        outcome.skipped = skipped
        return outcome
    }

     
     
     
     
     
     
     
     
    @MainActor
    static func coreFetchedProviders(in catalog: ProviderCatalog?, profile: Profile, store: ConfigResourceStore,
                                     container: URL, vpn: VPNController) async -> Set<String> {
        if let recorded = catalog?.coreFetchedProviders { return recorded }
        return await plannedCatalog(profile: profile, store: store, container: container, vpn: vpn)?
            .coreFetchedProviders ?? []
    }

     
     
     
    @MainActor
    static func plannedCatalog(profile: Profile, store: ConfigResourceStore, container: URL,
                               vpn: VPNController) async -> ProviderCatalog? {
        guard let coordinator = try? vpn.activationCoordinator(store: store, container: container) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            try? coordinator.providerRetryCatalog(profile: profile)
        }.value
    }

     
     
    struct CoreUpdateOutcome {
        var failed: [(name: String, error: Error)] = []
        var skipped: Set<String> = []
    }

     
     
     
     
    @MainActor
    static func refresh(
        name: String,
        profile: Profile,
        store: ConfigResourceStore,
        container: URL,
        vpn: VPNController
    ) async throws {
        let publication = try await publish(name: name, profile: profile, store: store, container: container, vpn: vpn)
        await PublishedRuntimeHandover.apply(vpn: vpn, profileID: publication.pointer.profileID)
    }
}

 
 
 
 
 
 
enum PublishedRuntimeHandover {
     
     
     
    @MainActor
    @discardableResult
    static func apply(vpn: VPNController, profileID: String?) async -> TunnelApplyOutcome? {
        await vpn.applyPublished(forProfile: profileID, startsWhenDown: false)
    }

     
     
    static func hands(_ published: ActiveConfigurationPointer, forProfile profileID: String?) -> Bool {
        profileID == nil || published.profileID == profileID
    }
}
