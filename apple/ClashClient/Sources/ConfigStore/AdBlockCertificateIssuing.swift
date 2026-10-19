#if os(iOS) || os(macOS)
import Foundation
import Security

 
 
 
 
 

enum AdBlockCertificateError: Error, Equatable {
    case invalidHostname(String)
    case encryptionFailed(Int32)
    case pkcs12ImportFailed(OSStatus)
    case noIdentity
    case keyRejected
    case keychain(OSStatus)

     
     
    enum Scope: Equatable, Sendable {
         
         
        case thisHost
         
         
        case structural
         
         
         
        case passing
    }

    var scope: Scope {
        switch self {
        case .invalidHostname: return .thisHost
        case .noIdentity, .keyRejected: return .structural
         
         
         
        case .pkcs12ImportFailed(let status): return status == errSecAllocate ? .passing : .structural
        case .keychain(let status): return status == errSecMissingEntitlement ? .structural : .passing
        case .encryptionFailed: return .passing
        }
    }

     
     
    static func scope(of error: Error) -> Scope {
        (error as? AdBlockCertificateError)?.scope ?? .passing
    }
}

 
struct AdBlockCAMaterial: Equatable, Sendable {
    let certificateDER: Data
    let privateKeyDER: Data
}

 
 
struct AdBlockLeafMaterial: Codable, Equatable, Sendable {
    let hostname: String
    let certificateDER: Data
     
    let pkcs12: Data
    let passphrase: String
     
    let privateKeyX963: Data
    let issuedAt: Date
    var notAfter: Date
}

 
 
 
protocol AdBlockCertificateIssuing: Sendable {
    func makeCA(now: Date) throws -> AdBlockCAMaterial
    func issueLeaf(hostname: String, ca: AdBlockCAMaterial, now: Date) throws -> AdBlockLeafMaterial
}

 
 
