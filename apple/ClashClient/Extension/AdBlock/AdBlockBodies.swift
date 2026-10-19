#if os(iOS) || os(macOS)
import Compression
import Darwin
import Foundation
import zlib

 
 
 
 
 
 
 

enum AdBlockContentCoding: Equatable, Sendable {
    case identity
    case gzip
    case deflate
    case brotli
    case unsupported(String)

     
    static func parse(_ header: String?) -> [AdBlockContentCoding] {
        guard let header else { return [] }
        return header.split(separator: ",").compactMap { raw in
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "", "identity": return nil
            case "gzip", "x-gzip": return .gzip
            case "deflate": return .deflate
            case "br": return .brotli
            case let other: return .unsupported(other)
            }
        }
    }
}

struct AdBlockDecodeResult: Equatable, Sendable {
    let data: Data
     
    let outputLimitExceeded: Bool
}

enum AdBlockBodyDecoderError: Error, Equatable, Sendable {
    case corrupt(String)
    case unsupported(String)
     
    case windowTooLarge(Int)

     
    var reason: String {
        switch self {
        case .corrupt(let why): return "corrupt: \(why)"
        case .unsupported(let coding): return "\(coding) is not decoded"
        case .windowTooLarge(let window): return "its brotli window is \(window) bytes"
        }
    }
}

enum AdBlockBodyDecoder {
    static let chunkSize = 32 * 1024

     
     
     
    static func decode(_ body: Data, coding: AdBlockContentCoding, maximumOutputLength: Int) throws -> AdBlockDecodeResult {
        let maximumOutputLength = max(0, maximumOutputLength)
        switch coding {
        case .identity:
            return AdBlockDecodeResult(data: Data(body.prefix(maximumOutputLength)), outputLimitExceeded: body.count > maximumOutputLength)
        case .gzip:
            return try inflateBody(body, windowBits: 15 + 16, maximumOutputLength: maximumOutputLength)
        case .deflate:
            do {
                return try inflateBody(body, windowBits: 15, maximumOutputLength: maximumOutputLength)
            } catch AdBlockBodyDecoderError.corrupt {
                 
                return try inflateBody(body, windowBits: -15, maximumOutputLength: maximumOutputLength)
            }
        case .brotli:
            return try brotliBody(body, maximumOutputLength: maximumOutputLength)
        case .unsupported(let name):
            throw AdBlockBodyDecoderError.unsupported(name)
        }
    }

     
     
    static func brotliWindowBytes(_ body: Data) -> Int? {
        guard let first = body.first else { return nil }
        let windowBits: Int
        if first & 0x01 == 0 {
            windowBits = 16
        } else if Int(first >> 1) & 0x07 != 0 {
            windowBits = 17 + Int(first >> 1) & 0x07
        } else {
            let extended = Int(first >> 4) & 0x07
            if extended == 1 { return nil }
            windowBits = extended == 0 ? 17 : 8 + extended
        }
        return (1 << windowBits) - 16
    }

    private static func inflateBody(_ body: Data, windowBits: Int32, maximumOutputLength: Int) throws -> AdBlockDecodeResult {
         
        let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        stream.initialize(to: z_stream())
        defer {
            stream.deinitialize(count: 1)
            stream.deallocate()
        }
        guard inflateInit2_(stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw AdBlockBodyDecoderError.corrupt("zlib could not start")
        }
        defer { inflateEnd(stream) }
        let chunk = UnsafeMutablePointer<Bytef>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }
        var output = Data()
        var exceeded = false
        var status: Int32 = Z_OK
         
