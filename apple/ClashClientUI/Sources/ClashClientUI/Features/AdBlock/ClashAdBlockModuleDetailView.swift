import ClashClientKit
import SwiftUI

 
 
 
 
 
 
 
 
 
 
 
public struct ClashAdBlockModuleDetailView: View {
    private let snapshot: ClashAdBlockModuleDetailSnapshot?
    private let editor: ClashAdBlockModuleEditorSnapshot?
    private let perform: (ClashAdBlockAction) -> Void
    private let close: () -> Void
    @State private var confirmsDelete = false
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(snapshot: ClashAdBlockModuleDetailSnapshot?, editor: ClashAdBlockModuleEditorSnapshot? = nil,
                perform: @escaping (ClashAdBlockAction) -> Void, close: @escaping () -> Void) {
        self.snapshot = snapshot
        self.editor = editor
        self.perform = perform
        self.close = close
    }

     
    private var thisModulesEditor: ClashAdBlockModuleEditorSnapshot? {
        guard let editor, let id = editor.moduleID, id == snapshot?.id else { return nil }
        return editor
    }

    public var body: some View {
        ClashSingleColumnNavigationContainer {
            content
                .clashPageTitle(snapshot.map { ClashDisplayText.verbatim($0.name) } ?? "Module", watchAs: "adblock.module")
                .clashToolbarUnlessInPanel {
                    ToolbarItem(placement: .cancellationAction) {
                        ClashSheetCloseButton {
                            close()
                        }
                    }
                }
                .clashProductModalRoot(title: snapshot?.name ?? "Module")
        }
        .modifier(ClashAdBlockEditorPresentation(editor: thisModulesEditor, perform: perform))
        .accessibilityIdentifier("adblock.detail")
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot {
            List {
                headerSection(snapshot)
                ForEach(snapshot.sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            itemRow(item)
                        }
                    } header: {
                        sectionHeader(section)
                    }
                }
                Section {
                    Button(role: .destructive) {
                        confirmsDelete = true
                    } label: {
                        Text("Delete Module")
                    }
                    .accessibilityIdentifier("adblock.detail.delete")
                     
                     
                     
                    .confirmationDialog(
                        Text(clash: .format("Delete %@?", [snapshot.name])),
                        isPresented: $confirmsDelete,
                        titleVisibility: .visible
                    ) {
                        Button(role: .destructive) {
                            perform(.removeModule(id: snapshot.id))
                            close()
                        } label: {
                            Text("Delete Module")
                        }
                        .accessibilityIdentifier("adblock.detail.delete.confirm")
                        Button(role: .cancel) {} label: {
                            Text("Cancel")
                        }
                    }
                }
            }
            .modifier(ClashAdBlockListStyle())
        } else {
            List {}
                .modifier(ClashAdBlockListStyle())
        }
    }

     
     
     
    @ViewBuilder
    private func sectionHeader(_ section: ClashAdBlockModuleDetailSnapshot.Section) -> some View {
        if dynamicTypeSize.isAccessibilitySize, let note = Self.headerNote(section) {
            VStack(alignment: .leading, spacing: ClashTheme.Spacing.compact) {
                HStack(alignment: .firstTextBaseline) {
                    Text(clash: section.title)
                    Spacer(minLength: ClashTheme.Spacing.compact)
                    Text(verbatim: ClashCopy.count(section.items.count, locale: locale))
                }
                headerNoteText(note)
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(clash: section.title)
                Spacer(minLength: ClashTheme.Spacing.compact)
                if let note = Self.headerNote(section) {
                    headerNoteText(note)
                }
                Text(verbatim: ClashCopy.count(section.items.count, locale: locale))
            }
        }
    }

     
     
     
    private func headerNoteText(_ note: ClashDisplayText) -> some View {
        Text(clash: note)
            .foregroundStyle(Color.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func headerSection(_ snapshot: ClashAdBlockModuleDetailSnapshot) -> some View {
        Section {
            Toggle(isOn: Binding(get: { snapshot.enabled },
                                 set: { perform(.setModule(id: snapshot.id, enabled: $0)) })) {
                Text(verbatim: snapshot.name)
            }
            .modifier(ClashAdBlockSwitchStyle())
            .accessibilityIdentifier("adblock.detail.toggle")
            if let summary = snapshot.summary {
                Text(verbatim: summary)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let author = snapshot.author {
                valueRow("Author") { Text(verbatim: author) }
            }
            if let source = Self.sourceText(snapshot, locale: locale) {
                valueRow("Source") {
                     
                    Text(unhyphenated: source)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let updated = snapshot.updatedAt {
                valueRow(Self.timeTitle(snapshot)) {
                    Text(updated, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                }
            }
            Text(clash: Self.countsLine(effective: snapshot.effectiveCount, skipped: snapshot.ignoredCount,
                                       waiting: snapshot.needsDecryptionCount, enabled: snapshot.enabled, locale: locale))
                .font(.subheadline)
             
            if let failure = snapshot.failure {
                if snapshot.failureIsSentence {
                     
                     
                    Label {
                        Text(clash: failure)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: ClashSymbol.exclamationmarkTriangleFill.rawValue)
                            .foregroundStyle(Color.red)
                    }
                    .font(.subheadline)
                } else {
                     
                    Text(clash: failure)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            switch snapshot.source {
            case .local:
                 
                Button {
                    perform(.editModule(id: snapshot.id))
                } label: {
                    Text("Edit")
                }
                .accessibilityIdentifier("adblock.detail.edit")
            case .link:
                 
                Button {
                    perform(.refreshModule(id: snapshot.id))
                } label: {
                    Text(clash: snapshot.isUpdating ? "Updating…" : "Update")
                }
                .disabled(snapshot.isUpdating)
                .accessibilityIdentifier("adblock.detail.update")
            case .unknown:
                 
                EmptyView()
            }
        }
    }

     
     
    nonisolated static func sourceText(_ snapshot: ClashAdBlockModuleDetailSnapshot, locale: Locale) -> String? {
        switch snapshot.source {
        case .link(let link): return link
        case .local: return ClashCopy.string("Local", locale: locale)
        case .unknown: return nil
        }
    }

    private func itemRow(_ item: ClashAdBlockModuleDetailSnapshot.Item) -> some View {
        VStack(alignment: .leading, spacing: ClashTheme.Spacing.compact) {
            moduleWords(item.text)
                .font(.system(.callout, design: .monospaced))
            if let detail = item.detail {
                if case .verbatim(let words) = detail {
                     
                    moduleWords(words)
                        .font(.footnote)
                } else {
                     
                    Text(clash: detail)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let secondary = item.secondary {
                 
                moduleWords(secondary)
                    .font(.system(.caption, design: .monospaced))
            }
            if let place = item.place {
                Text(clash: place)
                    .font(.caption)
            }
            if let action = item.action {
                 
                 
                Button {
                    perform(.notice(action))
                } label: {
                    Text(clash: item.actionTitle ?? "Run Again")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .accessibilityIdentifier("adblock.detail.item.action.\(item.id)")
            }
        }
    }

     
     
     
     
    private func moduleWords(_ words: String) -> some View {
        Text(unhyphenated: Self.drawn(words))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(Text(verbatim: words))
#if os(iOS) || os(macOS)
            .contextMenu {
                Button {
                    perform(.copy(words))
                } label: {
                    Text("Copy")
                }
                .accessibilityIdentifier("adblock.detail.item.copy")
            }
#endif
    }

     
     
     
     
     
     
     
    nonisolated static func drawn(_ words: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in words.unicodeScalars {
            out.append(scalar)
            switch scalar {
            case ",": out.append("\u{200B}")
            case "-", "|", "$": out.append("\u{2060}")
            default: break
            }
        }
        return String(out)
    }

     
     
     
     
    nonisolated static func countsLine(effective: Int, skipped: Int, waiting: Int = 0, enabled: Bool = true,
                                       locale: Locale) -> ClashDisplayText {
        let skippedCount = ClashCopy.count(skipped, locale: locale)
        guard enabled else {
            let all = ClashCopy.count(effective, locale: locale)
            guard skipped > 0 else { return .format(effective == 1 ? "%@ entry" : "%@ entries", [all]) }
            return .format(effective == 1 ? "%@ entry · %@ skipped" : "%@ entries · %@ skipped", [all, skippedCount])
        }
        let inUse = ClashCopy.count(max(0, effective - waiting), locale: locale)
        guard skipped > 0 else { return .format("%@ in use", [inUse]) }
        return .format("%@ in use · %@ skipped", [inUse, skippedCount])
    }

     
     
    nonisolated static func headerNote(_ section: ClashAdBlockModuleDetailSnapshot.Section) -> ClashDisplayText? {
        section.waiting
    }

     
    nonisolated static func timeTitle(_ snapshot: ClashAdBlockModuleDetailSnapshot) -> ClashDisplayText {
        switch snapshot.source {
        case .local: return "Saved"
        case .link, .unknown: return "Updated"
        }
    }

     
     
    @ViewBuilder
    private func valueRow<Value: View>(_ title: ClashDisplayText, @ViewBuilder value: () -> Value) -> some View {
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, *) {
            LabeledContent { value() } label: { Text(clash: title) }
        } else {
            valueRowBefore16(title, value: value())
        }
    }

    private func valueRowBefore16<Value: View>(_ title: ClashDisplayText, value: Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ClashTheme.Spacing.row) {
            Text(clash: title)
            Spacer(minLength: ClashTheme.Spacing.row)
            value.foregroundStyle(.secondary)
        }
    }
}

struct ClashAdBlockListStyle: ViewModifier {
    func body(content: Content) -> some View {
#if os(iOS)
        content.listStyle(.insetGrouped)
#elseif os(macOS)
        content.listStyle(.inset)
#else
        content.listStyle(.grouped)
#endif
    }
}

extension Text {
     
     
     
     
     
     
    init(unhyphenated value: String) {
        var text = AttributedString(value)
        text.languageIdentifier = "zxx"
        self.init(text)
    }
}
