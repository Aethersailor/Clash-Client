#if os(iOS) || os(macOS)
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

 
 
 
 
 
 
 
 

enum AdBlockEngineReadiness {
     
    static let memoryStopHold: TimeInterval = 6 * 60 * 60
     
     
    static let holdExpiry: TimeInterval = 24 * 60 * 60
     
     
    static let holdClockTolerance: TimeInterval = 60

     
     
    struct Retry: Codable, Equatable {
        let at: Date
    }

     
     
     
     
     
     
     
     
    struct Hold: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Equatable, Sendable {
             
            case reinjectNeedsAuthentication
             
            case certificateUnreadable
             
            case redrawSpent
        }

        let kind: Kind
         
        let ports: AdBlockPorts?
         
        let fingerprint: String?
         
        let revision: AdBlockRunningRevision?
         
         
        let at: Date

        var status: AdBlockEngineStatus {
            kind == .certificateUnreadable ? .withheld(.certificateUnusable) : .withheld(.engineUnavailable)
        }

         
         
         
         
        func stands(ports: AdBlockPorts?, fingerprint: String?, now: Date) -> Bool {
            let age = now.timeIntervalSince(at)
            return ports == self.ports && fingerprint == self.fingerprint
                && age > -AdBlockEngineReadiness.holdClockTolerance && age < AdBlockEngineReadiness.holdExpiry
        }

         
        static func kind(of failure: AdBlockEngineReport.Failure) -> Kind? {
            switch failure {
            case .bindFailed, .reinjectUnanswered: return .redrawSpent
            case .reinjectNeedsAuthentication: return .reinjectNeedsAuthentication
            case .certificateUnreadable: return .certificateUnreadable
            case .planUnreadable, .engineSignInMissing: return nil
            }
        }
    }

     
     
     
     
     
    static func status(certificate: AdBlockCertificateState, report: AdBlockEngineReport?, ports: AdBlockPorts?,
                       retriedAt: Date?, now: Date, fingerprint: String? = nil, publishedFingerprint: String? = nil,
                       caUnavailable: Bool = false, redrawsAllowed: Bool = true,
                       platform: AdBlockCertificatePlatform = .current) -> AdBlockEngineStatus {
        decide(certificate: certificate, report: report, ports: ports, retriedAt: retriedAt, now: now,
               fingerprint: fingerprint, publishedFingerprint: publishedFingerprint, caUnavailable: caUnavailable,
               redrawsAllowed: redrawsAllowed, platform: platform).status
    }

     
     
    static func decide(certificate: AdBlockCertificateState, report: AdBlockEngineReport?, ports: AdBlockPorts?,
                       retriedAt: Date?, now: Date, fingerprint: String? = nil, publishedFingerprint: String? = nil,
                       caUnavailable: Bool = false, redrawsAllowed: Bool = true,
                       platform: AdBlockCertificatePlatform = .current) -> (status: AdBlockEngineStatus, hold: Hold.Kind?) {
        let retried = retriedAt ?? .distantPast
         
         
         
         
         
        if platform == .ios, let stop = report?.lastMemoryStopAt, now.timeIntervalSince(stop) < memoryStopHold, retried < stop {
            return (.withheld(.stoppedForMemory), nil)
        }
         
         
        if caUnavailable { return (.withheld(.certificateUnusable), nil) }
         
         
         
         
        if let fingerprint, let report, report.identityDegradeHolds(for: fingerprint),
           let failed = report.identityFailedAt[fingerprint], retried < failed {
            return (.withheld(.certificateUnusable), nil)
        }
         
         
         
        if let report, let failure = report.failure, retried < report.updatedAt {
            switch failure {
            case .bindFailed(let port, _):
                if port == ports?.engine {
                    return redrawsAllowed ? (.portsFailed([port]), nil) : (.withheld(.engineUnavailable), .redrawSpent)
                }
            case .reinjectUnanswered(let port, _):
                if port == ports?.reinject {
                    return redrawsAllowed ? (.portsFailed([port]), nil) : (.withheld(.engineUnavailable), .redrawSpent)
                }
            case .reinjectNeedsAuthentication(let port, _):
                 
                if port == ports?.reinject { return (.withheld(.engineUnavailable), .reinjectNeedsAuthentication) }
            case .certificateUnreadable:
                 
                 
                 
                let identity = fingerprint.map { report.identityFailedAt[$0] != nil } ?? false
                 
                 
                if !identity, report.ports == nil || report.ports == ports {
                    return (.withheld(.certificateUnusable), .certificateUnreadable)
                }
            case .planUnreadable, .engineSignInMissing:
                 
                 
                 
                break
            }
        }
        switch certificate {
        case .ready:
             
             
             
            if let publishedFingerprint, let fingerprint, publishedFingerprint.lowercased() != fingerprint.lowercased() {
                return (.untrusted(.certificateNotTrusted), nil)
            }
            return (.ready, nil)
         
        case .notGenerated: return (.withheld(.certificateMissing), nil)
        case .notInstalled, .installedNotTrusted: return (.untrusted(.certificateNotTrusted), nil)
        }
    }
}

