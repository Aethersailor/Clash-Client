#if os(iOS)
import ClashClientUI
import Combine
import SwiftUI
import UIKit

 
 
 
 
 
 
 
 

enum ClashFeedbackPhoneLifetime {
     
     
    static let value = ClashFeedbackLifetime(
        reading: .init(base: 0.5, perCharacter: 0.06, minimum: 2, maximum: 5),
        undo: 10, warning: nil, error: nil, withAction: nil, batchSummary: nil
    )
}

private struct ClashFeedbackSceneHostModifier: ViewModifier {
     
    let localeOverride: Locale?
    let colorScheme: ColorScheme?
    let tint: Color?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @StateObject private var center = ClashFeedbackCenter(
        lifetime: ClashFeedbackPhoneLifetime.value,
        announce: { text in
            guard !text.isEmpty else { return }
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    )
    @State private var overlay = ClashFeedbackOverlayWindow()

    func body(content: Content) -> some View {
        content
            .environment(\.clashFeedback, center)
            .background(ClashFeedbackSceneProbe { scene in
                overlay.attach(to: scene, center: center)
                overlay.dress(locale: localeOverride ?? locale, colorScheme: colorScheme, tint: tint)
            })
            .onAppear {
                center.locale = localeOverride ?? locale
                overlay.dress(locale: localeOverride ?? locale, colorScheme: colorScheme, tint: tint)
            }
            .onChange(of: localeOverride ?? locale) { chosen in
                center.locale = chosen
                overlay.dress(locale: chosen, colorScheme: colorScheme, tint: tint)
            }
            .onChange(of: colorScheme) { scheme in overlay.dress(locale: localeOverride ?? locale, colorScheme: scheme, tint: tint) }
            .onChange(of: tint) { color in overlay.dress(locale: localeOverride ?? locale, colorScheme: colorScheme, tint: color) }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .active:
                    center.resume("scene")
                case .inactive:
                    center.pause("scene")
                case .background:
                     
                    center.dropTransient()
                    center.pause("scene")
                @unknown default:
                    break
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
                syncVoiceOver()
            }
            .onAppear { syncVoiceOver() }


    }



     
     
    private func syncVoiceOver() {
        if UIAccessibility.isVoiceOverRunning { center.pause("voiceover") } else { center.resume("voiceover") }
    }
}

extension View {
     
     
    func clashFeedbackSceneHost(locale: Locale?, colorScheme: ColorScheme?, tint: Color?) -> some View {
        modifier(ClashFeedbackSceneHostModifier(localeOverride: locale, colorScheme: colorScheme, tint: tint))
    }
}

 
private struct ClashFeedbackSceneProbe: UIViewRepresentable {
    let found: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.found = found
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.found = found
    }

    final class ProbeView: UIView {
        var found: ((UIWindowScene) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { found?(scene) }
        }
    }
}

 
 
 
@MainActor
final class ClashFeedbackBarPlacement: ObservableObject {
    @Published var top: CGFloat = 52
     
    @Published var locale: Locale = .current
     
     
    @Published var column: ClosedRange<CGFloat>?
}

 
 
@MainActor
final class ClashFeedbackOverlayWindow {
    private var window: PassthroughBarWindow?
    private let placement = ClashFeedbackBarPlacement()
    private var watch: AnyCancellable?
    private weak var center: ClashFeedbackCenter?

     
    func dress(locale: Locale, colorScheme: ColorScheme?, tint: Color?) {
        placement.locale = locale
        guard let window else { return }
        switch colorScheme {
        case .dark?: window.overrideUserInterfaceStyle = .dark
        case .light?: window.overrideUserInterfaceStyle = .light
        default: window.overrideUserInterfaceStyle = .unspecified
        }
        window.tintColor = tint.map { UIColor($0) }
    }

    func attach(to scene: UIWindowScene, center: ClashFeedbackCenter) {
        guard window?.windowScene !== scene else { return }
        self.center = center
        let window = PassthroughBarWindow(windowScene: scene)
         
         
        window.windowLevel = .normal + 2
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: ClashFeedbackTopBar(center: center, placement: placement) { [weak window] id, frame in
            window?.setBarFrame(frame, for: id)
        })
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window
         
        watch = center.objectWillChange.sink { [weak self, weak scene] _ in
            guard let self, let scene else { return }
            DispatchQueue.main.async {
                let page = Self.page(in: scene, center: self.center)
                self.placement.top = page.top
                self.placement.column = page.column
            }
        }
    }

     
     
    static func page(in scene: UIWindowScene, center: ClashFeedbackCenter?) -> (top: CGFloat, column: ClosedRange<CGFloat>?) {
        let pages = scene.windows
            .filter { !($0 is PassthroughBarWindow) && !$0.isHidden && $0.windowLevel < .normal + 2 }
            .sorted { $0.windowLevel > $1.windowLevel }
        for window in pages {
            guard var front = window.rootViewController else { continue }
            var covered = false
            while let presented = front.presentedViewController, !presented.isBeingDismissed {
                front = presented
                covered = true
            }
            let frame = front.view.convert(front.view.bounds, to: nil)
            var top = front.view.convert(CGPoint(x: 0, y: front.view.safeAreaInsets.top), to: nil).y
            var column: ClosedRange<CGFloat>? = frame.minX...frame.maxX
            if let bar = navigationBar(in: front), !bar.isHidden, bar.window != nil {
                let barFrame = bar.convert(bar.bounds, to: nil)
                top = max(top, barFrame.maxY)
                column = barFrame.minX...barFrame.maxX
            }
             
             
            if window.windowLevel == .normal, !covered, let header = center?.lowestHeader {
                top = max(top, header.maxY)
                column = header.minX...header.maxX
            }
            return (top + 6, column)
        }
        return (52, nil)
    }

    private static func navigationBar(in controller: UIViewController) -> UINavigationBar? {
        if let navigation = controller as? UINavigationController { return navigation.navigationBar }
        for child in controller.children.reversed() {
            if let bar = navigationBar(in: child) { return bar }
        }
        return nil
    }
}

