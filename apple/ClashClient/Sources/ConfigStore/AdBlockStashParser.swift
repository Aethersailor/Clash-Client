import Foundation

 
 
 
 
 
 
 
 
 
 
 
 
enum AdBlockStashParser {
     
     
     
     
    private static let known: Set<String> = ["name", "desc", "author", "icon", "rules", "http", "script-providers", "rule-providers",
                                             "openUrl", "homepage", "category", "date", "version",
                                             "arguments", "arguments-version"]

     
     
     
     
     
     
     
    struct Arguments {
         
        var defaults: [String: OrderedJSON?] = [:]
         
        var overLimit = false

        init(_ value: OrderedJSON?) {
            guard case .object(let declared)? = value else { return }
            for (name, declaration) in declared {
                 
                var given: OrderedJSON?
                if case .object(let fields) = declaration { given = fields.first { $0.key == "default" }?.value }
                let size = name.utf8.count + 1 + (given.map { AdBlockStashParser.scalar($0) ?? $0.serialized() }?.utf8.count ?? 0)
                guard defaults.count < AdBlockModuleParser.maximumArguments, size <= AdBlockModuleParser.maximumArgumentBytes else {
                    overLimit = true
                    continue
                }
                guard case .object(let fields) = declaration else {
                    defaults[name] = .some(nil)
                    continue
                }
                let type = AdBlockStashParser.scalar(fields.first { $0.key == "type" }?.value)?.lowercased()
                switch fields.first(where: { $0.key == "default" })?.value {
                case .some(.scalar("null")), nil:
                    let fallback: OrderedJSON? = type == "switch" ? .scalar("false") : (type == "input" ? .string("") : nil)
                    defaults[name] = .some(fallback)
                case .some(let given):
                     
                     
                    let text = AdBlockStashParser.scalar(given) ?? given.serialized()
                    defaults[name] = text.contains("${args.") || text.contains("{{{") ? .some(nil) : .some(given)
                }
            }
        }

         
         
        func fill(_ value: OrderedJSON) -> Result<OrderedJSON, AdBlockIgnoredReason> {
            switch value {
            case .string(let text): return fill(text).map(OrderedJSON.string)
            case .scalar: return .success(value)
            case .array(let items):
                var out: [OrderedJSON] = []
                for item in items {
                    switch fill(item) {
                    case .success(let filled): out.append(filled)
                    case .failure(let reason): return .failure(reason)
                    }
                }
                return .success(.array(out))
            case .object(let pairs):
                var out: [(key: String, value: OrderedJSON)] = []
                for pair in pairs {
                    switch fill(pair.value) {
                    case .success(let filled): out.append((pair.key, filled))
                    case .failure(let reason): return .failure(reason)
                    }
                }
                return .success(.object(out))
            }
        }

        var declared: [AdBlockModuleArgument] {
            defaults.keys.sorted().map { name in
                AdBlockModuleArgument(name: name, defaultValue: defaults[name].flatMap { AdBlockStashParser.scalar($0) })
            }
        }

        private static let reference = try! NSRegularExpression(pattern: #"\$?\$\{args\.([^{}|\s]+)(\|json)?\}"#)

         
         
         
        func fill(_ text: String) -> Result<String, AdBlockIgnoredReason> {
            var out = text
             
             
            var unread = text
            var escaped = 0
            if text.contains("${args.") {
                let whole = NSRange(text.startIndex..., in: text)
                for match in Self.reference.matches(in: text, range: whole).reversed() {
                    if let range = Range(match.range, in: unread) { unread.removeSubrange(range) }
                    guard let range = Range(match.range, in: out), let nameRange = Range(match.range(at: 1), in: text) else { continue }
                    if text[range].hasPrefix("$$") {
                        out.replaceSubrange(range, with: String(text[range].dropFirst()))
                        escaped += 1
                        continue
                    }
                    let name = String(text[nameRange])
                    guard let declared = defaults[name], let value = declared else { return .failure(.missingArgument(name)) }
                    let asJSON = match.range(at: 2).location != NSNotFound
                    let written: String
                    switch value {
                    case .string(let string): written = asJSON ? OrderedJSON.string(string).serialized() : string
                    case .scalar(let token): written = token
                    default: return .failure(.missingArgument(name))
                    }
                    out.replaceSubrange(range, with: written)
                }
            }
            if let open = out.range(of: "{{{") {
                let close = out.range(of: "}}}", range: open.upperBound..<out.endIndex)?.lowerBound ?? out.endIndex
                return .failure(.missingArgument(String(out[open.upperBound..<close])))
            }
             
             
            if let reference = unread.range(of: "${args.") {
                return .failure(.missingArgument(String(unread[reference.upperBound...].prefix { !"}| ".contains($0) })))
            }
             
             
            if out.components(separatedBy: "${args.").count - 1 > escaped, let reference = out.range(of: "${args.") {
                return .failure(.missingArgument(String(out[reference.upperBound...].prefix { !"}| ".contains($0) })))
            }
            return .success(out)
        }
    }

