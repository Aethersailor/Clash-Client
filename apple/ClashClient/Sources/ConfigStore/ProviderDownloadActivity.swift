import Foundation

 
 
 
 
 
 
 
enum ProviderDownloadActivity {
     
    static let didChangeNotification = Notification.Name("ClashProviderDownloadActivityDidChange")

     
    static let downloadingNote = "Downloading…"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: [String: Int] = [:]
    nonisolated(unsafe) private static var failures: [String: String] = [:]
    nonisolated(unsafe) private static var claimed: Set<String> = []

     
     
     
     
     
     
    static func claim(_ urls: [String]) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var taken: [String] = []
        for url in urls where !claimed.contains(url) {
            claimed.insert(url)
            taken.append(url)
        }
        return taken
    }

    static func release(_ urls: [String]) {
        lock.lock()
        for url in urls { claimed.remove(url) }
        lock.unlock()
    }

     
     
    static func begin(_ urls: [String]) {
        guard !urls.isEmpty else { return }
        lock.lock()
        for url in urls { running[url, default: 0] += 1 }
        lock.unlock()
        post()
    }

     
     
     
     
    static func end(_ url: String, failure: String?, answered: Bool = true) {
        lock.lock()
        if let count = running[url], count > 1 { running[url] = count - 1 } else { running[url] = nil }
        if answered { failures[url] = failure }
        lock.unlock()
        post()
    }

    static var downloading: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(running.keys)
    }

    static var recentFailures: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }

     
    static var fingerprint: String {
        lock.lock()
        defer { lock.unlock() }
        return running.keys.sorted().joined(separator: ",") + "|"
            + failures.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: ",")
    }

    static func resetForTesting() {
        lock.lock()
        running = [:]
        failures = [:]
        claimed = []
        lock.unlock()
    }

     
     
     
     
     
    static func reason(for error: Error, url: String) -> String {
        if let batch = error as? ProviderDownloadFailuresError, let first = batch.failures.first {
            return "download failed (\(first.url ?? url)): \(first.underlying.localizedDescription)"
        }
        if let refused = error as? ProviderValidationFailure {
            return refused.underlying.localizedDescription
        }
        if let refusal = error as? MaterializeError, let reason = refusal.providerRowReason {
            return reason
        }
        return "download failed (\(url)): \(error.localizedDescription)"
    }

     
     
    private static func post() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }
}
