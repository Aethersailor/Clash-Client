import ClashClientKit
import ClashClientUI
import SwiftUI

 
 
 
 
 
struct ClashMacTargetRow: View {
    let title: ClashDisplayText
    let value: String
    let identifier: String
    let open: () -> Void
    @Environment(\.configurationFieldCopy) private var copy
    @Environment(\.locale) private var locale

    var body: some View {
        LabeledContent {
            Button(action: open) {
                 
                Text(clash: value.isEmpty ? .copy("Choose…")
                     : .verbatim(ConfigurationRuleWords.targetName(value, locale: locale, copy: copy))).lineLimit(1)
            }
            .accessibilityIdentifier(identifier)
            .accessibilityValue(Text(verbatim: value))
        } label: {
            Text(clash: title)
        }
    }
}

 
 
 
 
 
struct ClashMacTargetPickerPage: View {
    let candidates: ConfigurationRuleTargetCandidates
    let current: String
    let identifier: String
     
     
     
     
    var addGroup: (() -> Void)?
    let pick: (String) -> Void
    @State private var query = ""
    @Environment(\.configurationFieldCopy) private var copy
    @Environment(\.locale) private var locale

    private var shown: ConfigurationRuleTargetCandidates { candidates.filtered(by: query) }

    private func title(_ section: ConfigurationRuleTargetCandidates.Section) -> ClashDisplayText {
        switch section.kind {
        case .builtin: return .copy("Built-in")
        case .groups: return .copy("Policy Groups")
        case .source, .providers: return .verbatim(section.sourceLabel ?? section.id)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(text: $query, prompt: Text(clash: .copy("Search"))) { Text(clash: .copy("Search")) }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .accessibilityIdentifier("\(identifier).search")
            Divider()
            if shown.sections.isEmpty {
                ClashMacSheetPlaceholder(title: .copy("No results"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("\(identifier).no-results")
            } else {
                List {
                    ForEach(shown.sections) { section in
                        Section {
                             
                            ForEach(section.names, id: \.self) { name in
                                Button { pick(name) } label: {
                                    HStack(spacing: ClashTheme.Spacing.compact) {
                                        Text(verbatim: ConfigurationRuleWords.targetName(name, locale: locale, copy: copy))
                                        Spacer()
                                        if name == current {
                                            ClashSymbolImage(symbol: .checkmark).foregroundStyle(.tint)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("\(identifier).pick.\(name)")
                            }
                        } header: {
                            Text(clash: title(section))
                        }
                    }
                }
                .clashMacSettingsList(minRowHeight: ClashMacSettingsMetrics.listRowMinHeight)
            }
             
             
             
             
             
            if let addGroup {
                Divider()
                Button(action: addGroup) { Text(clash: .copy("Add Policy Group")) }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("\(identifier).add-group")
            }
        }
    }
}
