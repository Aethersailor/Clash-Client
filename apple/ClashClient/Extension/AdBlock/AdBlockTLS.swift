#if os(iOS) || os(macOS)
import Foundation
import Network
import Security

 
 
 
 
 
 
 
 

enum AdBlockTLSFailure: Error, Equatable, Sendable {
     
     
    case listener(String)
     
     
     
     
    case clientRejected(String, status: Int32? = nil)
     
     
    case clientWentAway(String)
     
     
    case handshakeFailed(String)
    case timedOut

     
    static func from(_ error: NWError) -> AdBlockTLSFailure {
        switch error {
        case .tls(let status):
            if alertStatuses.contains(Int(status)) { return .clientRejected("\(error)", status: status) }
            if closedStatuses.contains(Int(status)) { return .clientWentAway("\(error)") }
            return .handshakeFailed("\(error)")
        case .posix:
            return .clientWentAway("\(error)")
        default:
            return .handshakeFailed("\(error)")
        }
    }

     
     
     
     
     
     
     
     
     
     
     
     
    private static let alertStatuses: Set<Int> = Set([-9802, -9808]).union(-9840 ... -9819).union(-9865 ... -9855)
     
     
     
    private static let closedStatuses: Set<Int> = [-9805, -9806, -9816, -9852]
}

 
 
 
 
enum AdBlockLoopbackHop {
    enum Verdict: Equatable, Sendable {
        case ours
        case stranger
         
        case undecided
    }

    static func judge(peer: NWEndpoint?, hopLocal: NWEndpoint?) -> Verdict {
        guard let peer = socket(peer) else { return .stranger }
        guard let ours = socket(hopLocal) else { return .undecided }
        return peer == ours ? .ours : .stranger
    }

     
    private static func socket(_ endpoint: NWEndpoint?) -> [UInt8]? {
        guard case .hostPort(let host, let port)? = endpoint else { return nil }
        let address: Data
        switch host {
        case .ipv4(let v4): address = v4.rawValue
        case .ipv6(let v6): address = v6.rawValue
        default: return nil
        }
        return [UInt8(address.count)] + address + [UInt8(port.rawValue >> 8), UInt8(port.rawValue & 0xFF)]
    }

     
    enum Undecided {
         
         
        case wait
         
         
         
         
        case provisional
    }

     
    enum Admission: Equatable, Sendable {
        case ours
         
        case stranger
         
         
         
        case gaveUp
    }

     
     
    static func admit(_ connection: NWConnection, hop: @escaping () -> NWConnection?, queue: DispatchQueue,
                      undecided: Undecided = .wait, attempts: Int = 10, attempt: Int = 0,
                      _ decided: @escaping (Admission) -> Void) {
        guard let ours = hop() else {
            connection.cancel()
            return decided(.stranger)
        }
        switch judge(peer: connection.endpoint, hopLocal: ours.currentPath?.localEndpoint) {
        case .ours:
            decided(.ours)
        case .stranger:
            connection.cancel()
            decided(.stranger)
        case .undecided where undecided == .provisional:
            decided(.ours)
        case .undecided:
            guard attempt < attempts else {
                connection.cancel()
                return decided(.gaveUp)
            }
            queue.asyncAfter(deadline: .now() + 0.02) {
                admit(connection, hop: hop, queue: queue, undecided: undecided, attempts: attempts, attempt: attempt + 1, decided)
            }
        }
    }
}

 
final class AdBlockTLSFront {
     
     
     
     
     
    static let silentCloseWindow: TimeInterval = 3

    let plaintext: AdBlockStream
     
     
     
     
    var onClosedWithoutAsking: (() -> Void)? {
        get { watch.handler }
        set { watch.handler = newValue }
    }

    private let watch: AdBlockFirstReadWatch
    private let splice: AdBlockRelay
    private let spliceEnd: SpliceEnd

     
    fileprivate final class SpliceEnd {
        var ended = false
        var handler: (() -> Void)?

        func fire() {
            ended = true
            let told = handler
            handler = nil
            told?()
        }
    }

    private init(connection: NWConnection, splice: AdBlockRelay, spliceEnd: SpliceEnd, window: TimeInterval) {
        let watch = AdBlockFirstReadWatch(AdBlockConnectionStream(connection), window: window)
        self.watch = watch
        plaintext = watch
        self.splice = splice
        self.spliceEnd = spliceEnd
    }

