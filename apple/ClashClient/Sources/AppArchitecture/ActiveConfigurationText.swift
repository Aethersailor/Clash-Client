import Foundation

 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
enum ActiveConfigurationText {
    private struct Entry {
        let pointer: ActiveConfigurationPointer
        let text: String
    }

     
     
     
    private static let lock = NSLock()
    private static var entry: Entry?

     
     
     
     
     
     
     
    static func current() -> String? {
        guard let container = ClashAppIdentifiers.appGroupContainer,
            let store = try? ConfigResourceStore(containerURL: container),
            let pointer = try? store.activeIdentity()
        else { return nil }

        lock.lock()
        if let cached = entry, cached.pointer == pointer {
            defer { lock.unlock() }
            return cached.text
        }
        lock.unlock()

         
         
         
         
         
        guard var text = try? store.loadCurrent().text else { return nil }
         
         
         
         
         
         
         
        if text.utf8.count > NodesInventoryProjection.wholeReadBytes,
           let reduced = ConfigurationSections.droppingLong(["proxies", "rules"], from: text) {
            text = reduced
        }
        lock.lock()
        entry = Entry(pointer: pointer, text: text)
        lock.unlock()
        return text
    }

     
     
     
    static func invalidate() {
        lock.lock()
        entry = nil
        lock.unlock()
    }
}

 
 
 
 
 
enum ActiveSourceNodeOrder {
    private struct Entry {
        let pointer: ActiveConfigurationPointer
        let names: [String]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entry: Entry?

    static func current() -> [String]? {
        guard let container = ClashAppIdentifiers.appGroupContainer,
              let store = try? ConfigResourceStore(containerURL: container),
              let pointer = try? store.activeIdentity()
        else { return nil }
        lock.lock()
        if let cached = entry, cached.pointer == pointer {
            defer { lock.unlock() }
            return cached.names
        }
        lock.unlock()
        guard let text = ActiveSourceText.text(of: pointer, container: container),
              let names = names(inSource: text)
        else { return nil }
        lock.lock()
        entry = Entry(pointer: pointer, names: names)
        lock.unlock()
        return names
    }

     
     
    static func names(inSource text: String) -> [String]? {
        var error: NSError?
        let json = AppCore.policyNamesJSON(text, &error)
        guard error == nil,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return nil }
        return (object["proxies"] as? [Any] ?? []).compactMap { $0 as? String }
    }
}

 
 
 
enum ActiveSourceText {
    private struct Entry {
        let pointer: ActiveConfigurationPointer
        let text: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entry: Entry?

     
     
    static func current() -> String? {
        guard let container = ClashAppIdentifiers.appGroupContainer,
              let store = try? ConfigResourceStore(containerURL: container),
              let pointer = try? store.activeIdentity()
        else { return nil }
        lock.lock()
        if let cached = entry, cached.pointer == pointer {
            defer { lock.unlock() }
            return cached.text
        }
        lock.unlock()
        guard let text = text(of: pointer, container: container, maxBytes: NodesInventoryProjection.wholeReadBytes)
        else { return nil }
        lock.lock()
        entry = Entry(pointer: pointer, text: text)
        lock.unlock()
        return text
    }

     
     
    static func text(of pointer: ActiveConfigurationPointer, container: URL, maxBytes: Int = .max) -> String? {
        let source = container.appendingPathComponent("working/store/\(pointer.profileID)/source.yaml")
        if maxBytes < .max {
            let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= maxBytes else { return nil }
        }
        return try? String(contentsOf: source, encoding: .utf8)
    }
}
