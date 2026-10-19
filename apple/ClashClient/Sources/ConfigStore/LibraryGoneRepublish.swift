import Foundation

 
 
 
 

 
 
 
 
enum LibraryGoneRepublish {
    static let markerKey = "node-library.republished-for"

     
    static func identity(of record: StartupOutcomeRecord) -> String {
        [record.at.map { String(Int64($0.timeIntervalSince1970)) } ?? "-",
         record.requested.map { $0.profileID + "/" + $0.revision } ?? "-",
         record.message ?? ""].joined(separator: "|")
    }

     
    static func owes(_ record: StartupOutcomeRecord?, answered: String?) -> Bool {
        guard let record, NodeLibraries.isUnavailable(record.message) else { return false }
        return identity(of: record) != answered
    }

     
     
     
     
    enum Action: Equatable {
        case reconnect, applyToRunningTunnel, republishOnly
    }

     
     
     
    static func action(for record: StartupOutcomeRecord, tunnelIsRunning: Bool,
                       readerStillWantsIt: Bool = true) -> Action {
        if tunnelIsRunning { return .applyToRunningTunnel }
        return record.operation == "start" && readerStillWantsIt ? .reconnect : .republishOnly
    }

     
     
    static let readerSentence = "Clash can reconnect once you open it"
}