enum AdBlockIdentity {
    static func make(_ leaf: AdBlockLeafMaterial) throws -> SecIdentity {
        try identity(pkcs12: leaf.pkcs12, passphrase: leaf.passphrase,
                     certificateDER: leaf.certificateDER, privateKeyX963: leaf.privateKeyX963)
    }

     
     
     
     
     
    static func identity(pkcs12: Data, passphrase: String, certificateDER: Data, privateKeyX963: Data) throws -> SecIdentity {
        var options: [CFString: Any] = [kSecImportExportPassphrase: passphrase]
        #if os(macOS)
        if #available(macOS 15, *) {
            options[kSecImportToMemoryOnly] = true
        } else {
            return try keychainIdentity(certificateDER: certificateDER, privateKeyX963: privateKeyX963)
        }
        #endif
        var items: CFArray?
        let status = SecPKCS12Import(pkcs12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw AdBlockCertificateError.pkcs12ImportFailed(status) }
        guard let first = (items as? [[CFString: Any]])?.first,
              let identity = first[kSecImportItemIdentity]
        else { throw AdBlockCertificateError.noIdentity }
        return identity as! SecIdentity
    }

     
     
     
    static let keychainLabelPrefix = #"Clash Ad Block leaf "#

     
     
     
    static var keychainScope: [CFString: Any] {
        #if os(macOS)
        return [kSecUseDataProtectionKeychain: true]
        #else
        return [:]
        #endif
    }

     
    static var usesKeychainRoute: Bool {
        #if os(macOS)
        if #available(macOS 15, *) { return false }
        return true
        #else
        return false
        #endif
    }

     
     
     
     
     
     
     
     
     
    static func keychainIdentity(certificateDER: Data, privateKeyX963: Data,
                                 delete: (CFDictionary) -> OSStatus = SecItemDelete,
                                 leftBehind: (String) -> Void = { AdBlockKeychainLedger.process.noteLeftBehind($0) }) throws -> SecIdentity {
        guard let key = SecKeyCreateWithData(
                privateKeyX963 as CFData,
                [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                 kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, nil),
              let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData)
        else { throw AdBlockCertificateError.keyRejected }

        let scope = keychainScope
        let label = keychainLabelPrefix + UUID().uuidString
        let tag = Data(label.utf8)
        let items: [(add: [CFString: Any], match: [CFString: Any], what: String)] = [
            (add: [kSecClass: kSecClassKey, kSecValueRef: key, kSecAttrLabel: label, kSecAttrApplicationTag: tag,
                   kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly],
             match: [kSecClass: kSecClassKey, kSecAttrApplicationTag: tag], what: "key"),
            (add: [kSecClass: kSecClassCertificate, kSecValueRef: certificate, kSecAttrLabel: label,
                   kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly],
             match: [kSecClass: kSecClassCertificate, kSecAttrLabel: label], what: "certificate"),
        ]

         
        var added: [(match: [CFString: Any], what: String)] = []
        func removeAdded() -> [String] {
            added.compactMap { item in
                let status = delete(scope.merging(item.match) { $1 } as CFDictionary)
                return status == errSecSuccess || status == errSecItemNotFound ? nil : #"the \#(item.what) labelled \#(label) (\#(status))"#
            }
        }

        let identity: SecIdentity
        do {
            for item in items {
                let status = SecItemAdd(scope.merging(item.add) { $1 } as CFDictionary, nil)
                guard status == errSecSuccess else { throw AdBlockCertificateError.keychain(status) }
                added.append((item.match, item.what))
            }
            var result: CFTypeRef?
            let status = SecItemCopyMatching(scope.merging([
                kSecClass: kSecClassIdentity, kSecAttrLabel: label,
                kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitOne,
            ]) { $1 } as CFDictionary, &result)
            guard status == errSecSuccess, let found = result else {
                throw status == errSecItemNotFound ? AdBlockCertificateError.noIdentity : AdBlockCertificateError.keychain(status)
            }
            identity = found as! SecIdentity
        } catch {
             
             
            removeAdded().forEach { leftBehind(#"the keychain kept \#($0) after a failed leaf identity"#) }
            throw error
        }
        removeAdded().forEach { leftBehind(#"the keychain kept \#($0); the identity serves, the next sweep removes it"#) }
        return identity
    }

     
     
     
     
     
     
     
     
    static func sweepKeychainLeftovers() -> AdBlockKeychainSweepOutcome {
        #if os(macOS)
        let scope = keychainScope
        var removed = 0
        var problems: [String] = []
        for itemClass in [kSecClassKey, kSecClassCertificate, kSecClassGenericPassword] {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(scope.merging([
                kSecClass: itemClass, kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll,
            ]) { $1 } as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let items = result as? [[CFString: Any]] else {
                problems.append(#"listing \#(itemClass) failed (\#(status))"#)
                continue
            }
            for item in items {
                 
                if item[kSecAttrService] as? String == AdBlockCAKeychain.service { continue }
                guard let label = item[kSecAttrLabel] as? String, label.hasPrefix(keychainLabelPrefix) else { continue }
                let deleted = SecItemDelete(scope.merging([kSecClass: itemClass, kSecAttrLabel: label]) { $1 } as CFDictionary)
                if deleted == errSecSuccess {
                    removed += 1
                } else if deleted != errSecItemNotFound {
                    problems.append(#"\#(label) could not be deleted (\#(deleted))"#)
                }
            }
        }
        if removed == 0, problems.isEmpty, let noAccess = keychainAccessProblem(scope) { problems.append(noAccess) }
        return problems.isEmpty ? .swept(removed: removed) : .failed(problems.joined(separator: "; "))
        #else
        return .swept(removed: 0)
        #endif
    }

     
     
     
    static func keychainAccessProblem(_ scope: [CFString: Any]) -> String? {
        let label = keychainLabelPrefix + #"probe "# + UUID().uuidString
        let match: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrLabel: label,
                                      kSecAttrService: label, kSecAttrAccount: label]
        let added = SecItemAdd(scope.merging(match.merging([
            kSecValueData: Data(), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 }) { $1 } as CFDictionary, nil)
        if added == errSecMissingEntitlement { return #"this process has no keychain access group (\#(added))"# }
        guard added == errSecSuccess else { return #"the keychain could not be checked (\#(added))"# }
        let deleted = SecItemDelete(scope.merging(match) { $1 } as CFDictionary)
        return deleted == errSecSuccess || deleted == errSecItemNotFound ? nil : #"the keychain probe could not be deleted (\#(deleted))"#
    }
}

 
enum AdBlockKeychainSweepOutcome: Equatable, Sendable {
    case swept(removed: Int)
     
    case skipped
     
    case failed(String)
}

 
 
 
 
 
final class AdBlockKeychainLedger: @unchecked Sendable {
    static let process = AdBlockKeychainLedger()

    private let lock = NSLock()
    private var leased = false
    private var residue: [String] = []

    init() {}

     
    func noteLease() {
        lock.lock()
        leased = true
        lock.unlock()
    }

    func sweepIfNoLease() -> AdBlockKeychainSweepOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard !leased else { return .skipped }
        return AdBlockIdentity.sweepKeychainLeftovers()
    }

     
    func noteLeftBehind(_ what: String) {
        lock.lock()
        residue.append(what)
        if residue.count > 64 { residue.removeFirst(residue.count - 64) }
        lock.unlock()
    }

    func takeLeftBehind() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let taken = residue
        residue = []
        return taken
    }
}

 
 
 
 
enum AdBlockPrivateFile {
     
     
    static let temporarySuffix = ".tmp"

    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
         
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString)" + temporarySuffix)
        try create(data, at: temporary)
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            let code = errno
            Darwin.unlink(temporary.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

     
     
     
     
    static func sweep(_ directory: URL, olderThan age: TimeInterval = 60, now: Date = Date()) {
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
            where name.hasPrefix(".") && name.hasSuffix(temporarySuffix) {
            let url = directory.appendingPathComponent(name)
            guard let modified = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) >= age else { continue }
            try? manager.removeItem(at: url)
        }
    }

     
    static func create(_ data: Data, at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: Int32 = 0
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        if failure == 0, Darwin.fsync(descriptor) != 0 { failure = errno }
        Darwin.close(descriptor)
        guard failure == 0 else {
            Darwin.unlink(url.path)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        #if os(iOS)
         
         
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: url.path)
        #endif
    }
}

 
 
 
 
 
 
 
 
 
 
 
 
enum AdBlockCAFiles {
     
     
    static let maximumBytes = 16 * 1024

    enum Status: Equatable, Sendable {
         
        case absent
        case ready(AdBlockCAMaterial, metadata: AdBlockCAMetadata)
         
         
        case needsRegeneration(String)
         
         
         
        case unavailable(String)
    }

    static func status(_ locations: AdBlockEngineLocations) -> Status {
         
        AdBlockPrivateFile.sweep(locations.certificateDirectory)
        let metadata: AdBlockCAMetadata
        switch AdBlockEngineFiles.bounded(locations.caMetadata, maximumBytes: maximumBytes) {
        case .absent: return .absent
        case .tooLarge: return .needsRegeneration(#"ca.json is larger than \#(maximumBytes) bytes"#)
        case .failed(let why): return .unavailable(#"ca.json could not be read: \#(why)"#)
        case .data(let data):
            guard let decoded = try? AdBlockJSON.decoder().decode(AdBlockCAMetadata.self, from: data) else {
                return .needsRegeneration(#"ca.json is not a CA's metadata"#)
            }
            metadata = decoded
        }
        guard metadata.schemaVersion == AdBlockCAMetadata.currentSchemaVersion else {
            return .needsRegeneration(#"ca.json is schema \#(metadata.schemaVersion)"#)
        }
        let certificate: Data
        switch AdBlockEngineFiles.bounded(locations.caCertificate, maximumBytes: maximumBytes) {
        case .data(let data): certificate = data
        case .absent: return .needsRegeneration(#"ca.der is missing"#)
        case .tooLarge: return .needsRegeneration(#"ca.der is larger than \#(maximumBytes) bytes"#)
        case .failed(let why): return .unavailable(#"ca.der could not be read: \#(why)"#)
        }
        guard AdBlockCertificateFingerprint.sha256(certificate) == metadata.fingerprintSHA256 else {
            return .needsRegeneration(#"ca.der is not the certificate ca.json names"#)
        }
        let key: Data
        switch privateKey(locations) {
        case .data(let data): key = data
         
         
         
         
         
        case .absent where locations.caKeyPlace != .file:
            guard case .keychain(let group) = locations.caKeyPlace else { return .needsRegeneration(#"the CA's private key is missing"#) }
            if let problem = AdBlockIdentity.keychainAccessProblem([kSecUseDataProtectionKeychain: true, kSecAttrAccessGroup: group]) {
                return .unavailable(#"the keychain shows no private key for the CA ca.json names, and cannot be reached (\#(problem))"#)
            }
            return .needsRegeneration(#"the CA key is gone from a reachable keychain"#)
        case .absent: return .needsRegeneration(#"the CA's private key is missing"#)
        case .tooLarge: return .needsRegeneration(#"the CA's private key is larger than \#(maximumBytes) bytes"#)
        case .failed(let why): return .unavailable(#"the CA's private key could not be read: \#(why)"#)
        }
        guard let keyDigest = metadata.privateKeySHA256 else {
            return .needsRegeneration(#"ca.json names no digest for the private key"#)
        }
        guard AdBlockJSON.sha256(key) == keyDigest else {
            return .needsRegeneration(#"the CA's private key is not the one ca.json names"#)
        }
        guard keyMatchesCertificate(privateKeyDER: key, certificateDER: certificate) else {
            return .needsRegeneration(#"the CA's private key is not the key of its certificate"#)
        }
        return .ready(AdBlockCAMaterial(certificateDER: certificate, privateKeyDER: key), metadata: metadata)
    }

     
    static func load(_ locations: AdBlockEngineLocations) -> (material: AdBlockCAMaterial, fingerprint: String)? {
        guard case .ready(let material, let metadata) = status(locations) else { return nil }
        return (material, metadata.fingerprintSHA256)
    }

     
     
    static func privateKey(_ locations: AdBlockEngineLocations) -> AdBlockEngineFiles.Bounded {
        switch locations.caKeyPlace {
        case .file: return AdBlockEngineFiles.bounded(locations.caPrivateKey, maximumBytes: maximumBytes)
        case .keychain: return AdBlockCAKeychain.read(locations, maximumBytes: maximumBytes)
        }
    }

     
     
     
     
    private static func writePrivateKey(_ key: Data, _ locations: AdBlockEngineLocations, log: (String) -> Void) throws {
        switch locations.caKeyPlace {
        case .file:
            try AdBlockPrivateFile.write(key, to: locations.caPrivateKey)
        case .keychain:
            try AdBlockCAKeychain.write(key, locations)
            guard FileManager.default.fileExists(atPath: locations.caPrivateKey.path) else { return }
            do {
                try FileManager.default.removeItem(at: locations.caPrivateKey)
            } catch {
                log(#"the CA key file an earlier build left (\#(locations.caPrivateKey.path)) could not be removed (\#(error)); the key in use is in the keychain"#)
            }
        }
    }

     
     
    @discardableResult
    static func write(_ material: AdBlockCAMaterial, createdAt: Date, to locations: AdBlockEngineLocations,
                      log: (String) -> Void = { _ in }) throws -> AdBlockCAMetadata {
        let commonName = SecCertificateCreateWithData(nil, material.certificateDER as CFData)
            .flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? ""
        let metadata = AdBlockCAMetadata(
            schemaVersion: AdBlockCAMetadata.currentSchemaVersion,
            fingerprintSHA256: AdBlockCertificateFingerprint.sha256(material.certificateDER), commonName: commonName,
            createdAt: createdAt, privateKeySHA256: AdBlockJSON.sha256(material.privateKeyDER))
        try writePrivateKey(material.privateKeyDER, locations, log: log)
        try AdBlockEngineFiles.write(material.certificateDER, to: locations.caCertificate)
        try AdBlockEngineFiles.write(try AdBlockJSON.encoder().encode(metadata), to: locations.caMetadata)
        return metadata
    }

     
     
     
    static func keyMatchesCertificate(privateKeyDER: Data, certificateDER: Data) -> Bool {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
              let published = SecCertificateCopyKey(certificate),
              let publishedBytes = SecKeyCopyExternalRepresentation(published, nil) as Data?,
              let type = (SecKeyCopyAttributes(published) as? [CFString: Any])?[kSecAttrKeyType],
              let privateKey = SecKeyCreateWithData(privateKeyDER as CFData, [
                  kSecAttrKeyType: type, kSecAttrKeyClass: kSecAttrKeyClassPrivate,
              ] as CFDictionary, nil),
              let derived = SecKeyCopyPublicKey(privateKey),
              let derivedBytes = SecKeyCopyExternalRepresentation(derived, nil) as Data? else { return false }
        return derivedBytes == publishedBytes
    }
}

 
 
 
 
 
 
 
enum AdBlockCAKeychain {
    static let service = "org.example.clash.adblock.ca-key"
    static let label = #"Clash Module CA private key"#

    private static func query(_ locations: AdBlockEngineLocations) -> [CFString: Any]? {
        guard case .keychain(let group) = locations.caKeyPlace else { return nil }
        return [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                kSecAttrAccount: locations.container.standardizedFileURL.path, kSecAttrAccessGroup: group,
                kSecUseDataProtectionKeychain: true, kSecAttrSynchronizable: false]
    }

    static func read(_ locations: AdBlockEngineLocations, maximumBytes: Int) -> AdBlockEngineFiles.Bounded {
        guard var query = query(locations) else { return .absent }
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .failed(#"the keychain item holds no data"#) }
            return data.count > maximumBytes ? .tooLarge(limit: maximumBytes) : .data(data)
        case errSecItemNotFound:
            return .absent
        default:
            return .failed(#"keychain status \#(status)"#)
        }
    }

     
    static func write(_ key: Data, _ locations: AdBlockEngineLocations) throws {
        guard let query = query(locations) else { return }
        let attributes: [CFString: Any] = [kSecValueData: key, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 }.merging([kSecAttrLabel: label]) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AdBlockCertificateError.keychain(status) }
    }

     
    static func delete(_ locations: AdBlockEngineLocations) {
        guard let query = query(locations) else { return }
        SecItemDelete(query as CFDictionary)
    }
}

enum AdBlockCertificateFingerprint {
     
    static func sha256(_ der: Data) -> String { AdBlockJSON.sha256(der) }
}
#endif