    func close() {
        plaintext.cancel()
        splice.close()
    }

     
     
     
     
     
     
     
    func closeAfterDraining(within grace: TimeInterval, queue: DispatchQueue, done: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        plaintext.cancel()
        var deadline: AdBlockDeadline?
        var finished = false
        let finish = { [splice] in
            guard !finished else { return }
            finished = true
            deadline?.cancel()
            deadline = nil
            splice.close()
            done()
        }
        guard !spliceEnd.ended else { return finish() }
        spliceEnd.handler = finish
        deadline = AdBlockDeadline(after: grace, queue: queue) { finish() }
    }

     
     
     
     
    static func serves(hello: Data) -> Bool {
        guard let offered = AdBlockClientHello.applicationProtocols(hello) else { return true }
        return offered.contains("http/1.1")
    }

     
     
     
     
     
     
     
     
    static func open(client: AdBlockStream, buffered: Data, clientEnded: Bool = false, identity: SecIdentity,
                     queue: DispatchQueue, timeout: TimeInterval = 10,
                     silentCloseWindow: TimeInterval = AdBlockTLSFront.silentCloseWindow,
                     beforeJoining: ((_ port: UInt16, _ join: @escaping () -> Void) -> Void)? = nil,
                     completion: @escaping (Result<AdBlockTLSFront, AdBlockTLSFailure>) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let secIdentity = sec_identity_create(identity) else {
            client.cancel()
            return completion(.failure(.listener("the identity could not be used")))
        }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
        sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, "http/1.1")
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: options)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            client.cancel()
            return completion(.failure(.listener("\(error)")))
        }
        var finish: ((Result<AdBlockTLSFront, AdBlockTLSFailure>) -> Void)? = completion
        var splice: AdBlockRelay?
        let spliceEnd = AdBlockTLSFront.SpliceEnd()
        var hop: NWConnection?
        var accepted: NWConnection?
         
        var deadline: AdBlockDeadline?
        var grace: AdBlockDeadline?
        var settled: Bool { finish == nil }
        let settle: (Result<AdBlockTLSFront, AdBlockTLSFailure>) -> Void = { result in
            guard let done = finish else { return }
             
             
            finish = nil
            deadline?.cancel()
            grace?.cancel()
            deadline = nil
            grace = nil
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            accepted?.stateUpdateHandler = nil
            if case .failure = result {
                accepted?.cancel()
                splice?.close()
                hop?.cancel()
                client.cancel()
            }
             
            splice = nil
            hop = nil
            accepted = nil
            done(result)
        }
        listener.newConnectionHandler = { connection in
            guard accepted == nil else { return connection.cancel() }
             
             
            AdBlockLoopbackHop.admit(connection, hop: { hop }, queue: queue) { admission in
                switch admission {
                case .ours: break
                case .stranger: return
                case .gaveUp:
                     
                     
                    return settle(.failure(.listener("the client's end of the loopback hop was not known in time")))
                }
                guard !settled, accepted == nil else { return connection.cancel() }
                accepted = connection
                listener.cancel()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.stateUpdateHandler = nil
                         
                        guard let ours = hop,
                              AdBlockLoopbackHop.judge(peer: connection.endpoint, hopLocal: ours.currentPath?.localEndpoint) == .ours else {
                            return settle(.failure(.listener("a connection other than the client's reached the loopback hop")))
                        }
                        guard let relay = splice else { return settle(.failure(.listener("the hop was never joined"))) }
                        settle(.success(AdBlockTLSFront(connection: connection, splice: relay, spliceEnd: spliceEnd,
                                                        window: silentCloseWindow)))
                    case .failed(let error), .waiting(let error):
                        settle(.failure(.from(error)))
                    case .cancelled:
                        settle(.failure(.clientWentAway("the handshake was cut off")))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard let port = listener.port else { return settle(.failure(.listener("ready without a port"))) }
                let join = {
                    guard !settled, hop == nil else { return }
                    let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
                    hop = connection
                    connection.start(queue: queue)
                    let relay = AdBlockRelay(client, AdBlockConnectionStream(connection)) {
                         
                        guard !settled else { return spliceEnd.fire() }
                         
                         
                         
                        guard accepted != nil else {
                            return settle(.failure(.clientWentAway("the client went away before its handshake began")))
                        }
                        grace = AdBlockDeadline(after: 1, queue: queue) {
                            settle(.failure(.clientWentAway("the client went away during the handshake")))
                        }
                    }
                    splice = relay
                    relay.start(sendingToB: buffered, aEnded: clientEnded)
                }
                if let beforeJoining { beforeJoining(port.rawValue, join) } else { join() }
            case .failed(let error), .waiting(let error):
                settle(.failure(.listener("\(error)")))
            default:
                break
            }
        }
        listener.start(queue: queue)
        deadline = AdBlockDeadline(after: timeout, queue: queue) { settle(.failure(.timedOut)) }
    }
}

 
 
 
private final class AdBlockFirstReadWatch: AdBlockStream {
    var handler: (() -> Void)?
    private let base: AdBlockStream
    private let deadline: DispatchTime
    private var decided = false