extension AdBlockEngineStatus {
     
    var spelling: String {
        switch self {
        case .ready: return "ready"
        case .untrusted(let reason): return "untrusted:" + reason.degradeReason.spelling
        case .withheld(let reason): return "withheld:" + reason.degradeReason.spelling
        case .portsFailed(let ports): return "portsFailed:" + ports.sorted().map(String.init).joined(separator: ",")
        case .unavailable: return "unavailable"
        }
    }
}

 
 
 
 
 
 
 
 
 
 
 
final class AdBlockEngineReadinessSource: @unchecked Sendable {
     
    static let didChange = Notification.Name("ClashAdBlockEngineReadinessDidChange")

     
     
     
     
    static var observesInThisProcess: Bool {

        true

    }

     
     
    struct Asked: Equatable, Sendable {
        let status: AdBlockEngineStatus
        let ports: AdBlockPorts?
        let publishedFingerprint: String?
    }

     
     
    private struct Carried: Codable, Equatable {
        let status: String
        let at: Date
        let enabled: Bool
        let ports: AdBlockPorts?
        let publishedFingerprint: String?
    }

     
     
     
    private struct Redraws: Codable, Equatable {
        var drawn = AdBlockPortRedraws()
        var lastFailed: [UInt16] = []
    }

     
     
     
    private struct Holds: Codable, Equatable {
        var hold: AdBlockEngineReadiness.Hold?
         
         
        var lifted: AdBlockEngineReadiness.Hold?
        var planRestagedFor: AdBlockRunningRevision?
         
         
         
        var reloadOwed: AdBlockRunningRevision?
    }

     
    private struct Inputs {
        let report: AdBlockEngineReport?
        let certificate: AdBlockCertificateState
        let caUnavailable: Bool
        let fingerprint: String?
        let retriedAt: Date?
        let now: Date
         
         
        let active: AdBlockRunningRevision?
    }

    private static let registryLock = NSLock()
    private static var registry: [String: AdBlockEngineReadinessSource] = [:]

     
     
    static func shared(_ container: URL) -> AdBlockEngineReadinessSource {
        let key = container.standardizedFileURL.path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[key] { return existing }
        let made = AdBlockEngineReadinessSource(container: container)
        registry[key] = made
        return made
    }

    let container: URL
    let locations: AdBlockEngineLocations
    let certificates: AdBlockCertificateStore
    private let now: () -> Date
    private let queue: DispatchQueue
     
     
    private let platform: AdBlockCertificatePlatform
     
    private let lock = NSLock()
    private var observing = false
    private var foregroundObserver: NSObjectProtocol?
     
    private let pendingLock = NSLock()
    private var recheckQueued = false



     
     
    init(container: URL, certificates: AdBlockCertificateStore? = nil, now: @escaping () -> Date = Date.init,
         queue: DispatchQueue = DispatchQueue(label: "adblock.readiness", qos: .utility),
         platform: AdBlockCertificatePlatform = .current) {
        self.container = container
        let locations = AdBlockEngineLocations.of(container)
        self.locations = locations
        self.certificates = certificates ?? AdBlockCertificateStore(locations: locations)
        self.now = now
        self.queue = queue
        self.platform = platform
    }

    deinit {
        stopObserving()
    }

     
    private var carriedFile: URL { locations.stateDirectory.appendingPathComponent("engine-carried.json") }
     
    private var redrawsFile: URL { locations.stateDirectory.appendingPathComponent("port-redraws.json") }
     
