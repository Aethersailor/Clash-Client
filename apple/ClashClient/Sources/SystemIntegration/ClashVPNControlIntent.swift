import AppIntents
import NetworkExtension

 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
@available(iOS 16.0, *)
struct ClashVPNControlIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set Clash VPN"

     
     
    static var openAppWhenRun: Bool { false }

    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "VPN Connected")
    var value: Bool

    func perform() async throws -> some IntentResult {
         
         
         
        if await ClashVPNControlDriver.apply(connect: value) {
            return .result()
        }
         
         
         
         
        ClashSystemActionDispatch.enqueue(.vpn(value ? .connect : .disconnect))
        return .result()
    }
}

 
 
 
 
 
 
 
 
 
 
 
protocol ClashTunnelHandle: AnyObject {
    var isEnabled: Bool { get }
    var status: NEVPNStatus { get }
     
     
    var providerBundleIdentifier: String? { get }
    func start() throws
    func stop()
     
     
     
     
     
    func enable() async throws
     
     
    func disarmOnDemand() async throws -> Bool
}

extension NETunnelProviderManager {
     
     
     
     
     
     
     
     
     
     
     
    func disarmOnDemandForUserStop() -> Bool {
        guard isOnDemandEnabled else { return false }
        isOnDemandEnabled = false
        return true
    }
}

@available(iOS 16.0, *)
extension NETunnelProviderManager: ClashTunnelHandle {
    var status: NEVPNStatus { connection.status }
    var providerBundleIdentifier: String? {
        (protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
    }
    func start() throws { try connection.startVPNTunnel() }
    func stop() { connection.stopVPNTunnel() }
    func enable() async throws {
        isEnabled = true
        try await saveToPreferences()
        try await loadFromPreferences()
    }
    func disarmOnDemand() async throws -> Bool {
        guard disarmOnDemandForUserStop() else { return false }
        try await saveToPreferences()
        return true
    }
}

@available(iOS 16.0, *)
enum ClashVPNControlDriver {
     
     
    static var loadHandles: () async throws -> [any ClashTunnelHandle] = {
        try await NETunnelProviderManager.loadAllFromPreferences()
    }

     
     
     
     
     
    static var log: (String) -> Void = { line in
        ClashLogStore.shared.append("control: \(line)", stream: .app, level: .warning)
    }

     
     
     
    static var onDemandSaveDeadline: UInt64 = 3_000_000_000

    private struct OnDemandSaveUnanswered: LocalizedError {
        var errorDescription: String? { let seconds = Double(onDemandSaveDeadline) / 1e9; return "unanswered after \(seconds)s" }
    }

     
    private final class Once<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
        func resume(with result: Result<T, Error>) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            pending?.resume(with: result)
        }
    }

     
     
     
    private static func bounded(_ save: @escaping () async throws -> Bool) async throws -> Bool {
        let deadline = onDemandSaveDeadline
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            let timer = Task {
                try? await Task.sleep(nanoseconds: deadline)
                once.resume(with: .failure(OnDemandSaveUnanswered()))
            }
            Task {
                defer { timer.cancel() }
                do { once.resume(with: .success(try await save())) } catch { once.resume(with: .failure(error)) }
            }
        }
    }

     
     
     
     
     
     
    @discardableResult
    static func apply(connect: Bool) async -> Bool {
         
         
         
        let step = connect ? "start" : "stop"
        guard let handle = await installed(step) else { return false }
        guard connect else {
             
             
             
             
            do {
                if try await bounded({ try await handle.disarmOnDemand() }) { log("\(step): on demand off") }
            } catch {
                log("\(step): on demand off refused  \(describe(error))")
            }
            handle.stop()
            log("\(step): asked")
            return true
        }
        if !handle.isEnabled {
             
             
            log("\(step): configuration disabled -- enabling")
            do {
                try await handle.enable()
                log("\(step): enabled")
            } catch {
                log("\(step): enabling refused  \(describe(error))")
                return false
            }
        }
        do {
            try handle.start()
            log("\(step): asked")
            return true
        } catch let error as NEVPNError where error.code == .configurationStale {
            log("\(step): \(describe(error)) -- loading again")
            let again = "\(step) again"
            guard let fresh = await installed(again) else { return false }
            do {
                try fresh.start()
                log("\(again): asked")
                return true
            } catch {
                log("\(again): \(describe(error))")
                return false
            }
        } catch {
            log("\(step): \(describe(error))")
            return false
        }
    }

     
     
    static func toggle() async -> Bool? {
        guard let active = await isActive() else { return nil }
        return await apply(connect: !active) ? !active : nil
    }

     
     
     
     
    static func currentStatus() async -> NEVPNStatus? {
        await installed("status", journal: false)?.status
    }

     
     
     
     
     
    static func isActive(journal: Bool = true) async -> Bool? {
        await state(journal: journal)?.active
    }

     
     
     
    static func state(journal: Bool = true) async -> (active: Bool, controllable: Bool)? {
        guard let handle = await installed("read", journal: journal) else { return nil }
        let active: Bool
        switch handle.status {
        case .connected, .connecting, .reasserting: active = true
        case .disconnected, .disconnecting, .invalid: active = false
        @unknown default: active = false
        }
        return (active, handle.isEnabled)
    }

     
     
     
     
     
     
     
    private static func installed(_ step: String, journal: Bool = true) async -> (any ClashTunnelHandle)? {
        let handles: [any ClashTunnelHandle]
        do {
            handles = try await loadHandles()
        } catch {
            log("\(step): load failed  \(describe(error))")
            return nil
        }
        let ours = handles.filter { handle in
            handle.providerBundleIdentifier.map(ClashAppIdentifiers.packetTunnelProviderBundleIDs.contains) ?? false
        }
        let chosen = ours.first(where: { $0.isEnabled }) ?? ours.first
        if journal {
            var line = "\(step): managers=\(handles.count) ours=\(ours.count) enabled=\(ours.filter(\.isEnabled).count)"
            if let chosen { line += " status=\(word(chosen.status))" }
            log(line)
        }
        return chosen
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(error.localizedDescription) [\(nsError.domain)#\(nsError.code)]"
    }

    private static func word(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
