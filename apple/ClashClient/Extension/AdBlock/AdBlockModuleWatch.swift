#if os(iOS) || os(macOS)
import CryptoKit
import Darwin
import Foundation

 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 

 
 
struct AdBlockFileStamp: Equatable, Sendable {
    let inode: UInt64
    let size: Int64
    let seconds: Int
    let nanoseconds: Int

    static func of(_ url: URL) -> AdBlockFileStamp? {
         
         
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return AdBlockFileStamp(inode: UInt64(info.st_ino), size: Int64(info.st_size),
                                seconds: Int(info.st_mtimespec.tv_sec), nanoseconds: Int(info.st_mtimespec.tv_nsec))
    }
}

final class AdBlockModuleWatch {
     
    static let maximumBytes = AdBlockModuleReader.maximumListBytes
     
     
     
     
    static let coalescing: TimeInterval = 0.5

     
     
    struct Listed: Equatable, Sendable {
        let enabled: Bool
        let modules: [AdBlockGlobalManifest.Module]
    }

    let file: URL
    private let queue: DispatchQueue
    private let log: AdBlockEngineLog
    private let notificationName: String
    private let coalescing: TimeInterval?
    private let apply: (AdBlockModuleWatch, [AdBlockGlobalManifest.Module]) -> Void
     
     
     
    var onDecryption: ((AdBlockModuleWatch, Bool) -> Void)?
    private var stamp: AdBlockFileStamp?
    private var digest: String?
    private var token: Int?
    private var lookPending = false
     
    private(set) var reads = 0

     
     
     
    init(locations: AdBlockEngineLocations, queue: DispatchQueue, log: AdBlockEngineLog,
         notificationName: String = AdBlockEngineSignal.modulesChanged, coalescing: TimeInterval? = AdBlockModuleWatch.coalescing,
         apply: @escaping (AdBlockModuleWatch, [AdBlockGlobalManifest.Module]) -> Void) {
        self.file = locations.globalManifest
        self.queue = queue
        self.log = log
        self.notificationName = notificationName
        self.coalescing = coalescing
        self.apply = apply
    }

    deinit {
        stopObserving()
    }

     
     
     
     
     
    @discardableResult
    func settle() -> Listed? {
        stamp = AdBlockFileStamp.of(file)
        guard stamp != nil, let read = read() else {
            digest = nil
            return nil
        }
        digest = read.digest
        return read.listed
    }

     
    func sessionStarted() {
        look("a new connection found the module list moved")
    }

     
    func published() {
        look("the App published its modules")
    }

    private func look(_ why: String) {
        guard let coalescing else { return check(why) }
        guard !lookPending, AdBlockFileStamp.of(file) != stamp else { return }
        lookPending = true
        queue.asyncAfter(deadline: .now() + coalescing) { [weak self] in
            guard let self else { return }
            self.lookPending = false
            self.check(why)
        }
    }

    private func check(_ why: String) {
        let now = AdBlockFileStamp.of(file)
        guard now != stamp else { return }
        stamp = now
        guard let now else { return log.say("module list gone (\(why)); the rules in force stay") }
        guard let read = read() else {
            return log.say("module list unreadable (\(why), \(now.size) bytes); the rules in force stay")
        }
        reads += 1
        guard read.digest != digest else { return }
        guard let listed = read.listed else {
             
            return log.say("module list \(read.digest.prefix(12)) could not be read (\(why)); the rules in force stay")
        }
        digest = read.digest
        onDecryption?(self, listed.enabled)
        guard listed.enabled else {
            return log.say("module list \(read.digest.prefix(12)) turns HTTPS Decryption off (\(why)): every connection is relayed untouched from now on, and the next configuration takes the engine out")
        }
        guard !listed.modules.isEmpty else {
            return log.say("module list \(read.digest.prefix(12)) has no module on (\(why)): the next configuration takes the engine out; the rules in force stay until then")
        }
        log.say("module list \(read.digest.prefix(12)) changed (\(why)): \(listed.modules.count) modules, rules read again")
        apply(self, listed.modules)
    }

     
     
    private struct ListView: Decodable {
        let schemaVersion: Int
        let enabled: Bool
        let modules: [AdBlockGlobalManifest.Module]
    }

     
     
     
    private func read() -> (digest: String, listed: Listed?)? {
        var hasher = SHA256()
        let outcome = AdBlockTopLevelJSON.values(
            keeping: { ["schemaVersion", "enabled", "modules"].contains($0) }, in: file, maximumBytes: Self.maximumBytes,
            maximumValueBytes: AdBlockModuleReader.maximumModuleTableBytes, eachChunk: { hasher.update(data: $0) })
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        switch outcome {
        case .missing, .tooLarge:
            return nil
        case .notAnObject:
            return (digest, nil)
        case .values(let values, let oversized):
            guard oversized.isEmpty,
                  let view = try? AdBlockJSON.decoder().decode(ListView.self, from: AdBlockTopLevelJSON.object(values)),
                  view.schemaVersion == AdBlockGlobalManifest.currentSchemaVersion else { return (digest, nil) }
            return (digest, Listed(enabled: view.enabled, modules: view.modules))
        }
    }

     

    private final class Weak {
        weak var watch: AdBlockModuleWatch?
        init(_ watch: AdBlockModuleWatch) { self.watch = watch }
    }

     
     
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [Int: Weak] = [:]
    nonisolated(unsafe) private static var nextToken = 1

    private static let callback: CFNotificationCallback = { _, observer, _, _, _ in
        let token = Int(bitPattern: observer)
        registryLock.lock()
        let watch = registry[token]?.watch
        registryLock.unlock()
        guard let watch else { return }
        watch.queue.async { watch.published() }
    }

    func startObserving() {
        guard token == nil else { return }
        Self.registryLock.lock()
        let token = Self.nextToken
        Self.nextToken += 1
        Self.registry[token] = Weak(self)
        Self.registryLock.unlock()
        self.token = token
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), UnsafeRawPointer(bitPattern: token),
                                        Self.callback, notificationName as CFString, nil, .deliverImmediately)
    }

    func stopObserving() {
        guard let token else { return }
        self.token = nil
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), UnsafeRawPointer(bitPattern: token),
                                           CFNotificationName(notificationName as CFString), nil)
        Self.registryLock.lock()
        Self.registry[token] = nil
        Self.registryLock.unlock()
    }
}
#endif