    init(_ base: AdBlockStream, window: TimeInterval) {
        self.base = base
        deadline = .now() + window
    }

    func receive(maximumLength: Int, _ completion: @escaping (Data?, Bool, Error?) -> Void) {
        guard !decided else { return base.receive(maximumLength: maximumLength, completion) }
        base.receive(maximumLength: maximumLength) { [weak self] data, isComplete, error in
            if let self, !self.decided {
                if let data, !data.isEmpty {
                    self.decided = true
                    self.handler = nil
                } else if isComplete || error != nil {
                    self.decided = true
                    let handler = self.handler
                    self.handler = nil
                    if DispatchTime.now() <= self.deadline { handler?() }
                }
            }
            completion(data, isComplete, error)
        }
    }

    func send(_ data: Data, isFinal: Bool, _ completion: @escaping (Error?) -> Void) {
        base.send(data, isFinal: isFinal, completion)
    }

    func cancel() {
         
        decided = true
        handler = nil
        base.cancel()
    }
}

 
 
enum AdBlockServerTrust {
     
     
     
     
    case system
#if false || ADBLOCK_ENGINE_TESTS

     
     
     
     
     
    case anchors([SecCertificate])
#endif



     
    func evaluate(_ trust: SecTrust, host: String, queue: DispatchQueue, completion: @escaping (Bool, String) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
         
         
         
         
         
         
        var policies: [SecPolicy] = [SecPolicyCreateSSL(true, host as CFString)]
        var existing: CFArray?
        if SecTrustCopyPolicies(trust, &existing) == errSecSuccess, let existing = existing as? [SecPolicy] {
            policies += existing.filter { policy in
                let oid = (SecPolicyCopyProperties(policy) as? [CFString: Any])?[kSecPolicyOid] as? String
                return oid != (kSecPolicyAppleSSL as String)
            }
        }
        var status = SecTrustSetPolicies(trust, policies as CFArray)
        guard status == errSecSuccess else {
            return completion(false, "the check for \(host) could not be set up (\(status))")
        }
#if false || ADBLOCK_ENGINE_TESTS

        if case .anchors(let anchors) = self {
            status = SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            if status == errSecSuccess { status = SecTrustSetAnchorCertificatesOnly(trust, true) }
            if status == errSecSuccess { status = SecTrustSetNetworkFetchAllowed(trust, false) }
            guard status == errSecSuccess else { return completion(false, "the test anchors could not be set (\(status))") }
        }
#endif


        status = SecTrustEvaluateAsyncWithError(trust, queue) { _, trusted, error in
            let why = error.map { CFErrorCopyDescription($0) as String } ?? (trusted ? "" : "not trusted")
            completion(trusted && error == nil, why)
        }
        if status != errSecSuccess { completion(false, "the check could not start (\(status))") }
    }
}

 
 
 
 
private final class AdBlockUpstreamStream: AdBlockStream {
    private let base: AdBlockStream
    private let splice: AdBlockRelay?
    private let queue: DispatchQueue
    private var onEnd: (() -> Void)?

    init(_ base: AdBlockStream, splice: AdBlockRelay?, queue: DispatchQueue, onEnd: (() -> Void)?) {
        self.base = base
        self.splice = splice
        self.queue = queue
        self.onEnd = onEnd
    }

    deinit {
        let base = self.base, splice = self.splice, onEnd = self.onEnd
        queue.async {
            base.cancel()
            splice?.close()
            onEnd?()
        }
    }

    func receive(maximumLength: Int, _ completion: @escaping (Data?, Bool, Error?) -> Void) {
        base.receive(maximumLength: maximumLength, completion)
    }

    func send(_ data: Data, isFinal: Bool, _ completion: @escaping (Error?) -> Void) {
        base.send(data, isFinal: isFinal, completion)
    }

    func cancel() {
        base.cancel()
        splice?.close()
        let end = onEnd
        onEnd = nil
        end?()
    }
}

 
 