    private var holdsFile: URL { Self.holdsFile(locations) }
    private static func holdsFile(_ locations: AdBlockEngineLocations) -> URL {
        locations.stateDirectory.appendingPathComponent("engine-holds.json")
    }

     
    func status(ports: AdBlockPorts?, publishedFingerprint: String? = nil) -> AdBlockEngineStatus {
        let inputs = gather()
        lock.lock()
        defer { lock.unlock() }
        return decideLocked(inputs, ports: ports, publishedFingerprint: publishedFingerprint, noting: false)
    }

     
     
     
     
     
    func statusForPublication(ports: AdBlockPorts?, publishedFingerprint: String? = nil) -> AdBlockEngineStatus {
        let inputs = gather()
        lock.lock()
        defer { lock.unlock() }
        return decideLocked(inputs, ports: ports, publishedFingerprint: publishedFingerprint, noting: true)
    }

     
     
     
    func confirm(_ asked: Asked?) {
        lock.lock()
        defer { lock.unlock() }
        guard let asked else {
            if FileManager.default.fileExists(atPath: carriedFile.path) { try? FileManager.default.removeItem(at: carriedFile) }
            return
        }
        let before = read(Carried.self, carriedFile)
        guard before?.status != asked.status.spelling || before?.ports != asked.ports
                || before?.publishedFingerprint != asked.publishedFingerprint || before?.enabled != true else { return }
        write(Carried(status: asked.status.spelling, at: now(), enabled: true, ports: asked.ports,
                      publishedFingerprint: asked.publishedFingerprint), carriedFile)
    }

     
     
     
     
