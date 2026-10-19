#if os(iOS) || os(macOS)
import Foundation

 
 
 
 
 
 
 
 
 
enum AdBlockDecryptionChoice: String, Codable, Equatable, Sendable {
    case followsTrust
    case offByReader

    private struct Record: Codable {
        let choice: AdBlockDecryptionChoice
        let at: Date
    }

    static func file(_ locations: AdBlockEngineLocations) -> URL {
        locations.stateDirectory.appendingPathComponent("decryption-choice.json")
    }

     
    static func read(_ locations: AdBlockEngineLocations) -> AdBlockDecryptionChoice? {
        AdBlockEngineFiles.read(Record.self, from: file(locations), maximumBytes: 1_024)?.choice
    }

    static func record(_ choice: AdBlockDecryptionChoice, in locations: AdBlockEngineLocations, at now: Date = Date()) {
        guard read(locations) != choice,
              let data = try? AdBlockJSON.encoder().encode(Record(choice: choice, at: now)) else { return }
        try? AdBlockEngineFiles.write(data, to: file(locations))
    }
}
#endif
