import ClashClientKit
import SwiftUI

 
 
 
 
 
 
 
 
 
public struct ClashAdBlockCertificateView: View {
    @ObservedObject private var feed: ClashAdBlockCertificateFeed
    private let perform: (ClashAdBlockAction) -> Void
    @State private var confirmsNewCertificate = false

     
    init(feed: ClashAdBlockCertificateFeed, perform: @escaping (ClashAdBlockAction) -> Void) {
        self.feed = feed
        self.perform = perform
    }

     
    public init(snapshot: ClashAdBlockSnapshot, perform: @escaping (ClashAdBlockAction) -> Void) {
        self.init(feed: ClashAdBlockCertificateFeed(snapshot), perform: perform)
    }

    public var body: some View {
        Form {
            if let certificate = feed.certificate {
                Section {
                    stateRow(certificate.state)
                    ForEach(Array(certificate.steps.enumerated()), id: \.offset) { _, step in
                        Text(clash: step)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = certificate.note {
                         
                         
                        Text(clash: note)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("adblock.certificate.note")
                    }
                    if certificate.state != .ready, let action = certificate.action {
                        actionButton(action)
                    }
                }
                 
                if certificate.state == .ready, let action = certificate.action {
                    Section {
                        actionButton(action)
                    }
                }
            }
        }
        .modifier(ClashAdBlockFormStyle())
        .clashPageTitle("Certificate")
        .accessibilityIdentifier("adblock.certificate.page")
    }

    private func stateRow(_ state: ClashAdBlockSnapshot.CertificateState) -> some View {
        Label {
            Text(clash: state.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: state == .ready
                  ? ClashSymbol.checkmarkShieldFill.rawValue
                  : ClashSymbol.exclamationmarkShieldFill.rawValue)
                .foregroundStyle(state == .ready ? Color.green : Color.orange)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("adblock.certificate.state")
    }

    private func actionButton(_ action: ClashAdBlockSnapshot.CertificateAction) -> some View {
        Button {
            switch action.kind {
            case .makeNew: confirmsNewCertificate = true
            default: perform(.certificate(action.kind))
            }
        } label: {
            Text(clash: action.title)
        }
        .disabled(feed.isBusy)
        .accessibilityIdentifier("adblock.certificate.action.\(Self.actionName(action.kind))")
         
         
         
        .confirmationDialog(
             
             
            Text("Make a New Module Certificate?"),
            isPresented: $confirmsNewCertificate,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                perform(.renewCertificate)
            } label: {
                Text("Make a New Certificate")
            }
            .accessibilityIdentifier("adblock.certificate.renew.confirm")
            Button(role: .cancel) {} label: {
                Text("Cancel")
            }
        } message: {
            if let warning = feed.certificate?.renewWarning {
                Text(clash: warning)
            }
        }
    }

     
     
     
    nonisolated static func actionName(_ kind: ClashAdBlockSnapshot.CertificateActionKind) -> String {
        switch kind {
        case .create: #"create"#
        case .installProfile: #"installProfile"#
        case .installAndTrust: #"installAndTrust"#
        case .openInKeychainAccess: #"openInKeychainAccess"#
        case .makeNew: #"makeNew"#
        }
    }
}

 
 
 
 
@MainActor
final class ClashAdBlockCertificateFeed: ObservableObject {
    @Published private(set) var certificate: ClashAdBlockSnapshot.Certificate?
    @Published private(set) var isBusy: Bool

    init(_ snapshot: ClashAdBlockSnapshot) {
        certificate = snapshot.certificate
        isBusy = snapshot.isBusy
    }

    func take(_ snapshot: ClashAdBlockSnapshot) {
        if certificate != snapshot.certificate { certificate = snapshot.certificate }
        if isBusy != snapshot.isBusy { isBusy = snapshot.isBusy }
    }
}