final class AdBlockUpstreamConnector {
    typealias Reinject = (_ authority: String,
                          _ completion: @escaping (Result<AdBlockStream, AdBlockUpstreamFailure>) -> Void) -> Void

     
     
    struct LoopCount {
        let opened: (String) -> Void
        let closed: (String) -> Void
    }

    static let handshakeTimeout: TimeInterval = 15

    private let queue: DispatchQueue
    private let reinject: Reinject
    private let trust: AdBlockServerTrust
    private let loopCount: LoopCount?
    private let ownCAFingerprint: String?
     
     
    var beforeJoining: ((_ port: UInt16, _ join: @escaping () -> Void) -> Void)?
     
     
     
    var redirectingTheTLSClient: ((_ port: UInt16) -> UInt16)?
     
     
     
     
    var onOwnAuthority: ((_ serverName: String) -> Void)?

     
     
     
     
    init(queue: DispatchQueue, reinject: @escaping Reinject, trust: AdBlockServerTrust = .system, loopCount: LoopCount? = nil,
         ownCAFingerprint: String? = nil) {
        self.queue = queue
        self.reinject = reinject
        self.trust = trust
        self.loopCount = loopCount
        self.ownCAFingerprint = ownCAFingerprint?.lowercased()
    }

     
     
     
     
     
     
    convenience init(engine: AdBlockEngine, ownCAFingerprint: String, trust: AdBlockServerTrust = .system) {
        self.init(queue: engine.queue, reinject: { [weak engine] authority, completion in
            guard let engine else { return completion(.failure(.unreachable("the engine stopped"))) }
            engine.reinject(authority, completion)
        }, trust: trust, loopCount: LoopCount(opened: { [weak engine] in engine?.upstreamOpened($0) },
                                             closed: { [weak engine] in engine?.upstreamClosed($0) }),
        ownCAFingerprint: ownCAFingerprint)
    }

     
     
     
     
     
    func open(authority: String, serverName: String, tls: Bool,
              completion: @escaping (Result<AdBlockStream, AdBlockUpstreamFailure>) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        let queue = self.queue
        let ended: (() -> Void)? = loopCount.map { count in { count.closed(authority) } }
         
         
        var pending: ((Result<AdBlockStream, AdBlockUpstreamFailure>) -> Void)? = completion
        let deliver: (Result<AdBlockStream, AdBlockUpstreamFailure>) -> Void = { result in
            let done = pending
            pending = nil
            done?(result)
        }
        loopCount?.opened(authority)
        reinject(authority) { [self] result in
            switch result {
            case .failure(let failure):
                ended?()
                deliver(.failure(failure))
            case .success(let toKernel) where !tls:
                deliver(.success(AdBlockUpstreamStream(toKernel, splice: nil, queue: queue, onEnd: ended)))
            case .success(let toKernel):
                handshake(over: toKernel, serverName: serverName) { result in
                    switch result {
                    case .success(let (connection, splice)):
                        deliver(.success(AdBlockUpstreamStream(AdBlockConnectionStream(connection), splice: splice,
                                                               queue: queue, onEnd: ended)))
                    case .failure(let failure):
                        ended?()
                        deliver(.failure(failure))
                    }
                }
            }
        }
    }

     
     
