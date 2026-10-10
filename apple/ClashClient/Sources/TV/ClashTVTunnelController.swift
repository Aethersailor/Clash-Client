import Combine
import Foundation
import NetworkExtension

 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
@MainActor
final class ClashTVTunnelController: ObservableObject {
     
     
    @Published var state: ClashTVProductState = .empty

     
     
     
     
    @Published var lastActivation: Activation?
    @Published private(set) var isApplyingIPStack = false
    let ipStackDefaults: UserDefaults

    struct Activation: Equatable {
        let subscriptionID: ClashTVSubscription.ID
        let at: Date
         
        var panelName: String? = nil
    }

    static let vpnProfileTitle = "Clash"
    static let vpnProfileDescription = "Clash"
     
     
     
     
     
    static let providerNotLaunchedMessage = String(localized: "Connection failed. Select Reinstall VPN Profile.")

     
     
     
     
     
    nonisolated static var defaultContainer: URL? {
        if let group = ClashAppIdentifiers.appGroupContainer { return group }

        return nil

    }
    private static let messageTimeout: TimeInterval = 8
     
    private static let reloadTimeout: TimeInterval = 30

    private let container: URL?
    private let session: URLSession
     
    private let autoConnect: ClashTVAutoConnect.Store
     
     
    typealias ProfileLoader = @MainActor () async throws -> [any ClashTVSystemProfile]
    typealias ProfileMaker = @MainActor () -> any ClashTVSystemProfile
     
     
     
     
    private let coordinator: ClashTVProfileCoordinator
     
     
    private var manager: (any ClashTVSystemProfile)? { coordinator.current }
    private var statusObserver: NSObjectProtocol?
    private var pollTask: Task<Void, Never>?
    typealias MessageReader = @MainActor (Data, UInt64, Bool) async throws -> Data
    private let messageReader: MessageReader?
    private let pollSleep: @MainActor () async throws -> Void
    private var presentation = ClashTVPollingPresentation(page: .configuration, active: false)
    private var presentationEpoch: UInt64 = 0
    private let observationClock: @MainActor () -> ClashTVObservation.Moment

    func updatePresentation(_ presentation: ClashTVPollingPresentation) {
        guard self.presentation != presentation else { return }
        self.presentation = presentation
        presentationEpoch &+= 1
        state.observations.waitForUpdate()
        stopPolling()
        if presentation.active {
             
            statusChanged()
            startPolling()
        }
    }
    private var startRequested = false
     
     
     
     
    private var stopRequested = false
     
     
     
     
     
    private var stopEpoch = 0
     
     
     
     
     
    private var connectTask: Task<Void, Never>?
     
    private var refreshTask: Task<Void, Never>?
     
     
     
    private var reinstallInFlight = false
     
     
    private var startGeneration = 0
    private var groupOrder: [String] = []
    private var lastKnownStatus: NEVPNStatus = .invalid
     
    private var startFailureTracker = VPNStartFailureTracker()
    private let clock: @MainActor () -> Date
    private var ipcGeneration = ClashTVIPCGeneration(active: false)
    private var observedIPCProfile: ObjectIdentifier?
    private var observedIPCSession: ObjectIdentifier?
    private var controlRevision: UInt64 = 0
    private var activeObservationGeneration: UInt64?
    private var ruleProbePointer: ActiveConfigurationPointer?
    private var ruleProbeGeneration: ClashTVIPCGeneration?
    private var nextRuleProbeAt = Date.distantPast
    private var ruleProbeBackoff: TimeInterval = 3
    private var ruleRecoveryPending = false

    private func replaceIPCGeneration(active: Bool) {
        ipcGeneration.invalidate()
        state.observations.beginGeneration()
        sweepingMembers = []
        ipcGeneration = ClashTVIPCGeneration(active: active)
    }