    static func parse(_ text: String, manifest base: AdBlockModuleManifest, platform: AdBlockPlatform = .current,
                      check: AdBlockRuleMapping.Check = AdBlockRuleMapping.kernelCheck) throws -> Result<AdBlockModuleIR, AdBlockModuleRefusal> {
        let tree: OrderedJSON
        do {
            tree = try OrderedJSON.parse(try ConfigTransforms.yamlToJSON(text))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
             
             
            return .failure(.unreadableYAML(AdBlockModuleParser.prefix(error.localizedDescription, bytes: AdBlockModuleParser.maximumShownBytes)))
        }
        guard case .object(let root) = tree else { return .failure(.notAModule) }
        func value(_ key: String) -> OrderedJSON? { root.first { $0.key == key }?.value }

        var manifest = base
        manifest.format = .stash
         
         
        var longHeaders: [String] = []
        func header(_ key: String) -> String? {
            guard let text = scalar(value(key)) else { return nil }
            let cut = AdBlockModuleParser.prefix(text, bytes: key == "desc" ? AdBlockModuleParser.maximumDescriptionBytes
                                                                            : AdBlockModuleParser.maximumArgumentBytes)
            if cut.utf8.count < text.utf8.count { longHeaders.append(key) }
            return cut
        }
        manifest.name = header("name")
        manifest.desc = header("desc")
        manifest.author = header("author")
        manifest.icon = header("icon")
         
         
        manifest.category = header("category")
        manifest.openURL = header("openUrl")
        manifest.homepage = header("homepage")
        manifest.date = header("date")
        manifest.version = header("version")
        let arguments = Arguments(value("arguments"))
        manifest.arguments = arguments.declared
        var ir = AdBlockModuleIR.empty(manifest)
        for key in longHeaders {
            ir.ignored.append(AdBlockIgnoredEntry(text: key, reason: .headerOverLimit, origin: AdBlockLineOrigin(section: key, line: 0)))
        }
        if arguments.overLimit {
            ir.ignored.append(AdBlockIgnoredEntry(text: "arguments", reason: .argumentsOverLimit,
                                                  origin: AdBlockLineOrigin(section: "arguments", line: 0)))
        }

         
         
         
         
        var providerNames: Set<String> = []
        if let given = value("rule-providers") {
            let origin = AdBlockLineOrigin(section: "rule-providers", line: 0)
            switch arguments.fill(given) {
            case .success(.object(let pairs)):
                for (index, pair) in pairs.enumerated() {
                    let at = AdBlockLineOrigin(section: "rule-providers", line: index + 1)
                    switch AdBlockRuleSetSyntax.stashProvider(pair.key, pair.value, origin: at) {
                    case .success(let set):
                        AdBlockRuleSetSyntax.add(set, to: &ir.ruleSets)
                        providerNames.insert(pair.key)
                    case .failure(let reason):
                        ir.ignored.append(AdBlockIgnoredEntry(text: pair.key, reason: reason, origin: at))
                    }
                }
            case .success(let other):
                ir.ignored.append(AdBlockIgnoredEntry(text: other.serialized(), reason: .unreadableLine, origin: origin))
            case .failure(let reason):
                ir.ignored.append(AdBlockIgnoredEntry(text: "rule-providers", reason: reason, origin: origin))
            }
        }
         
         
         
        let directives = Self.directives(in: text)
        for (key, written) in root where !known.contains(key) {
            let origin = AdBlockLineOrigin(section: key, line: 0)
            guard AdBlockSettingsMapping.stashKeys.contains(key) || AdBlockSettingsMapping.stashMisplacedKeys.contains(key) else {
                ir.ignored.append(AdBlockIgnoredEntry(text: key, reason: .sectionNotSupported(key), origin: origin))
                continue
            }
            switch arguments.fill(written) {
            case .success(let filled):
                AdBlockSettingsMapping.take(AdBlockSettingsMapping.stash(key, value: filled, directives: directives, origin: origin,
                                                                         ruleProviders: providerNames),
                                            written: key, origin: origin, key: key, into: &ir)
            case .failure(let reason):
                ir.ignored.append(AdBlockIgnoredEntry(text: key, reason: reason, origin: origin))
            }
        }
         
         
         
         
         
         
         
        let appended = directives[["rules"]] == .append
        if let rules = value("rules") {
            for (index, item) in listItems(rules, section: "rules", into: &ir.ignored).enumerated() {
                let origin = AdBlockLineOrigin(section: "rules", line: index + 1)
                guard let written = item.text else {
                    ir.ignored.append(AdBlockIgnoredEntry(text: item.shown, reason: .unreadableLine, origin: origin))
                    continue
                }
                let line: String
                switch arguments.fill(written) {
                case .success(let filled): line = filled
                case .failure(let reason):
                    ir.ignored.append(AdBlockIgnoredEntry(text: written, reason: reason, origin: origin))
                    continue
                }
                 
                var mapped = try AdBlockRuleMapping.map(line, family: .stash, platform: platform, origin: origin, check: check)
                if appended {
                    switch mapped.outcome {
                    case .kernel(var rule):
                        rule.appended = true
                        mapped.outcome = .kernel(rule)
                    case .rewrite, .engine:
                         
                         
                         
                        mapped.outcome = .ignored(.settingNotSupported(#"rules: #!append"#))
                    case .ruleSet, .ignored:
                        break
                    }
                }
                let before = ir.routingRules.count
                AdBlockRuleMapping.take(mapped, written: line, origin: origin, into: &ir)
                 
                if appended, case .ruleSet = mapped.outcome {
                    for index in before..<ir.routingRules.count { ir.routingRules[index].appended = true }
                }
            }
        }
         
         
        for index in ir.ruleSets.indices where ir.ruleSets[index].name != nil {
            if let rule = ir.routingRules.first(where: { $0.head == ir.ruleSets[index].reference }) { ir.ruleSets[index].policy = rule.policy }
        }
        var providers: [(key: String, value: OrderedJSON)] = []
        if let given = value("script-providers") {
            if case .object(let pairs) = given {
                providers = pairs
            } else {
                ir.ignored.append(AdBlockIgnoredEntry(text: given.serialized(), reason: .unreadableLine,
                                                      origin: AdBlockLineOrigin(section: "script-providers", line: 0)))
            }
        }
        if let given = value("http") {
            guard case .object(let http) = given else {
                ir.ignored.append(AdBlockIgnoredEntry(text: given.serialized(), reason: .unreadableLine,
                                                      origin: AdBlockLineOrigin(section: "http", line: 0)))
                return .success(ir)
            }
            for (key, list) in http {
                let section = "http." + key
                switch key {
                case "mitm", "force-http-engine", "rewrite", "url-rewrite", "header-rewrite", "body-rewrite", "script", "mock":
                    break
                default:
                    ir.ignored.append(AdBlockIgnoredEntry(text: section, reason: .settingNotSupported(section),
                                                          origin: AdBlockLineOrigin(section: section, line: 0)))
                    continue
                }
                let items = listItems(list, section: section, into: &ir.ignored)
                 
                 
                let directive: AdBlockHostListDirective
                switch directives[["http", key]] {
                case .append?: directive = .append
                case .replace?: directive = .replace
                default: directive = .insert
                }
                switch key {
                case "mitm":
                    ir.mitmHostLines.append(hostLine(items, section: section, directive: directive, arguments: arguments,
                                                     ignored: &ir.ignored))
                case "force-http-engine":
                    ir.forceHTTPEngineHostLines.append(hostLine(items, section: section, directive: directive, arguments: arguments,
                                                                ignored: &ir.ignored))
                case "rewrite", "url-rewrite":
                    keep(items, section: section, arguments: arguments, into: &ir, AdBlockLineSyntax.urlRewrite)
                case "header-rewrite":
                    keep(items, section: section, arguments: arguments, into: &ir, AdBlockLineSyntax.headerRewrite)
                case "body-rewrite":
                    let moduleURL = ir.manifest.sourceURL
                    keepReadings(items, section: section, arguments: arguments, into: &ir) {
                        AdBlockLineSyntax.bodyRewriteReading($0, origin: $1, moduleURL: moduleURL)
                    }
                case "mock":
                    mocks(items, section: section, arguments: arguments, into: &ir)
                default:
                    scripts(items, providers: providers, section: section, arguments: arguments, into: &ir)
                }
            }
        }
        return .success(ir)
    }

     
     
    static func scalar(_ value: OrderedJSON?) -> String? {
        switch value {
        case .string(let text): return text
        case .scalar(let token): return token == "null" ? nil : token
        default: return nil
        }
    }

     
    private struct Item {
        var text: String?
        var shown: String
        var json: OrderedJSON
    }

     
     
    private static func listItems(_ value: OrderedJSON, section: String, into ignored: inout [AdBlockIgnoredEntry]) -> [Item] {
        guard case .array(let items) = value else {
            ignored.append(AdBlockIgnoredEntry(text: value.serialized(), reason: .unreadableLine,
                                               origin: AdBlockLineOrigin(section: section, line: 0)))
            return []
        }
        return items.map { Item(text: scalar($0), shown: $0.serialized(), json: $0) }
    }

    private static func hostLine(_ items: [Item], section: String, directive: AdBlockHostListDirective, arguments: Arguments,
                                 ignored: inout [AdBlockIgnoredEntry]) -> AdBlockHostListLine {
        var entries: [AdBlockHostEntry] = []
        for (index, item) in items.enumerated() {
            let origin = AdBlockLineOrigin(section: section, line: index + 1)
            guard let written = item.text else {
                ignored.append(AdBlockIgnoredEntry(text: item.shown, reason: .unreadableLine, origin: origin))
                continue
            }
            let text: String
            switch arguments.fill(written) {
            case .success(let filled): text = filled
            case .failure(let reason):
                ignored.append(AdBlockIgnoredEntry(text: written, reason: reason, origin: origin))
                continue
            }
            if let entry = AdBlockHostList.entry(text) {
                entries.append(entry)
            } else {
                ignored.append(AdBlockIgnoredEntry(text: text, reason: .invalidHost(text), origin: origin))
            }
        }
        return AdBlockHostListLine(directive: directive, entries: entries, origin: AdBlockLineOrigin(section: section, line: 0))
    }

     
     
     
     
    static func directives(in text: String) -> [[String]: AdBlockEditOperation] {
        var out: [[String]: AdBlockEditOperation] = [:]
        var stack: [(indent: Int, key: String)] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed == "---" { continue }
            let indent = line.prefix { $0 == " " }.count
            while let last = stack.last, last.indent >= indent { stack.removeLast() }
             
            if trimmed.hasPrefix("-") {
                stack.append((indent, "-"))
                continue
            }
            guard let colon = keyColon(in: trimmed) else { continue }
            var key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            if key.count >= 2, let first = key.first, first == "\"" || first == "'", key.last == first { key = String(key.dropFirst().dropLast()) }
            stack.append((indent, key))
            let rest = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if stack.dropLast().contains(where: { $0.key == "-" }) { continue }
            if rest.hasPrefix("#!append") {
                out[stack.map(\.key)] = .append
            } else if rest.hasPrefix("#!replace") {
                out[stack.map(\.key)] = .replace
            }
        }
        return out
    }

     
     
    private static func keyColon(in line: String) -> String.Index? {
        var index = line.startIndex
        var quote: Character?
        if let first = line.first, first == "\"" || first == "'" {
            quote = first
            index = line.index(after: index)
        }
        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            if let open = quote {
                if character == open { quote = nil }
            } else if character == ":", next == line.endIndex || line[next] == " " || line[next] == "\t" {
                return index
            }
            index = next
        }
        return nil
    }