        body.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            stream.pointee.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
            stream.pointee.avail_in = uInt(source.count)
            reading: while true {
                stream.pointee.next_out = chunk
                stream.pointee.avail_out = uInt(chunkSize)
                status = zlib.inflate(stream, Z_NO_FLUSH)
                let produced = chunkSize - Int(stream.pointee.avail_out)
                if output.count + produced > maximumOutputLength {
                    exceeded = true
                    break reading
                }
                output.append(chunk, count: produced)
                switch status {
                case Z_OK:
                     
                    continue
                case Z_STREAM_END where windowBits > 15 && stream.pointee.avail_in > 0:
                     
                    guard inflateReset(stream) == Z_OK else {
                        status = Z_STREAM_ERROR
                        break reading
                    }
                default:
                    break reading
                }
            }
        }
        if exceeded { return AdBlockDecodeResult(data: output, outputLimitExceeded: true) }
        guard status == Z_STREAM_END else { throw AdBlockBodyDecoderError.corrupt("zlib status \(status)") }
        return AdBlockDecodeResult(data: output, outputLimitExceeded: false)
    }

    private static func brotliBody(_ body: Data, maximumOutputLength: Int) throws -> AdBlockDecodeResult {
        guard let window = brotliWindowBytes(body) else { throw AdBlockBodyDecoderError.corrupt("not a brotli stream") }
        guard window <= maximumOutputLength else { throw AdBlockBodyDecoderError.windowTooLarge(window) }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI) == COMPRESSION_STATUS_OK else {
            throw AdBlockBodyDecoderError.unsupported("br")
        }
        defer { compression_stream_destroy(stream) }
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }
        var output = Data()
        var exceeded = false
        var status = COMPRESSION_STATUS_OK
        body.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = source.count
             
             
            repeat {
                stream.pointee.dst_ptr = chunk
                stream.pointee.dst_size = chunkSize
                status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - stream.pointee.dst_size
                if output.count + produced > maximumOutputLength {
                    exceeded = true
                    break
                }
                output.append(chunk, count: produced)
            } while status == COMPRESSION_STATUS_OK
        }
        if exceeded { return AdBlockDecodeResult(data: output, outputLimitExceeded: true) }
        guard status == COMPRESSION_STATUS_END else { throw AdBlockBodyDecoderError.corrupt("brotli") }
        return AdBlockDecodeResult(data: output, outputLimitExceeded: false)
    }
}

 
 
 
 
struct AdBlockBodyLimits: Equatable, Sendable {
     
    var maximumBytes: Int
    var maximumConcurrent: Int
     
    var spillAbove: Int?

     
    static let iOS = AdBlockBodyLimits(maximumBytes: 256 * 1024, maximumConcurrent: 4, spillAbove: nil)
     
    static let macOS = AdBlockBodyLimits(maximumBytes: 10 * 1024 * 1024, maximumConcurrent: 4, spillAbove: 1024 * 1024)

    static var current: AdBlockBodyLimits {
        #if os(macOS)
        return .macOS
        #else
        return .iOS
        #endif
    }
}

 
enum AdBlockBodySkip: Error, Equatable, Sendable {
    case tooManyAtOnce(Int)
    case declaredTooLarge(Int64, Int)
    case grewTooLarge(Int)
     
    case spillFailed
    case decodedTooLarge(Int)
    case notDecodable(String)
    case notText
    case bodiesStopped
    case scriptsStopped
     
     
    case partialContent

     
    var isOverALimit: Bool {
        switch self {
        case .declaredTooLarge, .grewTooLarge, .decodedTooLarge: return true
        default: return false
        }
    }

    var description: String {
        switch self {
        case .tooManyAtOnce(let count): return "\(count) bodies are already held"
        case .declaredTooLarge(let length, let limit): return "Content-Length \(length) is over the \(limit)-byte limit"
        case .grewTooLarge(let limit): return "the body grew past the \(limit)-byte limit"
        case .spillFailed: return "the disk would not hold it while it was collected"
        case .decodedTooLarge(let limit): return "it decodes past the \(limit)-byte limit"
        case .notDecodable(let why): return "its encoding cannot be read here (\(why))"
        case .notText: return "it is not UTF-8 text"
        case .bodiesStopped: return "body changes are paused for memory"
        case .scriptsStopped: return "scripts are paused"
        case .partialContent: return "it is a part of a body (206 or Content-Range), which is never rewritten"
        }
    }
}

 
 
 
 
final class AdBlockBodyBudget {
    let limits: AdBlockBodyLimits
    private let metrics: AdBlockEngineMetrics
    private let spillDirectory: URL?
    private(set) var active = 0

