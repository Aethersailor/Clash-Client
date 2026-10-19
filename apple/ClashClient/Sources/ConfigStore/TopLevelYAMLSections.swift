import Foundation

 
 
 
 
 
 
 
 
 
 
 
 
 
enum TopLevelYAMLSections {
     
    struct Cut {
         
        let rest: String
         
         
         
        let sections: [(key: String, text: String)]
         
         
        let following: [String: [String]]

         
         
         
         
        func splicing(into restYAML: String) -> String? {
            var result = restYAML
             
             
            if result.trimmingCharacters(in: .whitespacesAndNewlines) == "{}" { result = "" }
             
             
            guard let written = TopLevelYAMLSections.keyLines(of: result) else { return nil }
            if sections.contains(where: { section in written.contains { $0.key == section.key } }) {
                return nil
            }
             
             
            for section in sections.reversed() {
                let lines = TopLevelYAMLSections.keyLines(of: result)
                let followers = following[section.key] ?? []
                let at = lines.flatMap { lines in
                    followers.lazy.compactMap { follower in lines.first { $0.key == follower }?.offset }.first
                }
                if let at {
                     
                     
                     
                     
                    guard section.text.hasSuffix("\n") else { return nil }
                    let index = result.utf8.index(result.utf8.startIndex, offsetBy: at)
                    result.insert(contentsOf: section.text, at: index)
                } else {
                    if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
                    result += section.text
                }
            }
            return result
        }
    }

     
     
    static func cutting(_ keys: Set<String>, from yaml: String) -> Cut? {
        var text = yaml
        let bytes = text.withUTF8 { Array($0) }
        guard let lines = keyLines(bytes) else { return nil }
        let present = lines.filter { keys.contains($0.key) }
        guard !present.isEmpty else { return nil }
        var sections: [(key: String, text: String)] = []
        var following: [String: [String]] = [:]
        var rest: [UInt8] = []
        rest.reserveCapacity(bytes.count)
        var cursor = 0
        for (index, line) in lines.enumerated() where keys.contains(line.key) {
            let end = index + 1 < lines.count ? lines[index + 1].offset : bytes.count
            let section = bytes[line.offset..<end]
             
             
             
            guard !mentionsAnchorOrAlias(section) else { return nil }
            rest.append(contentsOf: bytes[cursor..<line.offset])
            cursor = end
             
             
             
            sections.append((line.key, String(decoding: section, as: UTF8.self)))
            following[line.key] = lines[(index + 1)...].map(\.key).filter { !keys.contains($0) }
        }
        rest.append(contentsOf: bytes[cursor...])
        text = String(decoding: rest, as: UTF8.self)
        return Cut(rest: text, sections: sections, following: following)
    }

    struct KeyLine: Equatable {
        let key: String
         
        let offset: Int
    }

     
     
    static func keyLines(of yaml: String) -> [KeyLine]? {
        var text = yaml
        return text.withUTF8 { keyLines(Array($0)) }
    }

    private static func keyLines(_ bytes: [UInt8]) -> [KeyLine]? {
        var lines: [KeyLine] = []
        var seen = Set<String>()
        var sawDocumentStart = false
        var start = 0
        let count = bytes.count
        while start < count {
            var end = start
            while end < count, bytes[end] != UInt8(ascii: "\n") { end += 1 }
            defer { start = end + 1 }
            let first = bytes[start]
            switch first {
            case UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: " "), UInt8(ascii: "#"):
                 
                continue
            case UInt8(ascii: "\t"), UInt8(ascii: "%"), UInt8(ascii: "."):
                return nil
            case UInt8(ascii: "-"):
                if isMarker(bytes, start, end, "---") {
                     
                     
                    guard lines.isEmpty, !sawDocumentStart, isBareMarker(bytes, start, end) else { return nil }
                    sawDocumentStart = true
                    continue
                }
                 
                 
                guard !lines.isEmpty else { return nil }
                continue
            default:
                guard let key = plainKey(bytes, start, end), key != "<<", seen.insert(key).inserted else { return nil }
                lines.append(KeyLine(key: key, offset: start))
            }
        }
        return lines
    }

     
    private static func isMarker(_ bytes: [UInt8], _ start: Int, _ end: Int, _ marker: String) -> Bool {
        let mark = Array(marker.utf8)
        guard end - start >= mark.count, Array(bytes[start..<(start + mark.count)]) == mark else { return false }
        let after = start + mark.count
        return after == end || [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r")].contains(bytes[after])
    }

    private static func isBareMarker(_ bytes: [UInt8], _ start: Int, _ end: Int) -> Bool {
        var index = start + 3
        while index < end, [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r")].contains(bytes[index]) {
            index += 1
        }
        return index == end || bytes[index] == UInt8(ascii: "#")
    }

     
    private static func plainKey(_ bytes: [UInt8], _ start: Int, _ end: Int) -> String? {
        func isWord(_ byte: UInt8, first: Bool) -> Bool {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"):
                return true
            case UInt8(ascii: "-"), UInt8(ascii: "."):
                return !first
            default:
                return false
            }
        }
        var index = start
        while index < end, isWord(bytes[index], first: index == start) { index += 1 }
        guard index > start, index < end, bytes[index] == UInt8(ascii: ":") else { return nil }
        let after = index + 1
        guard after == end || [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r")].contains(bytes[after]) else {
            return nil
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

     
     
     
     
    private static func mentionsAnchorOrAlias(_ section: ArraySlice<UInt8>) -> Bool {
        let opens: Set<UInt8> = [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: ","),
                                 UInt8(ascii: "["), UInt8(ascii: "{"), UInt8(ascii: ":"), UInt8(ascii: "-")]
        let closes: Set<UInt8> = [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"),
                                  UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}")]
        var index = section.startIndex
        while index < section.endIndex {
            let byte = section[index]
            if byte == UInt8(ascii: "&") || byte == UInt8(ascii: "*") {
                let before = index == section.startIndex ? UInt8(ascii: "\n") : section[index - 1]
                let next = index + 1 < section.endIndex ? section[index + 1] : UInt8(ascii: "\n")
                if opens.contains(before), !closes.contains(next) { return true }
            }
            index += 1
        }
        return false
    }
}
