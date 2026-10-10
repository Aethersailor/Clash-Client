import SwiftUI

 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
struct ClashTVRulesScreen: View {
    @Binding var state: ClashTVProductState

    @State private var shownCategory: ClashStructuredRule.Category = .domain
    @State private var explainedRule: ClashRuleLineSnapshot?

    private var groups: [ClashStructuredRule.Category: [ClashRuleLineSnapshot]] {
        Self.group(state.rules)
    }

    var body: some View {
        let groups = groups
        HStack(alignment: .top, spacing: 40) {
            categories(groups)
                .frame(maxWidth: 520)
            rules(groups[shownCategory] ?? [])
        }
    }

     

    private func categories(_ groups: [ClashStructuredRule.Category: [ClashRuleLineSnapshot]]) -> some View {
        List {
            Section(Self.listHeader(count: state.rules.count)) {
                ForEach(ClashStructuredRule.Category.allCases) { category in
                    let lines = groups[category] ?? []
                    let inert = lines.filter { Self.neverMatches($0.type) }.count
                    Button {
                        shownCategory = category
                    } label: {
                        LabeledContent {
                            Text(lines.count.formatted())
                                .monospacedDigit()
                        } label: {
                            Text(category.title.localizedForTelevision)
                            if let subtitle = Self.groupSubtitle(neverMatching: inert) {
                                Text(subtitle)
                            }
                        }
                    }
                    .onClashTVFocus {
                        shownCategory = category
                        explainedRule = nil
                    }
                    .accessibilityIdentifier("tvos.rules.category.\(category.rawValue)")
                }
            }
        }
        .listStyle(.grouped)
        .safeAreaPadding(.horizontal, 44)
    }

     

    private func rules(_ lines: [ClashRuleLineSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Self.header(category: shownCategory, count: lines.count))
                .font(.caption)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
            List {
                ForEach(lines) { rule in
                    Button {} label: { row(rule) }
                        .onClashTVFocus { explainedRule = rule }
                }
            }
             
             
             
            .listStyle(.grouped)
             
             
             
             
             
             
            .safeAreaPadding(.horizontal, 24)
            .safeAreaPadding(.vertical, 20)
             
             
             
            Text(explainedRule.map(Self.explanation(for:)) ?? " ")
                .font(.body)
                .foregroundStyle(
                    explainedRule.map { Self.neverMatches($0.type) } == true
                        ? AnyShapeStyle(.orange)
                        : AnyShapeStyle(.secondary)
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 80, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func row(_ rule: ClashRuleLineSnapshot) -> some View {
        let inert = Self.neverMatches(rule.type)
        return HStack(spacing: 20) {
             
             
            Text(rule.type)
                .font(.caption.monospaced())
                .foregroundStyle(inert ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(minWidth: 220, alignment: .leading)
            Text(rule.payload.isEmpty ? "—" : rule.payload)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 20)
            Text(Self.trailing(for: rule))
                .font(.body)
                .foregroundStyle(inert ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
    }

     

     
     
     
    static func category(of type: String) -> ClashStructuredRule.Category {
        ClashStructuredRule.Action(rawValue: type)?.category ?? .advanced
    }

     
    static func group(_ lines: [ClashRuleLineSnapshot]) -> [ClashStructuredRule.Category: [ClashRuleLineSnapshot]] {
        var groups: [ClashStructuredRule.Category: [ClashRuleLineSnapshot]] = [:]
        for line in lines {
            groups[category(of: line.type), default: []].append(line)
        }
        return groups
    }

     
     
     
     
     
     
     
    static let neverMatchingKinds: Set<String> =
        ClashAppleRuntimeProfile.tvosPacketTunnel.keptNeverMatchRuleActionNames

    static func neverMatches(_ type: String) -> Bool {
        neverMatchingKinds.contains(type)
    }

     
     
    static func trailing(for rule: ClashRuleLineSnapshot) -> String {
        neverMatches(rule.type) ? String(localized: "Never matches") : rule.target
    }

     
    static func listHeader(count: Int) -> String {
        String(localized: "Rules · \(count.formatted())")
    }

     
     
    static func header(category: ClashStructuredRule.Category, count: Int) -> String {
        let title = category.title.localizedForTelevision
        return count == 1
            ? String(localized: "\(title) · 1 rule · in match order")
            : String(localized: "\(title) · \(count.formatted()) rules · in match order")
    }

    static func groupSubtitle(neverMatching count: Int) -> String? {
        switch count {
        case 0: nil
        case 1: String(localized: "1 never matches here")
        default: String(localized: "\(count) never match here")
        }
    }

     
     
     
     
    static func explanation(for rule: ClashRuleLineSnapshot) -> String {
        if neverMatches(rule.type) {
            return String(localized: "This rule tests which app opened the connection. An Apple TV tunnel only sees packets, never the app behind them, so it is loaded but never fires and the next rule decides.")
        }
        return ClashStructuredRule.Action(rawValue: rule.type)?.summary.localizedForTelevision ?? rule.raw
    }
}
