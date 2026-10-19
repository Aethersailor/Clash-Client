import ClashClientKit
import SwiftUI

 
 
 
 
 
 
 
 
 
 
public struct ClashAdBlockView<AddModule: View>: View {
    private let snapshot: ClashAdBlockSnapshot
    private let perform: (ClashAdBlockAction) -> Void
    private let detail: (String) -> ClashAdBlockModuleDetailSnapshot?
    private let addModule: (_ dismiss: @escaping () -> Void) -> AddModule

    @State private var showsAddModule = false
    @State private var openedModule: ClashAdBlockOpenedModule?
     
     
    @StateObject private var certificateFeed: ClashAdBlockCertificateFeed
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        snapshot: ClashAdBlockSnapshot,
        perform: @escaping (ClashAdBlockAction) -> Void,
        detail: @escaping (String) -> ClashAdBlockModuleDetailSnapshot?,
        @ViewBuilder addModule: @escaping (_ dismiss: @escaping () -> Void) -> AddModule
    ) {
        self.snapshot = snapshot
        self.perform = perform
        self.detail = detail
        self.addModule = addModule
        _certificateFeed = StateObject(wrappedValue: ClashAdBlockCertificateFeed(snapshot))
    }

    public var body: some View {
        Form {
            decryptionSection
             
             
             
            if !snapshot.notices.isEmpty {
                noticesSection
            }
            modulesSection
        }
        .modifier(ClashAdBlockFormStyle())
        .clashPageTitle("Modules")
        .onChange(of: snapshot) { certificateFeed.take($0) }
        .sheet(item: $openedModule) { opened in
             
             
            ClashAdBlockModuleDetailView(snapshot: detail(opened.id), editor: snapshot.editor, perform: perform) {
                openedModule = nil
            }
            .clashModalPresentation(.page)
        }
        .sheet(isPresented: $showsAddModule) {
            addModule { showsAddModule = false }
                .clashModalPresentation(.form)
        }
        .modifier(ClashAdBlockEditorPresentation(editor: newModuleEditor, perform: perform))
        .accessibilityIdentifier("adblock.page")
    }

     
     
    private var newModuleEditor: ClashAdBlockModuleEditorSnapshot? {
        snapshot.editor.flatMap { $0.moduleID == nil ? $0 : nil }
    }

     

     
     
     
     
     
     
    private var decryptionSection: some View {
        Section {
            Toggle(isOn: Binding(get: { snapshot.isOn }, set: { perform(.setEnabled($0)) })) {
                Text("HTTPS Decryption")
            }
            .modifier(ClashAdBlockSwitchStyle())
            .disabled(snapshot.isBusy)
            .accessibilityIdentifier("adblock.switch")
            if let certificate = snapshot.certificate {
                ClashRoutedViewLink {
                    ClashAdBlockCertificateView(feed: certificateFeed, perform: perform)
                        .clashPushedDetailPage()
                } label: {
                    HStack(spacing: ClashTheme.Spacing.row) {
                        Text("Certificate")
                        Spacer(minLength: ClashTheme.Spacing.compact)
                        Text(clash: certificate.state.rowValue)
                            .foregroundStyle(certificate.state == .ready ? Color.secondary : Color.orange)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .accessibilityIdentifier("adblock.certificate")
            }
            if let install = snapshot.install {
                Button {
                    perform(.certificate(install.action.kind))
                } label: {
                    Text(clash: install.action.title)
                }
                .disabled(snapshot.isBusy)
                .accessibilityIdentifier("adblock.install.\(ClashAdBlockCertificateView.actionName(install.action.kind))")
            }
        } footer: {
            if let install = snapshot.install {
                Text(clash: install.effect)
            } else if !snapshot.isOn {
                Text("When it's off, only the rules in your modules are used.")
            }
        }
    }

    private var noticesSection: some View {
        Section {
            ForEach(snapshot.notices) { notice in
                Label {
                    Text(clash: notice.text)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: ClashSymbol.exclamationmarkTriangleFill.rawValue)
                        .foregroundStyle(Color.orange)
                }
                .accessibilityIdentifier("adblock.notice.\(notice.id)")
                if let action = notice.action {
                    Button {
                        perform(.notice(action))
                    } label: {
                        Text(clash: notice.actionTitle ?? "Try Again")
                    }
                    .accessibilityIdentifier("adblock.notice.action.\(notice.id)")
                }
            }
        }
    }

    private var modulesSection: some View {
         
        let paths = ClashAdBlockSnapshot.ModuleRow.distinguishingPaths(snapshot.modules)
        return Section {
            ForEach(snapshot.modules) { row in
                moduleRow(row, path: paths[row.id])
            }
            ClashAddRow(Text("Add Module")) {
                showsAddModule = true
            }
            .disabled(snapshot.isBusy)
            .accessibilityIdentifier("adblock.modules.add")
             
             
            ClashAddRow(Text("New Module"), symbol: .docBadgePlus, action: { perform(.newModule) }) {
                ClashAdBlockNewModuleLabel()
            }
            .disabled(snapshot.isBusy)
            .accessibilityIdentifier("adblock.modules.new")
        } header: {
            Text("Modules")
        }
    }

     
     
     
    @ViewBuilder
    private func moduleRow(_ row: ClashAdBlockSnapshot.ModuleRow, path: String?) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: ClashTheme.Spacing.row) {
                    moduleLines(row, path: path)
                    HStack(spacing: ClashTheme.Spacing.row) {
                        moduleSwitch(row)
                        Spacer(minLength: ClashTheme.Spacing.compact)
                        moduleInfoButton(row)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: ClashTheme.Spacing.row) {
                    moduleLines(row, path: path)
                    Spacer(minLength: ClashTheme.Spacing.compact)
                    moduleInfoButton(row)
                    moduleSwitch(row)
                }
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                perform(.removeModule(id: row.id))
            } label: {
                Text("Delete")
            }
        }
        .modifier(ClashAdBlockDeleteSwipe { perform(.removeModule(id: row.id)) })
    }

     
     
    private func moduleLines(_ row: ClashAdBlockSnapshot.ModuleRow, path: String?) -> some View {
        VStack(alignment: .leading, spacing: ClashTheme.Spacing.compact) {
            Text(verbatim: row.name)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            if let path {
                Text(unhyphenated: path)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .truncationMode(.middle)
            }
            if dynamicTypeSize.isAccessibilitySize {
                 
                if let source = Self.sourceName(row, locale: locale) {
                    Text(unhyphenated: source)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let updated = Self.updatedLine(row, locale: locale) {
                    Text(verbatim: updated)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                sourceLines(row)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: Self.entriesLine(row, locale: locale))
                .font(.footnote)
                .foregroundStyle(.secondary)
             
            if row.failure != nil {
                Text("Update failed")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

     
     
     
     
    @ViewBuilder
    private func sourceLines(_ row: ClashAdBlockSnapshot.ModuleRow) -> some View {
        let updated = Self.updatedLine(row, locale: locale)
        if let source = Self.sourceName(row, locale: locale) {
            if let updated {
                if #available(iOS 16.0, *) {
                    ViewThatFits(in: .horizontal) {
                        Text(unhyphenated: source + " · " + updated)
                            .lineLimit(1)
                        stackedSourceLines(source, updated)
                    }
                } else {
                    stackedSourceLines(source, updated)
                }
            } else {
                Text(unhyphenated: source)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        } else if let updated {
             
            Text(verbatim: updated)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stackedSourceLines(_ source: String, _ updated: String) -> some View {
        VStack(alignment: .leading, spacing: ClashTheme.Spacing.compact) {
            Text(unhyphenated: source)
                .lineLimit(2)
                .truncationMode(.middle)
            Text(verbatim: updated)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func moduleInfoButton(_ row: ClashAdBlockSnapshot.ModuleRow) -> some View {
        Button {
            openedModule = ClashAdBlockOpenedModule(id: row.id)
        } label: {
            Image(systemName: ClashSymbol.infoCircle.rawValue)
                .imageScale(.large)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("Details"))
        .accessibilityIdentifier("adblock.module.info.\(row.id)")
    }

    private func moduleSwitch(_ row: ClashAdBlockSnapshot.ModuleRow) -> some View {
        Toggle(isOn: Binding(get: { row.enabled }, set: { perform(.setModule(id: row.id, enabled: $0)) })) {
            Text(verbatim: row.name)
        }
        .modifier(ClashAdBlockSwitchStyle())
        .labelsHidden()
        .disabled(snapshot.isBusy)
        .accessibilityIdentifier("adblock.module.toggle.\(row.id)")
    }

     

     
     
     
    nonisolated static func sourceLine(_ row: ClashAdBlockSnapshot.ModuleRow, locale: Locale, now: Date = Date()) -> String {
        [sourceName(row, locale: locale), updatedLine(row, locale: locale, now: now)].compactMap { $0 }.joined(separator: " · ")
    }

     
     
    nonisolated static func sourceName(_ row: ClashAdBlockSnapshot.ModuleRow, locale: Locale) -> String? {
        switch row.source {
        case .link(let host): return host
        case .local: return ClashCopy.string("Local", locale: locale)
        case .unknown: return nil
        }
    }

     
    nonisolated static func updatedLine(_ row: ClashAdBlockSnapshot.ModuleRow, locale: Locale, now: Date = Date()) -> String? {
        guard let updated = row.updatedAt else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
         
         
        let when = formatter.localizedString(for: min(updated, now.addingTimeInterval(-1)), relativeTo: now)
        return ClashCopy.string(for: .format("Last updated %@", [when]), locale: locale)
    }

     
     
    nonisolated static func entriesLine(_ row: ClashAdBlockSnapshot.ModuleRow, locale: Locale) -> String {
        ClashCopy.string(
            for: .format(row.effectiveCount == 1 ? "%@ entry" : "%@ entries",
                         [ClashCopy.count(row.effectiveCount, locale: locale)]),
            locale: locale
        )
    }
}

 
 
 
 
 
struct ClashAdBlockNewModuleLabel: View {
    var body: some View {
        HStack(spacing: ClashTheme.Spacing.row) {
            Image(systemName: ClashSymbol.plusCircleFill.rawValue)
                .font(.title3)
                .hidden()
                .overlay(
                    Image(systemName: ClashSymbol.docBadgePlus.rawValue)
                        .font(.title3)
                )
                .accessibilityHidden(true)
            Text("New Module")
            Spacer(minLength: 0)
        }
        .foregroundStyle(.tint)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

 
 
struct ClashAdBlockEditorPresentation: ViewModifier {
    let editor: ClashAdBlockModuleEditorSnapshot?
    let perform: (ClashAdBlockAction) -> Void

    func body(content: Content) -> some View {
#if os(tvOS)
        content
#else
        content.sheet(item: Binding(get: { editor }, set: { if $0 == nil { perform(.closeEditor) } })) { opened in
            ClashAdBlockModuleEditorView(editor: editor ?? opened, perform: perform)
                .clashModalPresentation(.page)
        }
#endif
    }
}

struct ClashAdBlockOpenedModule: Identifiable, Equatable {
    let id: String
}

 
 
 
struct ClashAdBlockSwitchStyle: ViewModifier {
    func body(content: Content) -> some View {
#if os(tvOS)
        content
#else
        content.toggleStyle(.switch)
#endif
    }
}

 
 
struct ClashAdBlockFormStyle: ViewModifier {
    func body(content: Content) -> some View {
#if os(macOS)
        content.formStyle(.grouped)
#else
        content
#endif
    }
}

 
struct ClashAdBlockDeleteSwipe: ViewModifier {
    let delete: () -> Void

    func body(content: Content) -> some View {
#if os(iOS)
        content.swipeActions(edge: .trailing) {
            Button(role: .destructive, action: delete) {
                Text("Delete")
            }
            .accessibilityIdentifier("adblock.module.delete")
        }
#else
        content
#endif
    }
}