    private static func keep(_ items: [Item], section: String, arguments: Arguments, into ir: inout AdBlockModuleIR,
                             _ read: (String, AdBlockLineOrigin) -> Result<AdBlockRewriteRule, AdBlockIgnoredReason>) {
        for (index, item) in items.enumerated() {
            let origin = AdBlockLineOrigin(section: section, line: index + 1)
            guard let text = item.text else {
                ir.ignored.append(AdBlockIgnoredEntry(text: item.shown, reason: .unreadableLine, origin: origin))
                continue
            }
            switch arguments.fill(text).flatMap({ read($0, origin) }) {
            case .success(let rule): ir.rewriteRules.append(rule)
            case .failure(let reason): ir.ignored.append(AdBlockIgnoredEntry(text: text, reason: reason, origin: origin))
            }
        }
    }

     
     
    private static func keepReadings(_ items: [Item], section: String, arguments: Arguments, into ir: inout AdBlockModuleIR,
                                     _ read: (String, AdBlockLineOrigin) -> Result<AdBlockLineSyntax.Reading, AdBlockIgnoredReason>) {
        for (index, item) in items.enumerated() {
            let origin = AdBlockLineOrigin(section: section, line: index + 1)
            guard let text = item.text else {
                ir.ignored.append(AdBlockIgnoredEntry(text: item.shown, reason: .unreadableLine, origin: origin))
                continue
            }
            switch arguments.fill(text).flatMap({ read($0, origin) }) {
            case .success(let reading):
                ir.rewriteRules += reading.rules
                ir.answerFiles += reading.files
            case .failure(let reason): ir.ignored.append(AdBlockIgnoredEntry(text: text, reason: reason, origin: origin))
            }
        }
    }

     
     
     
    private static func mocks(_ items: [Item], section: String, arguments: Arguments, into ir: inout AdBlockModuleIR) {
        for (index, item) in items.enumerated() {
            let origin = AdBlockLineOrigin(section: section, line: index + 1)
            var shown = item.shown
            if case .object(let pairs) = item.json, let match = scalar(pairs.first(where: { $0.key == "match" })?.value) { shown = match }
            switch AdBlockLocalAnswerSyntax.stashMock(item.json, origin: origin, fill: arguments.fill) {
            case .success(let read):
                ir.rewriteRules.append(read.rule)
                for note in read.notes { ir.ignored.append(AdBlockIgnoredEntry(text: shown, reason: note, origin: origin)) }
            case .failure(let reason):
                ir.ignored.append(AdBlockIgnoredEntry(text: shown, reason: reason, origin: origin))
            }
        }
    }

     
     
     
     