    @discardableResult
    func recheck() -> Bool {
        lock.lock()


        let asked = read(Carried.self, carriedFile)
        lock.unlock()
        guard let asked, asked.enabled else { return false }
        let inputs = gather()
        lock.lock()
        var moved = decideLocked(inputs, ports: asked.ports, publishedFingerprint: asked.publishedFingerprint, noting: false)
            .spelling != asked.status
         
         
         
         
        if let report = inputs.report, case .planUnreadable = report.failure, let revision = report.revision,
           revision == inputs.active {
            var holds = read(Holds.self, holdsFile) ?? Holds()
            if holds.planRestagedFor != revision {
                holds.planRestagedFor = revision
                holds.reloadOwed = revision
                write(holds, holdsFile)
                moved = true
            }
        }
        lock.unlock()
        guard moved else { return false }
        let container = self.container
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: container) }
        return true
    }

     
    func scheduleRecheck() {
        pendingLock.lock()
        guard !recheckQueued else {
            pendingLock.unlock()
            return
        }
        recheckQueued = true
        pendingLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            self.recheckQueued = false
            self.pendingLock.unlock()
            self.recheck()
        }
    }

     
     
     
    func noteRetry() {
        lock.lock()
        write(AdBlockEngineReadiness.Retry(at: now()), locations.engineRetry)
         
        if var holds = read(Holds.self, holdsFile), let hold = holds.hold {
            holds.lifted = hold
            holds.hold = nil
            write(holds, holdsFile)
        }
        lock.unlock()
        scheduleRecheck()
    }

     
     
     
     
     
     
     
     
    func takesOwedReload(of revision: AdBlockRunningRevision) -> Bool {
        let report = AdBlockEngineReport.load(locations)
        lock.lock()
        defer { lock.unlock() }
        guard var holds = read(Holds.self, holdsFile), let owed = holds.reloadOwed else { return false }
        holds.reloadOwed = nil
        write(holds, holdsFile)
        guard owed == revision, case .planUnreadable = report?.failure, report?.revision == revision else { return false }
        return true
    }

     
     
     
    static func takesOwedReload(of expected: ActiveConfigurationPointer?, container: URL?) -> Bool {
        guard let expected, let container,
              FileManager.default.fileExists(atPath: holdsFile(AdBlockEngineLocations.of(container)).path) else { return false }
        return shared(container).takesOwedReload(of: AdBlockRunningRevision(profileID: expected.profileID,
                                                                           revision: expected.revision))
    }

     

    private func gather() -> Inputs {
        let report = AdBlockEngineReport.load(locations)
        var certificate = AdBlockCertificateState.notGenerated
        var unavailable = false
        var fingerprint: String?
        switch AdBlockCAFiles.status(certificates.locations) {
        case .ready(_, let metadata):
            fingerprint = metadata.fingerprintSHA256
            certificate = certificates.state(report: report)
        case .unavailable:
            unavailable = true
        case .absent, .needsRegeneration:
            break
        }
        var active: AdBlockRunningRevision?
        if case .planUnreadable = report?.failure,
           let pointer = (try? ConfigResourceStore(containerURL: container))?.activeIdentityWithoutLock() {
            active = AdBlockRunningRevision(profileID: pointer.profileID, revision: pointer.revision)
        }
        return Inputs(report: report, certificate: certificate, caUnavailable: unavailable, fingerprint: fingerprint,
                      retriedAt: read(AdBlockEngineReadiness.Retry.self, locations.engineRetry)?.at, now: now(), active: active)
    }

     
     
    private func decideLocked(_ inputs: Inputs, ports: AdBlockPorts?, publishedFingerprint: String?,
                              noting: Bool) -> AdBlockEngineStatus {
        var report = inputs.report
        var holds = read(Holds.self, holdsFile) ?? Holds()
        func decide(redrawsAllowed: Bool = true) -> (status: AdBlockEngineStatus, hold: AdBlockEngineReadiness.Hold.Kind?) {
            AdBlockEngineReadiness.decide(certificate: inputs.certificate, report: report, ports: ports, retriedAt: inputs.retriedAt,
                                          now: inputs.now, fingerprint: inputs.fingerprint,
                                          publishedFingerprint: publishedFingerprint, caUnavailable: inputs.caUnavailable,
                                          redrawsAllowed: redrawsAllowed, platform: platform)
        }
        if let hold = holds.hold, hold.stands(ports: ports, fingerprint: inputs.fingerprint, now: inputs.now) {
             
             
            report?.failure = nil
            let other = decide().status
            if case .withheld = other { return other }
            return hold.status
        }
         
         
         
        for spent in [holds.hold, holds.lifted].compactMap({ $0 }) {
            if let failure = report?.failure, AdBlockEngineReadiness.Hold.kind(of: failure) == spent.kind,
               report?.revision == spent.revision {
                report?.failure = nil
            }
        }
        var decided = decide()
        if case .portsFailed(let failed) = decided.status {
            var redraws = read(Redraws.self, redrawsFile) ?? Redraws()
            let failedPorts = failed.sorted()
             
            if redraws.lastFailed != failedPorts {
                if redraws.drawn.allowsAnother(at: inputs.now) {
                    if noting {
                        redraws.drawn.note(at: inputs.now)
                        redraws.lastFailed = failedPorts
                        write(redraws, redrawsFile)
                    }
                } else {
                    decided = decide(redrawsAllowed: false)
                }
            }
        }
        if let kind = decided.hold, noting {
            holds.hold = AdBlockEngineReadiness.Hold(kind: kind, ports: ports, fingerprint: inputs.fingerprint,
                                                     revision: report?.revision, at: inputs.now)
            write(holds, holdsFile)
        }
        return decided.status
    }

    private func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        AdBlockEngineFiles.read(type, from: url)
    }

    private func write<T: Encodable>(_ value: T, _ url: URL) {
        if let data = try? AdBlockJSON.encoder().encode(value) { try? AdBlockEngineFiles.write(data, to: url) }
    }

     

    private static let signalCallback: CFNotificationCallback = { _, observer, _, _, _ in
        guard let observer else { return }
        Unmanaged<AdBlockEngineReadinessSource>.fromOpaque(observer).takeUnretainedValue().scheduleRecheck()
    }

     
     
     
    func startObserving() {
        lock.lock()
        defer { lock.unlock() }
        guard !observing else { return }
        observing = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), Self.signalCallback,
            AdBlockEngineSignal.statusChanged as CFString, nil, .deliverImmediately)
#if os(iOS)
        let forward = UIApplication.didBecomeActiveNotification
#else
        let forward = NSApplication.didBecomeActiveNotification
#endif
        foregroundObserver = NotificationCenter.default.addObserver(forName: forward, object: nil, queue: nil) { [weak self] _ in
            self?.scheduleRecheck()
        }
    }

    func stopObserving() {
        lock.lock()
        defer { lock.unlock() }
        guard observing else { return }
        observing = false
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(AdBlockEngineSignal.statusChanged as CFString), nil)
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = nil
    }
}
#endif