    init(
        container: URL? = ClashTVTunnelController.defaultContainer,
        session: URLSession = ClashTVNetwork.session,
        autoConnect: ClashTVAutoConnect.Store = ClashTVAutoConnect.Store(),
        loadProfiles: @escaping ProfileLoader = { try await NETunnelProviderManager.loadAllFromPreferences() },
        makeProfile: @escaping ProfileMaker = { NETunnelProviderManager() },
        preferencesTimeout: TimeInterval = 15,
        ipStackDefaults: UserDefaults = UserDefaults(suiteName: ClashAppIdentifiers.appGroup) ?? .standard,
        messageReader: MessageReader? = nil,
        observationClock: @escaping @MainActor () -> ClashTVObservation.Moment = { .init(date: Date()) },
        clock: @escaping @MainActor () -> Date = { Date() },
        pollSleep: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
    ) {
        self.ipStackDefaults = ipStackDefaults
        self.container = container
        self.messageReader = messageReader
        self.observationClock = observationClock
        self.clock = clock
        self.pollSleep = pollSleep
        self.session = session
        self.autoConnect = autoConnect
        self.coordinator = ClashTVProfileCoordinator(
            intent: autoConnect.isEnabled,
            persistIntent: { autoConnect.set($0) },
            load: loadProfiles,
            make: makeProfile,
            timeout: preferencesTimeout,
            ownedBy: { ClashTVTunnelController.owns($0) }
        )
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let connection = notification.object as? NEVPNConnection else { return }
            Task { @MainActor in
                guard let managed = self.manager?.vpnConnection, connection === managed else { return }
                self.statusChanged()
            }
        }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        pollTask?.cancel()
    }

     

     
     
     
     
     
     
    func prepare(subscription: ClashTVSubscription?) async {
        do {
            try await coordinator.find()
        } catch {
            report(issue: error.localizedDescription)
        }
        state.autoConnect = autoConnect.isEnabled
        showConfiguration(for: subscription)
        statusChanged()
    }

     
     
     
    func connect(subscription: ClashTVSubscription) async {
        guard connectTask == nil else { return }
        guard !isApplyingIPStack else {
             
             
             
             
             
             
            state.post(ClashTVFeedback.busy(.applying), for: .ipStack)
            return
        }
         
         
         
         
         
         
        stopRequested = false
         
         
         
        if let refreshTask { await refreshTask.value }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performConnect(subscription)
        }
        connectTask = task
        await task.value
         
         
        if connectTask == task { connectTask = nil }
    }

    private func performConnect(_ subscription: ClashTVSubscription) async {
        state.issue = nil
        state.vpnAuthorization = nil
        startGeneration += 1
        do {
            let ipStack = try IPStackSettings.load(from: ipStackDefaults)
            if needsActivation(for: subscription) {
                state.pipelinePhase = .downloading
                defer { state.pipelinePhase = nil }
                try await activate(subscription, settings: ipStack) { [weak self] phase in self?.state.pipelinePhase = phase }
            }
             
             
            if let container, let store = try? ConfigResourceStore(containerURL: container),
               let expected = try? store.activeIdentity() {
                do {
                    _ = try await ClashTVConfigPipeline(container: container, session: session, settings: ipStack).recoverRules(expected: expected)
                    loadActiveConfigurationFacts()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                     
                     
                    ClashLogStore.shared.append("tv startup rule recovery: \(error.localizedDescription)", stream: .app, level: .warning)
                }
            }
            try Task.checkCancellation()
             
             
            try await start(settings: ipStack, userInitiated: true)
        } catch ClashTVProfileCoordinator.StartError.permissionNotGranted {
            state.pipelinePhase = nil
            state.issue = nil
            state.vpnAuthorization = .notCompleted
            startRequested = false
            statusChanged()
        } catch is CancellationError {
            state.vpnAuthorization = nil
             
             
            state.pipelinePhase = nil
            ClashLogStore.shared.append("tv connect cancelled", stream: .app)
            statusChanged()
        } catch {
            state.vpnAuthorization = nil
            state.pipelinePhase = nil
            report(issue: error.localizedDescription)
             
             
             
            state.post(ClashTVFeedback.couldNotConnect(reason: error.localizedDescription), for: .connect, remembers: false)
            ClashLogStore.shared.append("tv connect failed  reason=\(error.localizedDescription)", stream: .app, level: .warning)
            statusChanged()
        }
    }

     
     
     
     
     
     
     
     
     
     
     
    func refresh(subscription: ClashTVSubscription, announces: Bool = true) async {
        guard connectTask == nil, refreshTask == nil else {
             
             
             
            if announces {
                state.beginOperation()
                state.post(ClashTVFeedback.busy(connectTask != nil ? .connecting : .updating), for: .update(subscription.id))
            }
            return
        }
        if announces { state.beginOperation() }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(subscription, announces: announces)
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

     
     
     
     
     
    func updateScript(subscription: ClashTVSubscription, isCurrent: Bool) async {
        guard connectTask == nil, refreshTask == nil else {
            state.beginOperation()
            state.post(ClashTVFeedback.busy(connectTask != nil ? .connecting : .updating), for: .script(subscription.id))
            return
        }
        state.beginOperation()
        guard let container else {
            let reason = ControllerError.appGroupUnavailable.localizedDescription
            state.refresh = .failed(subscription.id, reason)
            state.post(ClashTVFeedback.couldNotUpdateScript(subscription.title, reason: reason), for: .script(subscription.id))
            return
        }
        state.refresh = .updating(subscription.id, .downloading)
        do {
            _ = try await ClashTVConfigPipeline(container: container, session: session).updateScript(for: subscription)
            state.refresh = nil
        } catch {
            state.refresh = .failed(subscription.id, error.localizedDescription)
            state.post(ClashTVFeedback.couldNotUpdateScript(subscription.title, reason: error.localizedDescription), for: .script(subscription.id))
            ClashLogStore.shared.append("tv script update failed  reason=\(error.localizedDescription)", stream: .app, level: .warning)
            return
        }
         
         
         
        if isCurrent {
            await refresh(subscription: subscription)
        } else {
            state.post(ClashTVFeedback.scriptUpdated(subscription.title), for: .script(subscription.id))
        }
    }

    private func performRefresh(_ subscription: ClashTVSubscription, announces: Bool = true) async {
        let generation = ipcGeneration
         
         
         
         
        let running = state.isConnected ? activeConfigurationFacts() : nil
        state.refresh = .updating(subscription.id, .downloading)
        do {
            try await activate(subscription) { [weak self] phase in
                self?.state.refresh = .updating(subscription.id, phase)
            }
            state.refresh = nil
            var warning: String?
            if state.isConnected {
                warning = try await reloadOrRestart(subscription, expectedGeneration: generation)
            }
             
             
            if announces {
                state.post(warning.map { ClashTVFeedback.updatedWithWarning(subscription.title, warning: $0) }
                    ?? ClashTVFeedback.updated(subscription.title), for: .update(subscription.id))
            }
        } catch is CancellationError {
            state.refresh = nil
        } catch ControllerError.kernelRefused(let reason) {
             
             
            if let running {
                apply(facts: running.facts, catalog: running.catalog, fallbackCount: running.fallbackCount)
                await refreshStatus()
            }
            let sentence = ControllerError.kernelRefused(reason).localizedDescription
            state.refresh = .failed(subscription.id, sentence)
            updateFailed(subscription, reason: sentence, announces: announces)
            ClashLogStore.shared.append("tv update refused; the screens show the running configuration  reason=\(reason)", stream: .app, level: .warning)
        } catch {
             
             
            state.refresh = .failed(subscription.id, error.localizedDescription)
            updateFailed(subscription, reason: error.localizedDescription, announces: announces)
            ClashLogStore.shared.append("tv update failed  reason=\(error.localizedDescription)", stream: .app, level: .warning)
        }
    }

     
     
     
     
    private func updateFailed(_ subscription: ClashTVSubscription, reason: String, announces: Bool) {
        let result = ClashTVFeedback.couldNotUpdate(subscription.title, reason: reason)
        if announces {
            state.post(result, for: .update(subscription.id))
        } else {
            state.note(problem: ClashTVFeedback.spoken(result))
        }
    }

     
     
     
     
     
     
     
     
     
     
     
    @discardableResult
    func reloadOrRestart(_ subscription: ClashTVSubscription, expectedGeneration: ClashTVIPCGeneration? = nil) async throws -> String? {
        let generation = expectedGeneration ?? ipcGeneration
        controlRevision &+= 1
        state.observations.waitForUpdate()
         
         
         
        let controllerChangeSent = state.remoteControlPendingGeneration
        let reply = try await send(["cmd": "reload"], timeout: Self.reloadTimeout, expectedGeneration: generation)
        guard generation === ipcGeneration, generation.isValid else { throw ControllerError.ipcReplySuperseded }
        if Self.isOK(reply) {
            let warning = Self.committedWarning(reply)
            if let warning {
                ClashLogStore.shared.append("tv reload applied with a warning  reason=\(warning)", stream: .app, level: .warning)
                 
                 
                state.note(problem: String(localized: "The profile was applied, with a warning: \(warning)"))
            } else {
                ClashLogStore.shared.append("tv reload applied", stream: .app)
            }
             
             
            if controllerChangeSent != nil, state.remoteControlPendingGeneration == controllerChangeSent {
                state.remoteControlPendingGeneration = nil
            }
            await refreshProxies()
            await refreshStatus()
            return warning
        }
         
         
        guard case ControllerError.kernelRefused(let reason) = Self.replyError(reply) else { throw ControllerError.invalidResponse }
        if Self.errorClass(reply) == "config" {
            ClashLogStore.shared.append("tv reload refused; the running configuration stands  reason=\(reason)", stream: .app, level: .warning)
            await refreshStatus()
            throw ControllerError.kernelRefused(reason)
        }
        ClashLogStore.shared.append("tv reload refused; restarting the tunnel  reason=\(reason)", stream: .app, level: .warning)
         
         
        let epoch = stopEpoch + 1
        await disconnect()
        guard stopEpoch == epoch else { throw CancellationError() }
        try await waitUntilDown()
         
         
        guard stopEpoch == epoch else { throw CancellationError() }
         
         
         
        statusChanged()
         
         
        stopRequested = false
        do {
            try await start()
        } catch {
             
             
            if !(error is CancellationError) { report(issue: error.localizedDescription) }
            throw error
        }
        return nil
    }

     
     
     
    func disconnect() async {
        replaceIPCGeneration(active: false)
        startRequested = false
        startFailureTracker.cancelStart()
        state.vpnAuthorization = nil
        startGeneration += 1
        stopRequested = true
        stopEpoch += 1
        let disarm = coordinator.requestStop { $0.stopVPNTunnel() }
        if let connectTask {
            connectTask.cancel()
            await connectTask.value
             
             
             
             
             
            if self.connectTask == connectTask { self.connectTask = nil }
        }
         
         
        await disarm.value
        statusChanged()
    }

     
     
     
     
     
    func reinstallVPNProfile() async {
        guard connectTask == nil, refreshTask == nil, !isApplyingIPStack, !reinstallInFlight,
              !state.isConnected, state.stage != .connecting else { return }
        reinstallInFlight = true
        defer { reinstallInFlight = false }
        startFailureTracker.cancelStart()
        state.issue = nil
        state.vpnAuthorization = nil
        let epoch = stopEpoch
        do {
            let ipStack = try IPStackSettings.load(from: ipStackDefaults)
            try await coordinator.commitStart(
                replacingInstalled: true,
                configure: { try Self.configure($0, ipStack: ipStack) },
                shouldAbort: { [weak self] in
                    guard let self else { return true }
                    return self.stopEpoch != epoch
                },
                onWaiting: { [weak self] in
                    guard let self, self.stopEpoch == epoch else { return }
                    self.state.vpnAuthorization = .waiting
                }
            )
            state.vpnAuthorization = nil
             
             
            startFailureTracker.forgetInstantFailures()
            ClashLogStore.shared.append("tv vpn profile reinstalled", stream: .app)
        } catch ClashTVProfileCoordinator.StartError.permissionNotGranted {
             
             
            state.vpnAuthorization = .notCompleted
        } catch is CancellationError {
            state.vpnAuthorization = nil
            ClashLogStore.shared.append("tv vpn profile reinstall cancelled", stream: .app)
        } catch {
            state.vpnAuthorization = nil
            report(issue: error.localizedDescription)
            state.post(ClashTVFeedback.couldNotReinstall(reason: error.localizedDescription), for: .reinstall, remembers: false)
            ClashLogStore.shared.append("tv vpn profile reinstall failed  reason=\(error.localizedDescription)", stream: .app, level: .warning)
        }
        statusChanged()
    }

     
     
     
    var isStarting: Bool { connectTask != nil || state.stage == .connecting }

     
     
    @discardableResult
    func applyIPStack(_ next: IPStackSettings) async throws -> Bool {
        guard !isApplyingIPStack, connectTask == nil, refreshTask == nil,
              state.stage != .connecting, state.stage != .disconnecting else {
            throw IPStackSettingsApplicationError.operationInProgress
        }
        guard try next != IPStackSettings.load(from: ipStackDefaults) else { return false }
        isApplyingIPStack = true
        defer { isApplyingIPStack = false }
        let epoch = stopEpoch
        try await coordinator.applyIPStack(next, defaults: ipStackDefaults)
        guard stopEpoch == epoch, manager?.status == .connected || manager?.status == .reasserting else { return false }
        do {
            state.issue = nil
            startRequested = false
            stopRequested = true
            replaceIPCGeneration(active: false)
            await coordinator.stop { $0.stopVPNTunnel() }
            try await waitUntilDown()
            guard stopEpoch == epoch else { throw CancellationError() }
             
            statusChanged()
            stopRequested = false
        } catch {
             
             
             
            if error is CancellationError || stopEpoch != epoch { throw CancellationError() }
            throw ControllerError.ipStackStopUnanswered(error.localizedDescription)
        }
        do {
            try await start(settings: next)
            return true
        } catch {
            if error is CancellationError || stopEpoch != epoch { throw CancellationError() }
             
             
            report(issue: error.localizedDescription)
            throw ControllerError.ipStackRestartFailed(error.localizedDescription)
        }
    }

     
     
     
     
     
     
     
    func setAutoConnect(_ wanted: Bool) async {
        state.beginOperation()
        await coordinator.setWanted(wanted) { [weak self] outcome, wish in
            guard let self else { return }
             
             
            switch outcome {
            case .saved, .noProfile:
                self.state.autoConnect = wish
                self.state.autoConnectIssue = nil
            case .indeterminate(let error):
                 
                 
                 
                self.state.autoConnect = wish
                self.state.autoConnectIssue = Self.saveIndeterminate(error)
                self.state.post(ClashTVFeedback.autoConnectUnconfirmed(reason: Self.saveIndeterminate(error)), for: .autoConnect)
            case .refused(let error):
                 
                self.state.autoConnect = self.autoConnect.isEnabled
                self.state.autoConnectIssue = Self.saveRefused(error)
                self.state.post(ClashTVFeedback.autoConnectNotSaved(reason: Self.saveRefused(error)), for: .autoConnect)
            case .loadFailed(let error):
                 
                self.state.autoConnect = self.autoConnect.isEnabled
                self.state.autoConnectIssue = Self.saveRefused(error)
                self.state.post(ClashTVFeedback.autoConnectNotSaved(reason: Self.saveRefused(error)), for: .autoConnect)
            case .superseded:
                 
                 
                break
            }
        }
    }

     
     
     
     
    func subscriptionChanged(to subscription: ClashTVSubscription) async {
        let busy = connectTask != nil || state.isConnected || state.stage == .connecting
        guard busy else {
            showConfiguration(for: subscription)
            return
        }
        await disconnect()
        let epoch = stopEpoch
        do {
            try await waitUntilDown()
        } catch {
             
             
             
            state.post(ClashTVFeedback.couldNotSwitchProfile(to: subscription.title, reason: error.localizedDescription),
                       for: .use)
            return
        }
         
         
        guard stopEpoch == epoch else {
            showConfiguration(for: subscription)
            return
        }
        await connect(subscription: subscription)
    }



     

     
     
     
     
     
    func sendProxyShare(_ message: [String: Any]) async throws -> Data {
        try await send(message)
    }

     
     
     
     
     
    func remoteControlStatus() async -> ClashTVTunnelAnswer {
         
         
         
        var waited = 0
        while isStarting, waited < 60, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waited += 1
        }
        guard state.isConnected else { return .notRunning }
        do {
            return .status(String(decoding: try await send(["cmd": "remoteControl"]), as: UTF8.self))
        } catch {
            return .unanswered(error.localizedDescription)
        }
    }

    func setMode(_ mode: ClashTVOutboundMode) async {
        state.beginOperation()
        guard state.isConnected else {
            state.outboundMode = mode
            state.observations.mode.selectLocally()
            return
        }
        let generation = ipcGeneration
        controlRevision &+= 1
        let revision = controlRevision
        do {
            state.observations.mode.waitForUpdate()
            let reply = try await send(["cmd": "setMode", "mode": mode.kernelToken], expectedGeneration: generation)
            guard generation.isValid, revision == controlRevision else { return }
            guard Self.isOK(reply) else { throw Self.replyError(reply) }
            state.outboundMode = mode
            state.observations.mode.acknowledgeOperation(at: observationClock().date)
        } catch {
            ClashLogStore.shared.append("tv setMode outcome  reason=\(error.localizedDescription)", stream: .app, level: .warning)
            guard generation.isValid, revision == controlRevision else { return }
             
             
             
            state.post(ClashTVFeedback.couldNotChangeMode(reason: error.localizedDescription), for: .mode)
        }
    }

    func pin(member: String, group: String) async {
        state.beginOperation()
        guard state.isConnected else {
            state.pin(member: member, in: group)
            return
        }
        let generation = ipcGeneration
        controlRevision &+= 1
        let revision = controlRevision
        let epoch = presentationEpoch
        do {
            state.observations.proxies.waitForUpdate()
            let reply = try await send(["cmd": "select", "group": group, "name": member], expectedGeneration: generation)
            guard generation.isValid, revision == controlRevision else { return }
            guard Self.isOK(reply) else { throw Self.replyError(reply) }
             
            if presentation.active && presentationEpoch == epoch {
                await refreshProxies()
            }
        } catch {
            ClashLogStore.shared.append("tv pin outcome  reason=\(error.localizedDescription)", stream: .app, level: .warning)
            guard generation.isValid, revision == controlRevision else { return }
            state.post(ClashTVFeedback.couldNotUse(member, reason: error.localizedDescription), for: .pin)
        }
    }

     
     
     
     
    func unpin(group: String) async {
        state.beginOperation()
        guard state.isConnected else {
            state.unpin(group: group)
            return
        }
        let generation = ipcGeneration
        controlRevision &+= 1
        let revision = controlRevision
        let epoch = presentationEpoch
        do {
            state.observations.proxies.waitForUpdate()
            let reply = try await send(["cmd": "unfix", "group": group], expectedGeneration: generation)
            guard generation.isValid, revision == controlRevision else { return }
            guard Self.isOK(reply) else { throw Self.replyError(reply) }
            if presentation.active && presentationEpoch == epoch {
                await refreshProxies()
            }
        } catch {
            ClashLogStore.shared.append("tv unpin outcome  reason=\(error.localizedDescription)", stream: .app, level: .warning)
            guard generation.isValid, revision == controlRevision else { return }
            state.post(ClashTVFeedback.couldNotUnfix(group, reason: error.localizedDescription), for: .unpin)
        }
    }

     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
    func testAll(group: ClashProxyGroupSnapshot) async {
         
         
         
         
         
         
        ClashLogStore.shared.append(
            "url test sweep requested  group=\(group.name) members=\(group.members.count) "
                + "connected=\(state.isConnected) stage=\(state.stage) busy=\(!sweepingMembers.isEmpty)",
            stream: .app
        )
        guard state.isConnected else {
             
             
            state.beginOperation()
            state.post(isStarting ? ClashTVFeedback.busy(.connecting) : ClashTVFeedback.connectToTest, for: .test)
            return
        }
        state.beginOperation()
         
         
        guard sweepingMembers.isEmpty else { return }
        let generation = ipcGeneration
         
         
         
         
        let probes = ClashTVNodesScreen.sweepProbes(of: group, state: state)
        let previousLatency = probes.reduce(into: [String: ClashProxyLatencyState]()) {
            $0[$1] = state.latency[$1]
        }
        sweepingMembers = Set(probes)
        defer {
            if generation === ipcGeneration {
                for name in probes where state.latency[name] == .testing {
                    state.latency[name] = previousLatency[name] ?? .untested
                }
                sweepingMembers = []
            }
        }
        ClashTVNodesScreen.beginTesting(group, state: &state)
         
         
         
         
         
         
         
         
         
        var measured = 0
        for name in probes {
            guard generation.isValid else { return }
            do {
                let reply = try await send(["cmd": "urltest", "name": name], expectedGeneration: generation)
                guard generation.isValid else { return }
                let delay = (try? ClashTVKernelSnapshots.urlTestDelay(from: reply)) ?? -1
                if delay > 0 { measured += 1 }
                ClashTVNodesScreen.record(delay: delay, for: name, state: &state)
            } catch {
                ClashLogStore.shared.append("tv url test sweep ended  reason=\(error.localizedDescription)", stream: .app, level: .warning)
                guard generation.isValid else { return }
                state.latency[name] = .failed
                state.post(ClashTVFeedback.testStopped(reason: error.localizedDescription), for: .test)
                return
            }
        }
        ClashLogStore.shared.append(
            "url test sweep done  group=\(group.name) measured=\(measured) of \(probes.count)",
            stream: .app
        )
    }

     
     
     
     
     
    func testOne(member: ClashProxyMemberSnapshot) async {
         
         
         
        guard state.isConnected else {
            state.beginOperation()
            state.post(isStarting ? ClashTVFeedback.busy(.connecting) : ClashTVFeedback.connectToTest, for: .test)
            return
        }
        state.beginOperation()
        guard let name = ClashTVNodesScreen.probeName(for: member, state: state),
              !sweepingMembers.contains(name)
        else { return }
        let generation = ipcGeneration
        sweepingMembers.insert(name)
        defer { if generation === ipcGeneration { sweepingMembers.remove(name) } }
        state.latency[name] = .testing
        do {
            let reply = try await send(["cmd": "urltest", "name": name], expectedGeneration: generation)
            guard generation.isValid else { return }
            let delay = (try? ClashTVKernelSnapshots.urlTestDelay(from: reply)) ?? -1
            ClashTVNodesScreen.record(delay: delay, for: name, state: &state)
            ClashLogStore.shared.append("url test one  node=\(name) member=\(member.name) delay=\(delay)", stream: .app)
        } catch {
            ClashLogStore.shared.append("tv url test ended  reason=\(error.localizedDescription)", stream: .app, level: .warning)
            guard generation.isValid else { return }
            state.latency[name] = .failed
            state.post(ClashTVFeedback.testStopped(reason: error.localizedDescription), for: .test)
        }
    }

     
     
     
     
     
     
    private var sweepingMembers: Set<String> = []

     

     
     
    var iCloudRestore: ClashTVICloudRestore? {
        get { injectedICloudRestore ?? container.map { ClashTVICloudRestore(container: $0) } }
        set { injectedICloudRestore = newValue }
    }
    private var injectedICloudRestore: ClashTVICloudRestore?

     
     
     
     
    func refreshRestoredProfilesIfNewer(store: ClashTVSubscriptionStore) async -> ClashTVSubscriptionStore? {
        guard let service = iCloudRestore, !store.followingAutoBackup.isEmpty else { return nil }
        var working = store
        let result: Result<ClashTVSubscriptionStore?, Error>
        do {
            let changed = try await service.refreshIfNewer(store: &working)
            result = .success(changed ? working : nil)
        } catch {
            result = .failure(error)
        }
        switch result {
        case .success(let refreshed):
            if refreshed != nil {
                ClashLogStore.shared.append("tv icloud refresh applied", stream: .app)
            }
            return refreshed
        case .failure(let error):
            ClashLogStore.shared.append("tv icloud refresh failed  reason=\(error.localizedDescription)", stream: .app, level: .warning)
            return nil
        }
    }

     
    func probeICloudForWelcome() async {
        guard let service = iCloudRestore else { return }
        let availability = await ClashTVICloudRestore.availability(locator: service.locator())
        state.iCloudRestoreLine = ClashTVICloudRestorePresentation.welcomeLine(availability)
    }

     
     
    func restoredDocumentIsNewerThanLastActivation(_ subscription: ClashTVSubscription) -> Bool {
        guard let at = subscription.restored?.exportedAt, let last = lastActivation,
              last.subscriptionID == subscription.id else { return false }
        return at > last.at
    }

     
    func noteActivated(_ subscription: ClashTVSubscription, at date: Date) {
        lastActivation = Activation(subscriptionID: subscription.id, at: date)
    }

    private func needsActivation(for subscription: ClashTVSubscription) -> Bool {
        if restoredDocumentIsNewerThanLastActivation(subscription) { return true }
        guard let container, let store = try? ConfigResourceStore(containerURL: container),
              let pointer = try? store.activePointer()
        else { return true }
        return pointer.profileID != ClashTVConfigPipeline.profileID(for: subscription)
    }

     
     
     
    private func showConfiguration(for subscription: ClashTVSubscription?) {
        if let subscription, !needsActivation(for: subscription) {
            loadActiveConfigurationFacts()
        } else {
            clearConfigurationFacts()
        }
    }

    private func clearConfigurationFacts() {
        guard !state.isConnected else { return }
        controlRevision &+= 1
        state.observations.proxies = .init()
        state.observations.mode = .init()
        groupOrder = []
        state.rules = []
        state.ruleCount = 0
        state.dnsEnhancedMode = ""
        state.dnsNameservers = []
        state.dnsFallback = []
        state.dnsDefaultNameservers = []
        state.groupCount = 0
        state.ruleProvidersTotal = 0
        state.ruleProvidersLoaded = 0
        state.proxyGroups = []
        state.hiddenProxyGroups = []
        state.nodeCount = 0
        state.nodeGroup = ""
        state.nodeName = ""
    }

     
     
     
     
    private func activate(_ subscription: ClashTVSubscription, settings: IPStackSettings? = nil, report: @escaping @MainActor (ClashTVConfigPipeline.Phase) -> Void) async throws {
        guard let container else { throw ControllerError.appGroupUnavailable }
        let pipeline = ClashTVConfigPipeline(container: container, session: session, settings: settings)
        let activation = try await pipeline.activate(subscription: subscription) { phase in
            Task { @MainActor in report(phase) }
        }
        for warning in activation.warnings {
            ClashLogStore.shared.append("provider warning  \(warning)", stream: .app, level: .warning)
        }
        apply(facts: try ClashTVConfigFacts(yaml: activation.finalYAML), catalog: activation.catalog)
        lastActivation = Activation(subscriptionID: subscription.id, at: Date(), panelName: activation.panelName)
    }

     
     
     
     
    private func loadActiveConfigurationFacts() {
        guard let active = activeConfigurationFacts() else { return }
        apply(facts: active.facts, catalog: active.catalog, fallbackCount: active.fallbackCount)
    }

     
     
    private func activeConfigurationFacts() -> (facts: ClashTVConfigFacts, catalog: ClashTVProviderCatalog, fallbackCount: Int)? {
        guard let container, let store = try? ConfigResourceStore(containerURL: container),
              let current = try? store.loadCurrent(), let yaml = current.text,
              let facts = try? ClashTVConfigFacts(yaml: yaml)
        else { return nil }
         
         
         
         
         
         
        let directory = try? store.activeProvidersDirectory()
        let catalog = directory.flatMap { ClashTVProviderCatalog.read(from: $0) }
        let files = directory
            .flatMap { try? FileManager.default.subpathsOfDirectory(atPath: $0.path) } ?? []
        return (facts, catalog ?? ClashTVProviderCatalog(entries: []), ClashTVProviderCatalog.providerFileCount(in: files))
    }

     
     
     
     
     
     
    private func report(issue: String) {
        state.issue = issue
        state.note(problem: issue)
    }

    private func apply(facts: ClashTVConfigFacts, catalog: ClashTVProviderCatalog, fallbackCount: Int? = nil) {
        controlRevision &+= 1
        state.observations.waitForUpdate()
        state.observations.mode.useConfiguration()
        groupOrder = facts.proxyGroupNames
        state.rules = facts.rules
        state.ruleCount = facts.rules.count
        state.dnsEnhancedMode = facts.dnsEnhancedMode
        state.dnsNameservers = facts.dnsNameservers
        state.dnsFallback = facts.dnsFallback
        state.dnsDefaultNameservers = facts.dnsDefaultNameservers
        state.groupCount = facts.proxyGroupNames.count
        state.easyTierNodeNames = facts.easyTierNodeNames
        state.outboundMode = ClashTVOutboundMode(rawValue: facts.mode) ?? .rule
        state.geodataSource = "Bundled"
        state.providers = catalog.entries
        let total = catalog.entries.isEmpty ? (fallbackCount ?? 0) : catalog.entries.count
        state.ruleProvidersTotal = total
        state.ruleProvidersLoaded = catalog.entries.isEmpty ? total : catalog.readyCount
         
         
         
         
         
        if !state.isConnected {
            state.observations.proxies.useConfiguration()
            state.proxyGroups = facts.proxyGroups
             
             
            state.hiddenProxyGroups = []
            state.nodeCount = facts.nodeCount
            if let first = facts.proxyGroups.first {
                state.nodeGroup = first.name
                state.nodeName = first.members.first?.name ?? ""
            }
        }
    }

     

    private func start(settings: IPStackSettings? = nil, userInitiated: Bool = false) async throws {
         
         
         
         
         
         
        let epoch = stopEpoch
        let ipStackSnapshot = try settings ?? IPStackSettings.load(from: ipStackDefaults)
        if let container {
            try AppCoreSetup.ensure(container: container, settings: ipStackSnapshot)
        }
        try await coordinator.commitStart(
            configure: { try Self.configure($0, ipStack: ipStackSnapshot) },
            shouldAbort: { [weak self] in
                guard let self else { return true }
                return self.stopEpoch != epoch
            },
            onWaiting: { [weak self] in
                guard let self, self.stopEpoch == epoch else { return }
                self.state.vpnAuthorization = .waiting
            }
        )
         
         
         
        if stopEpoch != epoch || Task.isCancelled { throw CancellationError() }
        guard let profile = coordinator.current else { throw ControllerError.tunnelDidNotStart }
        replaceIPCGeneration(active: false)
        state.vpnAuthorization = nil
        startRequested = true
        startGeneration += 1
         
         
        startFailureTracker.beginStart(at: clock())
        do {
            try profile.startVPNTunnel(userInitiated: userInitiated)
        } catch {
            startFailureTracker.cancelStart()
            throw error
        }
        ClashLogStore.shared.append("tv vpn start requested", stream: .app)
         
         
         
         
        state.stage = .connecting
    }

     
     
     
     
    private static func configure(_ profile: any ClashTVSystemProfile, ipStack: IPStackSettings) throws {
        let tunnelProtocol = (profile.protocolConfiguration?.copy() as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = ClashAppIdentifiers.tvPacketTunnelExtensionBundleID
        tunnelProtocol.serverAddress = Self.vpnProfileDescription
        tunnelProtocol.providerConfiguration = try ipStack.applying(
            to: tunnelProtocol.providerConfiguration
        )
        profile.protocolConfiguration = tunnelProtocol
        profile.localizedDescription = Self.vpnProfileTitle
        profile.isEnabled = true
    }

    private static func owns(_ manager: any ClashTVSystemProfile) -> Bool {
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
            == ClashAppIdentifiers.tvPacketTunnelExtensionBundleID
    }

     
     
     
     
     
    static func dropMessage(for error: NSError, providerLooksUnlaunched: Bool) -> String {
        if error.domain == NEVPNConnectionErrorDomain, error.code == 12, providerLooksUnlaunched {
            return providerNotLaunchedMessage
        }
        return error.localizedDescription
    }


     
     
    static func saveRefused(_ error: Error) -> String {
        String(localized: "The system did not take the change — the switch is back where it was.") + " " + error.localizedDescription
    }

     
     
    static func saveIndeterminate(_ error: Error) -> String {
        String(localized: "The system has not answered yet — the change may still take. The switch shows what you asked for; the next Connect applies it again.") + " " + error.localizedDescription
    }

     
     
     
    private func waitUntilDown() async throws {
         
        for _ in 0..<100 where (manager?.status ?? .disconnected) != .disconnected {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard (manager?.status ?? .disconnected) == .disconnected else {
            throw ControllerError.systemTimedOut
        }
    }

     
     
     
    func statusChanged() {
        let status = manager?.status ?? .invalid
         
         
        _ = startFailureTracker.statusDidChange(to: status, at: clock())
        let previous = lastKnownStatus
        let active = status == .connected || status == .reasserting
        let previouslyActive = previous == .connected || previous == .reasserting
        let profileID = manager.map { ObjectIdentifier($0) }
        let sessionID = manager?.vpnConnection.map { ObjectIdentifier($0) }
        let runtimeIdentityChanged = profileID != observedIPCProfile || sessionID != observedIPCSession
        if active != previouslyActive || runtimeIdentityChanged {
            replaceIPCGeneration(active: active)
            observedIPCProfile = profileID
            observedIPCSession = sessionID
        }
        if active {
             
            if activeObservationGeneration == nil || runtimeIdentityChanged {
                activeObservationGeneration = state.observations.generation
            }
        } else if status == .disconnected || status == .invalid, let ended = activeObservationGeneration {
            state.observations.lastEndedGeneration = ended
            activeObservationGeneration = nil
        }
        lastKnownStatus = status
        switch status {
        case .connected, .reasserting:
            if state.stage != .connected {
                state.stage = .connected
                state.connectedSince = Date()
                state.issue = nil
                 
                 
                state.settle(.connect)
                startRequested = false
                startPolling()
            }
        case .connecting:
            stopPolling()
            state.stage = .connecting
        case .disconnecting:
            stopPolling()
            state.stage = .disconnecting
             
             
            state.remoteControlPendingGeneration = nil
        case .disconnected, .invalid:
            let wasUp = state.stage == .connected || state.stage == .disconnecting
            state.stage = .disconnected
            state.remoteControlPendingGeneration = nil
            stopPolling()
            state.connectedSince = nil
            state.downloadBytesPerSecond = 0
            state.uploadBytesPerSecond = 0
            state.connections = []
            state.connectionCount = 0
             
             
             
             
            let startNeverCameUp = startRequested && !wasUp
                && (previous == .connecting || previous == .disconnected || previous == .invalid)
            let droppedWhileUp = wasUp && !stopRequested
            if startNeverCameUp || droppedWhileUp {
                startRequested = false
                explainDrop(unexpectedWhileUp: droppedWhileUp)
            }
            stopRequested = false
        @unknown default:
            state.stage = .disconnected
        }
    }

    private func explainDrop(unexpectedWhileUp: Bool) {
        let fallback = unexpectedWhileUp
            ? ControllerError.tunnelStopped.localizedDescription
            : ControllerError.tunnelDidNotStart.localizedDescription
        guard let profile = manager else {
            sayDrop(fallback, unexpectedWhileUp: unexpectedWhileUp)
            return
        }
        let generation = startGeneration
         
         
        let providerLooksUnlaunched = startFailureTracker.providerLooksUnlaunched
        Task { @MainActor [weak self] in
            let error = await profile.lastDisconnectError()
            guard let self else { return }
             
             
            guard self.startGeneration == generation, self.state.stage == .disconnected,
                  self.state.issue == nil, self.state.vpnAuthorization == nil else { return }
            if let error {
                self.sayDrop(Self.dropMessage(for: error as NSError, providerLooksUnlaunched: providerLooksUnlaunched),
                             unexpectedWhileUp: unexpectedWhileUp)
            } else {
                self.sayDrop(fallback, unexpectedWhileUp: unexpectedWhileUp)
            }
        }
    }

     
     
     
     
    private func sayDrop(_ sentence: String, unexpectedWhileUp: Bool) {
        report(issue: sentence)
        state.post(unexpectedWhileUp ? ClashTVFeedback.disconnected(reason: sentence)
                                     : ClashTVFeedback.couldNotConnect(reason: sentence),
                   for: .connect, remembers: false)
    }

     

    private func startPolling() {
        guard pollTask == nil, presentation.active, state.isConnected else { return }
        let page = presentation.page
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self, self.state.isConnected else { return }
                for command in page.commands(tick: tick) {
                    guard !Task.isCancelled else { return }
                    switch command {
                    case .traffic: await self.refreshTraffic()
                    case .proxies: await self.refreshProxies(cancellableRead: true)
                    case .connections: await self.refreshConnections()
                    case .status: await self.refreshStatus(cancellableRead: true)
                    }
                }
                tick = (tick + 1) % 3
                do { try await self.pollSleep() } catch { return }
            }
        }
    }

     
     
    private var acceptsKernelReplies: Bool {
        state.isConnected && !Task.isCancelled
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }


     
    private struct ReadContext {
        let generation: ClashTVIPCGeneration
        let presentationEpoch: UInt64
        let controlRevision: UInt64
    }

    private func readContext() -> ReadContext {
        .init(generation: ipcGeneration, presentationEpoch: presentationEpoch, controlRevision: controlRevision)
    }

    private func accepts(_ context: ReadContext) -> Bool {
        acceptsKernelReplies && context.generation === ipcGeneration && context.generation.isValid
            && context.presentationEpoch == presentationEpoch && context.controlRevision == controlRevision
    }

    private func readFailed(_ error: Error, context: ReadContext,
                            fields: [WritableKeyPath<ClashTVControlObservations, ClashTVObservation>]) {
        guard accepts(context), !(error is CancellationError) else { return }
        let kind: ClashTVObservation.FailureKind
        if let error = error as? ControllerError {
            switch error {
            case .ipcReplySuperseded: return
            case .ipcNotSent: kind = .notSent
            case .ipcResultUnknown: kind = .resultUnknown
            case .invalidResponse: kind = .invalidReply
            default: kind = .readFailed
            }
        } else {
            if let decoding = error as? ClashTVKernelSnapshots.DecodingError {
                switch decoding {
                case .kernelError: kind = .readFailed
                case .notAnObject: kind = .invalidReply
                }
            } else { kind = .readFailed }
        }
        let failure = ClashTVObservation.Failure(kind: kind, message: error.localizedDescription)
        for field in fields { state.observations[keyPath: field].fail(failure) }
    }

    private func refreshTraffic() async {
        let context = readContext()
        do {
            let reply = try await send(["cmd": "traffic"], timeout: 2, cancellableRead: true)
            let traffic = try ClashTVKernelSnapshots.traffic(from: reply)
            guard accepts(context) else { return }
            let moment = observationClock()
            if traffic.hasRates {
                state.downloadBytesPerSecond = traffic.down
                state.uploadBytesPerSecond = traffic.up
                state.observations.traffic.accept(moment)
            } else {
                state.observations.traffic.fail(.init(kind: .invalidReply, message: String(localized: "Valid traffic rates were not included in the reply.")))
            }
            if traffic.hasTotals {
                state.sessionBytes = traffic.downTotal + traffic.upTotal
                state.observations.totals.accept(moment)
            } else {
                state.observations.totals.fail(.init(kind: .invalidReply, message: String(localized: "Valid session totals were not included in the reply.")))
            }
            if traffic.memory > 0 {
                state.memoryBytes = traffic.memory
                state.observations.memory.accept(moment)
            } else {
                state.observations.memory.fail(.init(kind: .invalidReply, message: String(localized: "A valid memory sample was not included in the reply.")))
            }
        } catch {
            readFailed(error, context: context, fields: [\.traffic, \.totals, \.memory])
        }
    }

    func refreshProxies(cancellableRead: Bool = false) async {
        let context = readContext()
        do {
            let reply = try await send(["cmd": "proxies"], cancellableRead: cancellableRead)
            let decoded = try ClashTVKernelSnapshots.proxies(from: reply, groupOrder: groupOrder)
            guard accepts(context) else { return }
            state.proxyGroups = decoded.groups
            state.hiddenProxyGroups = decoded.hiddenGroups
            state.latency = ClashTVNodesScreen.merge(
                polled: decoded.latency, over: state.latency, sweeping: sweepingMembers
            )
            state.nodeCount = decoded.nodeCount
             
             
            if !decoded.easyTierPlaceholders.isEmpty { state.easyTierNodeNames.formUnion(decoded.easyTierPlaceholders) }
            state.groupCount = decoded.groups.filter { $0.name != "GLOBAL" }.count
            let root = state.outboundMode == .global
                ? decoded.groups.first { $0.name == "GLOBAL" }
                : decoded.groups.first { $0.name != "GLOBAL" }
            if let root {
                state.nodeGroup = root.name
                state.nodeName = Self.leaf(of: root, in: decoded.groups) ?? root.currentSelection ?? ""
            } else {
                state.nodeName = ""
                state.nodeGroup = ""
            }
            state.observations.proxies.accept(observationClock())
        } catch {
            readFailed(error, context: context, fields: [\.proxies])
        }
    }

    private static func leaf(of group: ClashProxyGroupSnapshot, in groups: [ClashProxyGroupSnapshot], depth: Int = 0) -> String? {
        guard depth < 8, let selection = group.currentSelection else { return nil }
        if let next = groups.first(where: { $0.name == selection }) {
            return leaf(of: next, in: groups, depth: depth + 1) ?? selection
        }
        return selection
    }

    private func refreshConnections() async {
        let context = readContext()
        do {
            let reply = try await send(["cmd": "connections"], cancellableRead: true)
            let read = try ClashTVKernelSnapshots.connectionRead(from: reply)
            guard accepts(context) else { return }
            guard read.isComplete else {
                state.observations.connections.fail(.init(kind: .invalidReply, message: String(localized: "The connection list was incomplete.")))
                return
            }
            state.connections = read.rows
            state.connectionCount = read.rows.count
            state.observations.connections.accept(observationClock())
        } catch {
            readFailed(error, context: context, fields: [\.connections])
        }
    }

    private func refreshStatus(cancellableRead: Bool = false) async {
        let context = readContext()
        do {
            let reply = try await send(["cmd": "status"], cancellableRead: cancellableRead)
            let status = try ClashTVKernelSnapshots.status(from: reply)
            guard let mode = ClashTVOutboundMode(rawValue: status.mode.lowercased()) else {
                throw ClashTVKernelSnapshots.DecodingError.notAnObject("mode")
            }
            guard accepts(context) else { return }
            state.outboundMode = mode
            state.observations.mode.accept(observationClock())
            await refreshRuleProviders(force: false)
        } catch {
            readFailed(error, context: context, fields: [\.mode])
        }
    }

     
    func refreshRuleProviders(force: Bool = true, now: Date = Date()) async {
        let context = readContext()
        guard accepts(context), let container,
              let store = try? ConfigResourceStore(containerURL: container),
              let expected = try? store.activeIdentity() else { return }
        let newIdentity = ruleProbePointer != expected || ruleProbeGeneration !== ipcGeneration
        let pending = ruleRecoveryPending || state.providers.contains { $0.kind == "rule" && $0.pending == true }
        let visible = presentation.active && presentation.page == .providers
        guard force || newIdentity || ((pending || visible) && now >= nextRuleProbeAt) else { return }
        if newIdentity { ruleProbeBackoff = 3 }
        ruleProbePointer = expected
        ruleProbeGeneration = ipcGeneration
        nextRuleProbeAt = now.addingTimeInterval(visible ? 10 : ruleProbeBackoff)
        ruleProbeBackoff = min(60, ruleProbeBackoff * 2)
        let directory = store.providersDirectory(profileID: expected.profileID, revision: expected.revision)
        let record = directory.flatMap { ClashTVRuleRecovery.read(from: $0) }
        ruleRecoveryPending = record?.hasUnexpandedRoutes ?? false
         
         
        guard state.providers.contains(where: { $0.kind == "rule" }) else { return }
        do {
            let reply = try await send(["cmd": "ruleProviders"], cancellableRead: true)
            let providers = try ClashTVKernelSnapshots.ruleProviders(from: reply)
            guard accepts(context), try store.activeIdentity() == expected else { return }
            state.providers = state.providers.map { entry in
                guard entry.kind == "rule", let provider = providers[entry.name] else { return entry }
                return .init(kind: entry.kind, name: entry.name,
                             updatedAt: provider.updatedAt ?? entry.updatedAt,
                             failure: provider.loaded ? nil : entry.failure,
                             pending: provider.loaded ? false : (record == nil ? entry.pending : true))
            }
            state.ruleProvidersLoaded = ClashTVProviderCatalog(entries: state.providers).readyCount
            guard record != nil else { return }
             
             
            let tunnelHashes = ClashTVRuleRecovery.tunnelContent(container: container)
            let pipeline = ClashTVConfigPipeline(container: container, session: session)
            let recovered = try await pipeline.recoverRules(expected: expected, tunnelHashes: tunnelHashes) { [weak self] hashes in
                guard let self, self.accepts(context), try store.activeIdentity() == expected else { return false }
                let second = ClashTVRuleRecovery.tunnelContent(container: container)
                return hashes.allSatisfy { key, hash in
                    second[String(key.dropFirst("rule:".count))]?.contains(hash) == true
                }
            }
            if let recovered, accepts(context) {
                ruleProbePointer = .init(profileID: recovered.profileID, revision: recovered.revision)
                if let directory = store.providersDirectory(profileID: recovered.profileID, revision: recovered.revision) {
                    ruleRecoveryPending = ClashTVRuleRecovery.read(from: directory)?.hasUnexpandedRoutes ?? false
                }
            }
        } catch {
             
             
            guard !(error is CancellationError), accepts(context),
                  (try? store.activeIdentity()) == expected else { return }
            ClashLogStore.shared.append("tv rule recovery: \(error.localizedDescription)", stream: .app, level: .warning)
        }
    }


     

    private func send(_ object: [String: Any], timeout: TimeInterval = messageTimeout, cancellableRead: Bool = false, expectedGeneration: ClashTVIPCGeneration? = nil) async throws -> Data {
        let generation = expectedGeneration ?? ipcGeneration
        guard generation === ipcGeneration, generation.isValid else { throw ControllerError.ipcNotSent(.connectionChanged) }
        let payload = try JSONSerialization.data(withJSONObject: object)
        let reply: Data
        if let messageReader {
            reply = try await messageReader(payload, UInt64(timeout * 1_000_000_000), cancellableRead)
        } else {
            guard let session = manager?.vpnConnection as? NETunnelProviderSession else {
                throw ControllerError.ipcNotSent(.connectionChanged)
            }
            reply = try await ClashTVIPCChannel.shared.send(session: session, data: payload,
                timeoutNanoseconds: UInt64(timeout * 1_000_000_000),
                cancellableRead: cancellableRead, generation: generation)
        }
        guard generation === ipcGeneration, generation.isValid else { throw ControllerError.ipcReplySuperseded }
        return reply
    }

    private static func isOK(_ reply: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["ok"] as? Bool == true
    }

     
    private static func errorClass(_ reply: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["errorClass"] as? String
    }

     
    private static func committedWarning(_ reply: Data) -> String? {
        guard errorClass(reply) == "committed" else { return nil }
        let warning = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["warning"] as? String
        return warning?.isEmpty == false ? warning : nil
    }

    private static func replyError(_ reply: Data) -> Error {
        guard let message = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["error"] as? String else {
            return ControllerError.invalidResponse
        }
        return ControllerError.kernelRefused(message)
    }

     

     
     
     
     
     
     
     
     
     
     
     
    static func bounded<T: Sendable>(
        _ seconds: TimeInterval,
        late: (@Sendable (Result<T, Error>) -> Void)? = nil,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = ClashTVResumeOnce()
            let work = Task {
                do {
                    let value = try await operation()
                    if once.claim() { continuation.resume(returning: value) } else { late?(.success(value)) }
                } catch {
                    if once.claim() { continuation.resume(throwing: error) } else { late?(.failure(error)) }
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() {
                     
                     
                    if late == nil { work.cancel() }
                    continuation.resume(throwing: ControllerError.systemTimedOut)
                }
            }
        }
    }

     
     
     
     
    enum ControllerError: LocalizedError {
        case appGroupUnavailable
        case extensionUnavailable
        case systemTimedOut
        case tunnelTimedOut
        case invalidResponse
        case ipcNotSent(IPCNotSentReason)
        case ipcResultUnknown
        case ipcReplySuperseded

        enum IPCNotSentReason {
            case capacity, deadline, connectionChanged, unresolved, invalidRequest, unsupportedAsyncReload
            case transport(String)
        }
        case tunnelDidNotStart
        case tunnelStopped
        case kernelRefused(String)
        case ipStackRestartFailed(String)
         
         
        case ipStackStopUnanswered(String)

        var errorDescription: String? {
            switch self {
            case .ipStackRestartFailed(let reason):
                return String(localized: "IP Stack settings were saved, but the VPN did not restart. Connect again to apply them.") + "\n" + reason
            case .ipStackStopUnanswered(let reason):
                return String(localized: "IP Stack settings were saved, but the VPN did not stop in time to restart. Connect again to apply them.") + "\n" + reason
            case .appGroupUnavailable:
                return String(localized: "Clash could not open its secure shared container.")
            case .extensionUnavailable:
                return String(localized: "The Clash packet tunnel is not available.")
            case .systemTimedOut:
                return String(localized: "The system did not answer in time.")
            case .tunnelTimedOut:
                return String(localized: "The Clash packet tunnel did not answer in time.")
            case .ipcNotSent(let reason):
                let detail: String
                switch reason {
                case .capacity: detail = String(localized: "The tunnel request queue is full.")
                case .deadline: detail = String(localized: "The request expired while waiting.")
                case .connectionChanged: detail = String(localized: "The connection changed while waiting.")
                case .unresolved: detail = String(localized: "An earlier tunnel request is still unresolved.")
                case .invalidRequest: detail = String(localized: "The tunnel request is invalid.")
                case .unsupportedAsyncReload: detail = String(localized: "Asynchronous reload is not supported here.")
                case .transport(let message): detail = message
                }
                return String(localized: "Not sent.") + " " + detail
            case .ipcResultUnknown:
                return String(localized: "The request was sent, but its result could not be confirmed. It will not be sent again automatically.")
            case .ipcReplySuperseded:
                return String(localized: "The request's reply belongs to an earlier connection.")
            case .invalidResponse:
                return String(localized: "The Clash packet tunnel returned an invalid response.")
            case .tunnelDidNotStart:
                return String(localized: "The tunnel stopped before it came up.")
            case .tunnelStopped:
                return String(localized: "The tunnel stopped on its own. Connect again to bring it back.")
            case .kernelRefused(let reason):
                return String(localized: "The tunnel refused: \(reason)")
            }
        }
    }
}

 
 
 
actor ClashTVIPCChannel {
    static let shared = ClashTVIPCChannel()
    typealias Delivery = @Sendable (Data, @escaping @Sendable (Data?) -> Void) throws -> Void
    typealias Failure = ClashTVTunnelController.ControllerError

    struct Limits: Sendable {
        var queuedCount = 32
        var payloadBytes = 256 * 1024
        var timeoutNanoseconds: UInt64 = 30_000_000_000
    }
    private struct Pending {
        let id: UUID
        let command: String
        let deliver: Delivery
        let data: Data
        let ticket: ClashTVReadAdmission?
        let generation: ClashTVIPCGeneration?
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Data, Error>
    }
     
     
    private struct Unresolved {
        let id: UUID
        let command: String
        let generation: ClashTVIPCGeneration?
        let deadline: ContinuousClock.Instant
        var continuation: CheckedContinuation<Data, Error>?
    }

    private let limits: Limits
    private var queue: [Pending] = []
    private var current: Unresolved?
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private(set) var queuedBytes = 0
    var queuedCount: Int { queue.count }
    var unresolvedCount: Int { current == nil ? 0 : 1 }
    var quarantined: Bool { current != nil && current?.continuation == nil }

    init(limits: Limits = Limits()) { self.limits = limits }

    func send(session: NETunnelProviderSession, data: Data, timeoutNanoseconds: UInt64,
              cancellableRead: Bool = false, generation: ClashTVIPCGeneration? = nil) async throws -> Data {
        try await send(data: data, timeoutNanoseconds: timeoutNanoseconds,
                       cancellableRead: cancellableRead, generation: generation) { data, reply in
            try session.sendProviderMessage(data, responseHandler: reply)
        }
    }

    func send(data: Data, timeoutNanoseconds: UInt64, cancellableRead: Bool = false,
              generation: ClashTVIPCGeneration? = nil, deliver: @escaping Delivery) async throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(clamping:
            min(timeoutNanoseconds, limits.timeoutNanoseconds))))
        guard data.count <= limits.payloadBytes else { throw Failure.ipcNotSent(.capacity) }
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = request["cmd"] as? String, !command.isEmpty, command.utf8.count <= 64 else {
            throw Failure.ipcNotSent(.invalidRequest)
        }
         
         
        if command == "reload", request["async"] as? Bool == true {
            throw Failure.ipcNotSent(.unsupportedAsyncReload)
        }
        let id = UUID()
        let ticket = cancellableRead && Self.readCommands.contains(command) ? ClashTVReadAdmission() : nil
        return try await withTaskCancellationHandler {
            if ticket != nil { try Task.checkCancellation() }
            guard generation?.isValid != false else { throw Failure.ipcNotSent(.connectionChanged) }
            guard deadline > .now else { throw Failure.ipcNotSent(.deadline) }
            guard !quarantined else { throw Failure.ipcNotSent(.unresolved) }
            guard queue.count < limits.queuedCount,
                  data.count <= limits.payloadBytes - queuedBytes else { throw Failure.ipcNotSent(.capacity) }
            return try await withCheckedThrowingContinuation { continuation in
                queue.append(Pending(id: id, command: command, deliver: deliver, data: data,
                    ticket: ticket, generation: generation, deadline: deadline, continuation: continuation))
                queuedBytes += data.count
                deadlines[id] = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                    await self?.expire(id: id)
                }
                startNextIfNeeded()
            }
        } onCancel: {
            guard let ticket else { return }
            ticket.cancel()
            Task { await self.removeQueued(id: id, error: CancellationError()) }
        }
    }

    private static let readCommands: Set<String> = [
        "hello", "runtimeDiagnostics", "reloadStatus", "status", "traffic",
        "connections", "proxies", "ruleProviders", "logs", "proxyShareStatus"
    ]

    private func removeQueued(id: UUID, error: Error) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let pending = queue.remove(at: index)
        queuedBytes -= pending.data.count
        deadlines.removeValue(forKey: id)?.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func startNextIfNeeded() {
        guard current == nil else { return }
        while !queue.isEmpty {
            let pending = queue.removeFirst()
            queuedBytes -= pending.data.count
            let failure: Error?
            if pending.generation?.isValid == false { failure = Failure.ipcNotSent(.connectionChanged) }
            else if pending.deadline <= .now { failure = Failure.ipcNotSent(.deadline) }
            else if let ticket = pending.ticket, !ticket.admit() { failure = CancellationError() }
            else { failure = nil }
            if let failure {
                deadlines.removeValue(forKey: pending.id)?.cancel()
                pending.continuation.resume(throwing: failure)
                continue
            }
            let id = pending.id
            current = Unresolved(id: id, command: pending.command, generation: pending.generation,
                                 deadline: pending.deadline, continuation: pending.continuation)
            do {
                try pending.deliver(pending.data) { [weak self] response in
                    Task { await self?.receive(id: id, response: response) }
                }
                return
            } catch {
                 
                deadlines.removeValue(forKey: id)?.cancel()
                current = nil
                pending.continuation.resume(throwing: Failure.ipcNotSent(.transport(error.localizedDescription)))
                 
            }
        }
    }

    private func expire(id: UUID) {
        deadlines.removeValue(forKey: id)?.cancel()
        if current?.id == id { makeUnknown(id: id) }
        else { removeQueued(id: id, error: Failure.ipcNotSent(.deadline)) }
    }

    private func makeUnknown(id: UUID) {
        guard current?.id == id else { return }
        deadlines.removeValue(forKey: id)?.cancel()
        let continuation = current?.continuation
        current?.continuation = nil
        continuation?.resume(throwing: Failure.ipcResultUnknown)
    }

    private func receive(id: UUID, response: Data?) {
        guard let unresolved = current, unresolved.id == id else { return }
        guard let response, Self.isCompletion(response, command: unresolved.command) else {
            makeUnknown(id: id)
            return
        }
        deadlines.removeValue(forKey: id)?.cancel()
        current = nil
        if unresolved.deadline <= .now {
            unresolved.continuation?.resume(throwing: Failure.ipcResultUnknown)
        } else if unresolved.generation?.isValid == false {
            unresolved.continuation?.resume(throwing: Failure.ipcReplySuperseded)
        } else {
            unresolved.continuation?.resume(returning: response)
        }
        startNextIfNeeded()
    }

    private static func isCompletion(_ data: Data, command: String) -> Bool {
         
         
        if command == "consumeGoCrashReport" { return String(data: data, encoding: .utf8) != nil }
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return false }
        if command == "logs", value is [String] || value is NSNull { return true }
        guard let object = value as? [String: Any] else { return false }
        if object["error"] is String { return true }
        if object["accepted"] as? Bool == true { return false }
        switch command {
        case "reload", "setMode", "select", "unfix", "closeAll", "recordMemoryPressureEvidence":
            return object["ok"] as? Bool == true
        case "hello":
            return object["schemaVersion"] is NSNumber && object["coreVersion"] is String
        case "status":
            return object["status"] is String && object["mode"] is String
        case "traffic":
            return ["up", "down", "upTotal", "downTotal"].allSatisfy { object[$0] is NSNumber }
        case "connections":
            return object["connections"] is [Any] || object["connections"] is NSNull
        case "proxies": return object["proxies"] is [String: Any]
         
         
         
        case "ruleProviders": return object["providers"] is [String: Any]
        case "urltest": return object["delay"] is NSNumber
        case "dnsQuery": return object["Status"] is NSNumber
        case "close": return object["closed"] is NSNumber
        case "proxyShareStart", "proxyShareStop", "proxyShareStatus":
            return object["ok"] as? Bool == true && object["status"] is [String: Any]
        case "runtimeDiagnostics", "reloadRuntimeSetupOptions", "exerciseSleepWake":
            return object["goroutines"] is NSNumber
        case "consumeOOMEvidence":
            return object["schemaVersion"] is NSNumber && object["pressureLevel"] is String
                && object["possibleSystemKill"] as? Bool == true
        case "reloadStatus":
            return object["session"] is String && object["state"] is String
         
         
         
        case "remoteControl":
            return object["generation"] is NSNumber && object["mode"] is String
        default:
             
             
            return false
        }
    }
}

 
 
final class ClashTVIPCGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var valid: Bool
    init(active: Bool = true) { valid = active }
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
}

 
 
private final class ClashTVReadAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var admitted = false
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        if !admitted { cancelled = true }
    }
    func admit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        admitted = true
        return true
    }
}

 
final class ClashTVResumeOnce: @unchecked Sendable {
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


enum ClashTVPollingPage: Equatable, Sendable {
    case home, nodes, outboundMode, connections, connectionDetail, diagnostics, configuration, providers

     
     
    func commands(tick: Int) -> [ClashTVPollingCommand] {
        var result: [ClashTVPollingCommand] = []
        if self == .home || self == .diagnostics { result.append(.traffic) }
        if tick % 3 == 0 {
            if self == .home || self == .nodes { result.append(.proxies) }
            if self == .home || self == .connections || self == .connectionDetail { result.append(.connections) }
            result.append(.status)
        }
        return result
    }
}

enum ClashTVPollingCommand: String, Equatable, Sendable {
    case traffic, proxies, connections, status
}

struct ClashTVPollingPresentation: Equatable, Sendable {
    let page: ClashTVPollingPage
    let active: Bool
}