    private static func scripts(_ items: [Item], providers: [(key: String, value: OrderedJSON)], section: String,
                                arguments: Arguments, into ir: inout AdBlockModuleIR) {
        for (index, item) in items.enumerated() {
            let origin = AdBlockLineOrigin(section: section, line: index + 1)
            guard case .object(let pairs) = item.json else {
                ir.ignored.append(AdBlockIgnoredEntry(text: item.shown, reason: .unreadableLine, origin: origin))
                continue
            }
            func field(_ key: String) -> OrderedJSON? { pairs.first { $0.key == key }?.value }
            let name = scalar(field("name")) ?? ""
            var provider: [(key: String, value: OrderedJSON)] = []
            if case .object(let found)? = providers.first(where: { $0.key == name })?.value { provider = found }
            func providerField(_ key: String) -> String? { scalar(provider.first { $0.key == key }?.value) }
            var parameters: [(key: String, value: String)] = [
                (key: "type", value: "http-" + (scalar(field("type")) ?? "")),
                (key: "pattern", value: scalar(field("match")) ?? ""),
                (key: "script-path", value: providerField("url") ?? ""),
            ]
             
            for key in ["require-body", "requires-body", "binary-mode", "max-size", "timeout", "argument"] {
                if let value = scalar(field(key)) { parameters.append((key: key, value: value)) }
            }
            if let interval = providerField("interval") {
                parameters.append((key: "script-update-interval", value: interval))
            }
            var filled: [(key: String, value: String)] = []
            var unfilled: AdBlockIgnoredReason?
            for parameter in parameters where unfilled == nil {
                switch arguments.fill(parameter.value) {
                case .success(let value): filled.append((key: parameter.key, value: value))
                case .failure(let reason): unfilled = reason
                }
            }
            if let unfilled {
                ir.ignored.append(AdBlockIgnoredEntry(text: scalar(field("match")) ?? name, reason: unfilled, origin: origin))
                continue
            }
            switch AdBlockLineSyntax.script(name: name, parameters: filled, origin: origin) {
            case .success(let script): ir.scripts.append(script)
            case .failure(let reason):
                ir.ignored.append(AdBlockIgnoredEntry(text: scalar(field("match")) ?? name, reason: reason, origin: origin))
            }
        }
    }
}