    static func chain(of trust: SecTrust, contains fingerprint: String) -> Bool {
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        return chain.contains { AdBlockCertificateFingerprint.sha256(SecCertificateCopyData($0) as Data) == fingerprint }
    }

     
     
     
    private static func clientOptions(serverName: String, trust: AdBlockServerTrust, ownCAFingerprint: String?,
                                      queue: DispatchQueue, ownAuthority: ((String) -> Void)?,
                                      refused: @escaping (String) -> Void) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, serverName, &v4) != 1, inet_pton(AF_INET6, serverName, &v6) != 1 {
            sec_protocol_options_set_tls_server_name(security, serverName)
        }
        sec_protocol_options_add_tls_application_protocol(security, "http/1.1")
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_tls_ocsp_enabled(security, true)
        sec_protocol_options_set_tls_sct_enabled(security, true)
        sec_protocol_options_set_verify_block(security, { _, presented, complete in
            let secTrust = sec_trust_copy_ref(presented).takeRetainedValue()
            trust.evaluate(secTrust, host: serverName, queue: queue) { trusted, why in
                if trusted, let ownCAFingerprint, chain(of: secTrust, contains: ownCAFingerprint) {
                    refused("the server presented a certificate of this engine's own authority: a route back into ad blocking")
                    ownAuthority?(serverName)
                    return complete(false)
                }
                if !trusted { refused(why.isEmpty ? "not trusted" : why) }
                complete(trusted)
            }
        }, queue)
        return options
    }

    private func handshake(over toKernel: AdBlockStream, serverName: String,
                           completion: @escaping (Result<(NWConnection, AdBlockRelay), AdBlockUpstreamFailure>) -> Void) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else {
            toKernel.cancel()
            return completion(.failure(.unreachable("no loopback listener for the upstream hop")))
        }
        let queue = self.queue
        let trust = self.trust
        let ownCAFingerprint = self.ownCAFingerprint
        let beforeJoining = self.beforeJoining
        let redirect = self.redirectingTheTLSClient
        let ownAuthority = self.onOwnAuthority
        var finish: ((Result<(NWConnection, AdBlockRelay), AdBlockUpstreamFailure>) -> Void)? = completion
        var splice: AdBlockRelay?
        var client: NWConnection?
        var accepted: NWConnection?
        var verdict: String?
        var deadline: AdBlockDeadline?
        var settled: Bool { finish == nil }
        let settle: (Result<(NWConnection, AdBlockRelay), AdBlockUpstreamFailure>) -> Void = { result in
            guard let done = finish else { return }
             
             
             
            finish = nil
            deadline?.cancel()
            deadline = nil
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            client?.stateUpdateHandler = nil
            if case .failure = result {
                client?.cancel()
                accepted?.cancel()
                splice?.close()
                toKernel.cancel()
            }
            splice = nil
            client = nil
            accepted = nil
            done(result)
        }
        let failure: (String) -> AdBlockUpstreamFailure = { why in verdict.map { .untrusted($0) } ?? .unreachable(why) }
        listener.newConnectionHandler = { connection in
            guard accepted == nil else { return connection.cancel() }
             
             
             
             
             
             
             
             
             
            AdBlockLoopbackHop.admit(connection, hop: { client }, queue: queue, undecided: .provisional) { admission in
                guard admission == .ours else { return }
                guard !settled, accepted == nil else { return connection.cancel() }
                accepted = connection
                listener.cancel()
                connection.start(queue: queue)
                let relay = AdBlockRelay(AdBlockConnectionStream(connection), toKernel) {
                    settle(.failure(failure("the connection closed during the handshake")))
                }
                splice = relay
                relay.start()
            }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard let port = listener.port else { return settle(.failure(.unreachable("ready without a port"))) }
                let join = {
                    guard !settled, client == nil else { return }
                    let options = Self.clientOptions(serverName: serverName, trust: trust, ownCAFingerprint: ownCAFingerprint,
                                                     queue: queue, ownAuthority: ownAuthority) { why in verdict = why }
                    let destination = redirect.flatMap { NWEndpoint.Port(rawValue: $0(port.rawValue)) } ?? port
                    let connection = NWConnection(host: .ipv4(.loopback), port: destination, using: NWParameters(tls: options))
                    client = connection
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            guard verdict == nil else { return settle(.failure(failure("the server was not trusted"))) }
                            guard let relay = splice, let hop = accepted else {
                                return settle(.failure(failure("the TLS client was ready with no hop spliced to the CONNECT")))
                            }
                             
                             
                            switch AdBlockLoopbackHop.judge(peer: hop.endpoint, hopLocal: connection.currentPath?.localEndpoint) {
                            case .ours:
                                settle(.success((connection, relay)))
                            case .stranger:
                                settle(.failure(failure("the hop was not the TLS client's own")))
                            case .undecided:
                                settle(.failure(failure("the TLS client's own end was still not known when it was ready")))
                            }
                        case .failed(let error), .waiting(let error):
                            settle(.failure(failure("\(error)")))
                        case .cancelled:
                            settle(.failure(failure("cancelled")))
                        default:
                            break
                        }
                    }
                    connection.start(queue: queue)
                }
                if let beforeJoining { beforeJoining(port.rawValue, join) } else { join() }
            case .failed(let error), .waiting(let error):
                settle(.failure(.unreachable("\(error)")))
            default:
                break
            }
        }
        listener.start(queue: queue)
        deadline = AdBlockDeadline(after: Self.handshakeTimeout, queue: queue) {
            settle(.failure(verdict.map { .untrusted($0) } ?? .timedOut))
        }
    }
}

 
enum AdBlockPinningSignal: Equatable, Sendable {
     
    case refusedLeaf(String)
     
     
    case closedWithoutAsking
     
     
     
