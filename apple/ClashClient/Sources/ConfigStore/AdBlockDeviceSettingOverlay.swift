import ClashClientKit
import ClashClientUI
import Foundation

 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
struct AdBlockDeviceSettingOverlay: Equatable, Sendable {
     
    private(set) var values: [AdBlockDeviceSettingKey: String] = [:]
     
    private(set) var moduleIDs: [AdBlockDeviceSettingKey: String] = [:]

    init() {}

     
     
     
    init(_ settings: [AdBlockGlobalManifest.ModuleSettings]) {
        for module in settings {
            for setting in module.deviceSettings {
                values[setting.key] = setting.value
                moduleIDs[setting.key] = module.moduleID
            }
        }
    }

    var isEmpty: Bool { values.isEmpty }

     
    func bool(_ key: AdBlockDeviceSettingKey, else app: Bool) -> Bool {
        guard let written = values[key] else { return app }
        return AdBlockSettingsMapping.boolean(written) ?? app
    }

    func string(_ key: AdBlockDeviceSettingKey, else app: String) -> String {
        values[key] ?? app
    }

     

     
    static func file(in locations: AdBlockModuleLocations) -> URL {
        locations.container.appendingPathComponent(ClashTunnelRouteShaping.moduleDeviceSettingsPath)
    }

     
     
     
     
     
     
    static func load(locations: AdBlockModuleLocations? = .production) -> AdBlockDeviceSettingOverlay {
        guard let locations else { return AdBlockDeviceSettingOverlay() }
        let url = file(in: locations)
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let kept = Cache.shared.overlay(at: url, date: date) { return kept }
        let overlay = date == nil ? AdBlockDeviceSettingOverlay() : read(url)
        Cache.shared.keep(overlay, at: url, date: date)
        return overlay
    }

    private static func read(_ url: URL) -> AdBlockDeviceSettingOverlay {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return AdBlockDeviceSettingOverlay() }
        var overlay = AdBlockDeviceSettingOverlay()
        for (name, value) in object {
            guard let key = AdBlockDeviceSettingKey(rawValue: name) else { continue }
            overlay.values[key] = value
        }
        return overlay
    }

     
    private final class Cache: @unchecked Sendable {
        static let shared = Cache()
        private let lock = NSLock()
        private var kept: [URL: (date: Date?, overlay: AdBlockDeviceSettingOverlay)] = [:]

        func overlay(at url: URL, date: Date?) -> AdBlockDeviceSettingOverlay? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = kept[url], entry.date == date else { return nil }
            return entry.overlay
        }

        func keep(_ overlay: AdBlockDeviceSettingOverlay, at url: URL, date: Date?) {
            lock.lock()
            kept[url] = (date, overlay)
            lock.unlock()
        }
    }

     
     
     
    func publish(to locations: AdBlockModuleLocations) throws {
        let url = Self.file(in: locations)
        defer {
            let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            Cache.shared.keep(date == nil ? AdBlockDeviceSettingOverlay() : Self.read(url), at: url, date: date)
        }
        guard !values.isEmpty else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        let object = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if (try? Data(contentsOf: url)) == data { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

extension VPNTunnelSettings {
     
     
    func overlaid(by overlay: AdBlockDeviceSettingOverlay) -> VPNTunnelSettings {
        guard !overlay.isEmpty else { return self }
        var out = self
        out.includeAllNetworks = overlay.bool(.includeAllNetworks, else: includeAllNetworks)
        out.includeLocalNetworks = overlay.bool(.includeLocalNetworks, else: includeLocalNetworks)
        out.includeAPNs = overlay.bool(.includeAPNs, else: includeAPNs)
#if !os(macOS)
        out.includeCellularServices = overlay.bool(.includeCellularServices, else: includeCellularServices)
#endif
        out.hideVPNIcon = overlay.bool(.hideVPNIcon, else: hideVPNIcon)
        out.homeKitCompatibility = overlay.bool(.homeKitCompatibility, else: homeKitCompatibility)
        return out
    }
}

extension DelayTestSettings {
     
     
     
    static func effectiveURL(from defaults: UserDefaults = appGroupDefaults,
                             overlay: AdBlockDeviceSettingOverlay = .load()) -> String {
        if let written = overlay.values[.testURL], isValid(written) { return written }
        return url(from: defaults)
    }
}
