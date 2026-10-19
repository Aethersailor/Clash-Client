import ClashClientUI
import SwiftUI

 
 
 
 
 
struct AdBlockAddModuleSheet: View {
    enum Input: Equatable {
        case link(String)
        case text(String)
    }

    let isAdding: Bool
    let refusal: ClashDisplayText?
    let add: (Input) -> Void
    let cancel: () -> Void
    let edited: () -> Void
    @State private var link = ""
     
    @Environment(\.clashInsideProductModalPresentation) private var insideProductModal

    private var typedLink: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ClashClientUI.ClashSingleColumnNavigationContainer {
            Form {
                Section {
                     
                     
                     
                     
                    HStack(spacing: ClashTheme.Spacing.standard) {
                        linkField
                        ClashPasteControl(style: .square) { pasted in
                            let input = Self.input(forPasted: pasted)
                            if case .link(let value) = input { link = value }
                            add(input)
                        }
                        .disabled(isAdding)
                        .accessibilityIdentifier("adblock.add.paste")
                    }
                } footer: {
                    if let refusal {
                        Text(clash: refusal)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("adblock.add.refusal")
                    } else {
                        Text("Paste a link to a module, or the module itself.")
                    }
                }
            }
            .clashPageTitle("Add Module")
            .clashToolbarUnlessInPanel {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: cancel) {
                        Text("Cancel")
                    }
                    .accessibilityIdentifier("adblock.add.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isAdding {
                        ProgressView()
                    } else {
                        Button {
                            add(.link(typedLink))
                        } label: {
                            Text("Add")
                        }
                        .disabled(typedLink.isEmpty)
                        .accessibilityIdentifier("adblock.add.confirm")
                    }
                }
            }
            .clashMacProductModalBar {
                if insideProductModal {
                    ClashModalActionBar(primaryTitle: "Add", primaryDisabled: typedLink.isEmpty, isBusy: isAdding,
                                        onPrimary: { add(.link(typedLink)) })
                }
            }
            .clashProductModalRoot(title: "Add Module", actionTitle: "Add",
                                  actionDisabled: isAdding || typedLink.isEmpty,
                                  action: { add(.link(typedLink)) })
        }
    }

    private var linkField: some View {
        TextField(text: $link, prompt: Self.prompt) {
            Text("Module Link")
        }
        .disableAutocorrection(true)
#if os(iOS)
        .textInputAutocapitalization(.never)
        .keyboardType(.URL)
        .textContentType(.URL)
#endif
        .onChange(of: link) { _ in edited() }
        .onSubmit { if !typedLink.isEmpty { add(.link(typedLink)) } }
        .accessibilityIdentifier("adblock.add.link")
    }

     
     
     
     
    static var prompt: Text {
        #if os(macOS)
        Text(verbatim: "https://…")
        #else
        Text("Module Link")
        #endif
    }

     
    static func input(forPasted pasted: String) -> Input {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("\n"), let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https", url.host?.isEmpty == false {
            return .link(trimmed)
        }
        return .text(pasted)
    }
}