    init(limits: AdBlockBodyLimits, metrics: AdBlockEngineMetrics, spillDirectory: URL?) {
        self.limits = limits
        self.metrics = metrics
        self.spillDirectory = spillDirectory
    }

     
     
     
     
     
    func begin(declaredLength: Int64?, maximum: Int?, atOnce: Int? = nil) -> Result<AdBlockBodyCollection, AdBlockBodySkip> {
        let asked = maximum.flatMap { $0 > 0 ? $0 : nil }
        let limit = min(asked ?? limits.maximumBytes, limits.maximumBytes)
        if let declaredLength, declaredLength > Int64(limit) { return .failure(metrics.skipped(.declaredTooLarge(declaredLength, limit))) }
        let concurrent = min(limits.maximumConcurrent, atOnce ?? limits.maximumConcurrent)
        guard active < concurrent else { return .failure(metrics.skipped(.tooManyAtOnce(active))) }
        active += 1
        metrics.update { $0.bodyCollectionsTotal += 1 }
        return .success(AdBlockBodyCollection(limit: limit, spillAbove: limits.spillAbove, spillDirectory: spillDirectory,
                                              metrics: metrics) { [weak self] in self?.active -= 1 })
    }

     
     
    func decode(_ body: Data, coding: AdBlockContentCoding, maximumOutputLength: Int) -> Result<Data, AdBlockBodySkip> {
        do {
            let decoded = try AdBlockBodyDecoder.decode(body, coding: coding, maximumOutputLength: maximumOutputLength)
            guard !decoded.outputLimitExceeded else { return .failure(metrics.skipped(.decodedTooLarge(max(0, maximumOutputLength)))) }
            return .success(decoded.data)
        } catch let error as AdBlockBodyDecoderError {
            return .failure(metrics.skipped(.notDecodable(error.reason)))
        } catch {
            return .failure(metrics.skipped(.notDecodable("\(error)")))
        }
    }
}

extension AdBlockEngineMetrics {
     
    fileprivate func skipped(_ why: AdBlockBodySkip) -> AdBlockBodySkip {
        update {
            $0.bodySkippedTotal += 1
            if why.isOverALimit { $0.bodyLimitExceeded += 1 }
        }
        return why
    }
}

 
 
 
final class AdBlockHeldBody {
    private var bytes: Data?
    private var giveBack: (() -> Void)?

    fileprivate init(_ bytes: Data, giveBack: @escaping () -> Void) {
        self.bytes = bytes
        self.giveBack = giveBack
    }

     
    func take() -> Data {
        defer { bytes = nil }
        return bytes ?? Data()
    }

    var isReleased: Bool { giveBack == nil }

    func release() {
        bytes = nil
        let pending = giveBack
        giveBack = nil
        pending?()
    }

    deinit { release() }
}

 
enum AdBlockBodyCollected {
    case memory(Data)
     
    case spilled(AdBlockSpillReader)
}

 
 
final class AdBlockSpillReader {
    static let piece = 64 * 1024
     
    let count: Int
    private var handle: FileHandle?
    private let file: URL
    private var offset = 0
     
    private(set) var largestRead = 0

    fileprivate init(handle: FileHandle, file: URL, count: Int) {
        self.handle = handle
        self.file = file
        self.count = count
    }

    deinit { close() }

     
     
     
     
    func next() -> Data? {
        guard let handle else { return nil }
        guard offset < count else { return Data() }
        let wanted = min(Self.piece, count - offset)
        let read: Data? = autoreleasepool {
            do {
                if offset == 0 { try handle.seek(toOffset: 0) }
                guard let data = try handle.read(upToCount: wanted), data.count == wanted else { return nil }
                return Data(data)
            } catch {
                return nil
            }
        }
        guard let read else { return nil }
        offset += wanted
        largestRead = max(largestRead, wanted)
        return read
    }

    func close() {
        guard let handle else { return }
        self.handle = nil
        try? handle.close()
        try? FileManager.default.removeItem(at: file)
    }
}

 
final class AdBlockBodyCollection {
    let limit: Int
    private(set) var count = 0
    private let spillAbove: Int?
    private let spillDirectory: URL?
    private let metrics: AdBlockEngineMetrics
    private var release: (() -> Void)?
    private var memory = Data()
     
    private var spillTried = false
    private var spillFile: URL?
    private var spillHandle: FileHandle?
     
    private var spilled = 0
     
     
    private(set) var refusal: AdBlockBodySkip?