    case encryptedClientHello(String)

     
    static let echRequiredStatus: Int32 = -9802

     
     
     
     
     
     
     
    static func of(_ failure: AdBlockTLSFailure, hello: Data) -> AdBlockPinningSignal? {
        guard case .clientRejected(let why, let status) = failure else { return nil }
        guard status == echRequiredStatus, AdBlockClientHello.offersEncryptedClientHello(hello) else { return .refusedLeaf(why) }
        return .encryptedClientHello(why)
    }

    var detail: String {
        switch self {
        case .refusedLeaf(let why):
            return "the app broke off the handshake with the ad-block certificate (\(why))"
        case .closedWithoutAsking:
            return "the app closed the connection right after the handshake without asking anything"
        case .encryptedClientHello(let why):
            return "the app offered Encrypted Client Hello, which ad blocking cannot answer, and broke off the handshake (\(why))"
        }
    }
}

 
 
 
 
final class AdBlockPinningMonitor {
    static let threshold = 3
    static let window: TimeInterval = 600
     
     
    static let maximumTrackedHosts = 256

    private let now: () -> Date
    private var events: [String: [Date]] = [:]
    private(set) var hosts: [AdBlockEngineReport.PinnedHost]

    init(now: @escaping () -> Date = Date.init, carrying: [AdBlockEngineReport.PinnedHost] = []) {
        self.now = now
        hosts = Array(carrying.prefix(AdBlockEngineReport.pinnedHostLimit))
    }

    var trackedHostCount: Int { events.count }

     
    func record(_ host: String) -> Bool {
        let at = now()
        var recent = (events[host] ?? []).filter { at.timeIntervalSince($0) < Self.window }
        recent.append(at)
        events[host] = Array(recent.suffix(Self.threshold))
        if events.count > Self.maximumTrackedHosts { prune(at) }
        let passed = recent.count >= Self.threshold
        var entry = hosts.first { $0.host == host }
            ?? AdBlockEngineReport.PinnedHost(host: host, count: 0, lastAt: at, passedThrough: false)
        entry.count += 1
        entry.lastAt = at
        entry.passedThrough = entry.passedThrough || passed
        hosts.removeAll { $0.host == host }
        hosts.insert(entry, at: 0)
        hosts = Array(hosts.prefix(AdBlockEngineReport.pinnedHostLimit))
        return passed
    }

     
     
     
    @discardableResult
    func suspect(_ host: String, _ signal: AdBlockPinningSignal, metrics: AdBlockEngineMetrics, log: AdBlockEngineLog) -> Bool {
        metrics.update { $0.pinningSuspectedTotal += 1 }
        log.say("pinning suspected \(host): \(signal.detail)")
        let wasPassed = hosts.first { $0.host == host }?.passedThrough ?? false
        let passed = record(host)
        if passed, !wasPassed {
            log.say("\(host) looked like an app that pins its certificate \(Self.threshold) times in \(Int(Self.window / 60)) minutes; it is relayed untouched for the rest of this run")
        }
        return passed || wasPassed
    }

     
     
    private func prune(_ at: Date) {
        events = events.filter { $0.value.last.map { at.timeIntervalSince($0) < Self.window } ?? false }
        guard events.count > Self.maximumTrackedHosts else { return }
        let kept = events.sorted { ($0.value.last ?? .distantPast) > ($1.value.last ?? .distantPast) }
            .prefix(Self.maximumTrackedHosts * 3 / 4)
        events = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}

 
enum AdBlockLeafChoice {
     
    case present(SecIdentity, AdBlockIdentityLease)
     
     
     
    case relayUntouched(String)
     
     
     
     
    case degrade(String)

    static func choose(host: String, leaves: AdBlockLeafStore) -> AdBlockLeafChoice {
        let lease: AdBlockIdentityLease
        do {
            lease = try leaves.lease(hostname: host)
        } catch {
            switch AdBlockCertificateError.scope(of: error) {
            case .thisHost: return .relayUntouched("\(error)")
            case .structural: return .degrade("\(error)")
            case .passing:
                guard leaves.passingFailuresDegrade else { return .relayUntouched("\(error); the next session tries again") }
                return .degrade("\(error), for \(AdBlockLeafStore.passingFailureLimit) hosts within \(Int(AdBlockLeafStore.passingFailureWindow / 60)) minutes")
            }
        }
         
        guard let identity = lease.identity else {
            lease.end()
            return .relayUntouched("the certificate was let go before the session began")
        }
        return .present(identity, lease)
    }
}
#endif