private final class PassthroughBarWindow: UIWindow {
     
     
     
    private var barFrames: [Int: CGRect] = [:]

    func setBarFrame(_ frame: CGRect?, for id: Int) {
        barFrames[id] = frame
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard barFrames.values.contains(where: { $0.contains(point) }) else { return nil }
        return super.hitTest(point, with: event)
    }
}

 
struct ClashFeedbackTopBar: View {
    @ObservedObject var center: ClashFeedbackCenter
    @ObservedObject var placement: ClashFeedbackBarPlacement
    let reportFrame: (Int, CGRect?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { window in
            bar(textHeight: max(120, window.size.height * 0.3))
        }
    }

     
     
     
    private func bar(textHeight: CGFloat) -> some View {
        VStack {
            if let entry = center.unclaimed {
                ClashFeedbackCapsule(entry: entry, center: center, textHeight: textHeight)
                    .background(GeometryReader { proxy in
                        Color.clear
                            .onAppear { reportFrame(entry.id, proxy.frame(in: .global)) }
                            .onChange(of: proxy.frame(in: .global)) { reportFrame(entry.id, $0) }
                    })
                    .onDisappear { reportFrame(entry.id, nil) }
                     
                    .gesture(DragGesture(minimumDistance: 12).onEnded { drag in
                        if drag.translation.height < -20 { center.dismiss(entry.id) }
                    })
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .id(entry.id)
            }
            Spacer(minLength: 0)
        }
         
         
         
        .padding(.top, placement.top)
        .padding(.horizontal, 16)
        .frame(width: placement.column.map { $0.upperBound - $0.lowerBound })
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(x: placement.column?.lowerBound ?? 0)
        .ignoresSafeArea(edges: [.top, .leading, .trailing])
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.85),
                   value: center.unclaimed?.id)
        .environment(\.locale, placement.locale)
    }
}

 
 
 
struct ClashFeedbackCapsule: View {
    let entry: ClashFeedbackCenterState.ShownResult
    @ObservedObject var center: ClashFeedbackCenter
    var textHeight: CGFloat = .infinity
    @State private var measuredText: CGFloat?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
     
     
    @Environment(\.colorSchemeContrast) private var contrast

    private var presentation: ClashFeedbackPresentation { entry.presentation }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView(.vertical) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            symbol
                            sentence
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: ClashFeedbackTextHeight.self, value: proxy.size.height)
                        })
                    }
                     
                    .frame(height: min(measuredText ?? textHeight, textHeight))
                    .onPreferenceChange(ClashFeedbackTextHeight.self) { measuredText = $0 }
                    HStack {
                        actionButton
                        Spacer(minLength: 0)
                        closeButton
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    symbol
                    sentence.frame(maxWidth: .infinity, alignment: .leading)
                    actionButton
                    closeButton
                }
            }
        }
         
         
        .frame(minHeight: 44)
        .padding(.vertical, 4)
        .padding(.horizontal, 14)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color(uiColor: .separator).opacity(contrast == .increased ? 1 : 0.5),
                          lineWidth: contrast == .increased ? 1 : 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(presentation.accessibilityIdentifier)
    }

    private var sentence: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(clash: presentation.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress = presentation.progress {
                    Text(verbatim: "\(progress.completed)/\(progress.total)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let message = presentation.message, !message.rawValue.isEmpty {
                Text(clash: message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                     
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if let action = presentation.action, center.offersAction(entry.id) {
            Button {
                center.perform(entry.id)
            } label: {
                Text(clash: ClashFeedbackCopy.title(for: action))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize()
                     
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("feedback.bar.action")
        }
    }

    @ViewBuilder
    private var closeButton: some View {
        if entry.deadline == nil, presentation.kind != .loading {
            Button {
                center.dismiss(entry.id)
            } label: {
                Image(systemName: ClashSymbol.xmark.rawValue)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                     
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
            .accessibilityIdentifier("feedback.bar.close")
        }
    }

     
     
    private var symbol: some View {
        kindSymbol.accessibilityHidden(true)
    }

    @ViewBuilder
    private var kindSymbol: some View {
        switch presentation.kind {
        case .loading:
            ProgressView().controlSize(.small)
        case .success:
            Image(systemName: ClashSymbol.checkmarkCircleFill.rawValue).foregroundStyle(.green)
        case .information:
            Image(systemName: ClashSymbol.infoCircleFill.rawValue).foregroundStyle(.secondary)
        case .warning:
            Image(systemName: ClashSymbol.exclamationmarkTriangleFill.rawValue).foregroundStyle(.orange)
        case .error:
            Image(systemName: ClashSymbol.xmarkOctagonFill.rawValue).foregroundStyle(.red)
        }
    }
}
private struct ClashFeedbackTextHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
#endif