    fileprivate init(limit: Int, spillAbove: Int?, spillDirectory: URL?, metrics: AdBlockEngineMetrics, release: @escaping () -> Void) {
        self.limit = limit
        self.spillAbove = spillAbove
        self.spillDirectory = spillDirectory
        self.metrics = metrics
        self.release = release
    }

    deinit { end() }

     
     
     
    func append<Bytes: DataProtocol>(_ data: Bytes) -> Bool {
        guard release != nil, refusal == nil else { return false }
        guard count + data.count <= limit else { return refuse(.grewTooLarge(limit)) }
        if spillHandle == nil, !spillTried, let threshold = spillAbove, let directory = spillDirectory, memory.count + data.count > threshold {
            spillTried = true
            startSpilling(in: directory)
        }
        if let spillHandle {
            do {
                try spillHandle.write(contentsOf: data)
            } catch {
                return refuse(.spillFailed)
            }
            spilled += data.count
            count += data.count
            metrics.update { $0.bodyCollectBytesTotal += data.count }
        } else {
            memory.append(contentsOf: data)
            count += data.count
            metrics.update {
                $0.bodyCollectBytesTotal += data.count
                $0.bodyCollectBytes += data.count
                $0.bodyCollectBytesPeak = max($0.bodyCollectBytesPeak, $0.bodyCollectBytes)
            }
        }
        return true
    }

     
     
     
     
    func finish() -> Data? {
        guard refusal == nil else { return nil }
        return giveBack()
    }

     
     
    func abandon() -> Data? { giveBack() }

     
     
     
     
     
    func giveWay() -> AdBlockBodyCollected? {
        guard release != nil else { return nil }
        guard let handle = spillHandle, let file = spillFile else {
            let bytes = memory
            end()
            return .memory(bytes)
        }
         
        spillHandle = nil
        spillFile = nil
        let reader = AdBlockSpillReader(handle: handle, file: file, count: spilled)
        end()
        return .spilled(reader)
    }

     
    func discard() { end() }

     
     
     
     
     
     
    func finishHeld() -> AdBlockHeldBody? {
        guard refusal == nil, let slot = release else { return nil }
        let bytes: Data
        if spillHandle == nil {
            bytes = memory
        } else {
            guard let read = spilledBytes() else {
                end()
                return nil
            }
            bytes = read
            metrics.update {
                $0.bodyCollectBytes += read.count
                $0.bodyCollectBytesPeak = max($0.bodyCollectBytesPeak, $0.bodyCollectBytes)
            }
        }
         
        release = nil
        memory = Data()
        try? spillHandle?.close()
        spillHandle = nil
        if let spillFile { try? FileManager.default.removeItem(at: spillFile) }
        spillFile = nil
        let metrics = self.metrics
        let counted = bytes.count
        return AdBlockHeldBody(bytes) {
            metrics.update { $0.bodyCollectBytes -= counted }
            slot()
        }
    }

    private func refuse(_ why: AdBlockBodySkip) -> Bool {
        refusal = metrics.skipped(why)
        return false
    }

    private func giveBack() -> Data? {
        guard release != nil else { return nil }
        let bytes = spillHandle == nil ? memory : spilledBytes()
        end()
        return bytes
    }

     
     
    private func startSpilling(in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(UUID().uuidString + ".body")
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            try handle.write(contentsOf: memory)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
            return
        }
        spillFile = file
        spillHandle = handle
        spilled = memory.count
        metrics.update { $0.bodyCollectBytes -= memory.count }
        memory = Data()
    }

    private func spilledBytes() -> Data? {
        guard let spillHandle else { return nil }
        do {
            try spillHandle.seek(toOffset: 0)
            let bytes = try spillHandle.read(upToCount: spilled) ?? Data()
            return bytes.count == spilled ? bytes : nil
        } catch {
            return nil
        }
    }

    private func end() {
        guard let release else { return }
        self.release = nil
        metrics.update { $0.bodyCollectBytes -= memory.count }
        memory = Data()
        try? spillHandle?.close()
        spillHandle = nil
        if let spillFile { try? FileManager.default.removeItem(at: spillFile) }
        spillFile = nil
        release()
    }
}
#endif
