import Foundation
import SwiftUI

public struct ClashProductPalette {
    public let canvas: Color
    public let surface: Color
    public let raisedFill: Color
    public let separator: Color
     
     
     
     
     
     
    public let card: Color

    public init(
        canvas: Color,
        surface: Color,
        raisedFill: Color,
        separator: Color,
        card: Color? = nil
    ) {
        self.canvas = canvas
        self.surface = surface
        self.raisedFill = raisedFill
        self.separator = separator
        self.card = card ?? surface
    }
}

private extension View {
     
     
     
     
     
     
     
     
     
     
    @ViewBuilder
    func clashTracksScrollDistance(
        _ action: @escaping (CGFloat) -> Void
    ) -> some View {
        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, *) {
            onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, distance in
                action(distance)
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func clashHomePinnedTopBar<Footprint: View, Bar: View>(
        stableFootprint: Bool,
        @ViewBuilder footprint: @escaping () -> Footprint,
        @ViewBuilder bar: @escaping () -> Bar
    ) -> some View {
        if stableFootprint {
            clashStablePinnedTopBar(footprint: footprint, bar: bar)
        } else {
            clashPinnedTopBar(bar)
        }
    }
}

private let clashHomeTopAnchor = "clash.home.top"

 
 
 
private struct ClashHomeCompactingBar<Content: View>: View {
    @ObservedObject private var state: ClashHomeHeaderCompactionState
    private let content: (CGFloat) -> Content

    init(
        state: ClashHomeHeaderCompactionState,
        @ViewBuilder content: @escaping (CGFloat) -> Content
    ) {
        self.state = state
        self.content = content
    }

    var body: some View {
        content(state.progress)
    }
}

 
 
 
 
 
public struct ClashHomeView<Icon: View>: View, Equatable {
     
     
     
     
    nonisolated public static func == (a: Self, b: Self) -> Bool {
        a.snapshot == b.snapshot
            && a.presentationClass == b.presentationClass
    }

     
     
    @Environment(\.locale)
    private var locale
    @Environment(\.clashRegularRootScrollsContent)
    private var regularShellScrollsContent
    @Environment(\.clashRegularShellOwnsCanvas)
    private var regularShellOwnsCanvas

    private let snapshot: AppleClientSnapshot
    private let actions: AppleClientActions
    private let presentationClass: ClashPresentationClass
    private let palette: ClashProductPalette
    private let customizationPresentation: (AnyView) -> AnyView
     
     
     
    private let clearedLostPresentation: () -> Void
    private let icon: (ClashSymbol) -> Icon

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var favoriteCards: [ClashHomeCard]
    @State private var trafficScope: ClashHomeTrafficScope
    @State private var showsCardCustomization = false
    @State private var headerCompaction = ClashHomeHeaderCompactionState()

    public init(
        snapshot: AppleClientSnapshot,
        actions: AppleClientActions,
        presentationClass: ClashPresentationClass,
        palette: ClashProductPalette,
        customizationPresentation: @escaping (AnyView) -> AnyView = {
            $0
        },
        clearedLostPresentation: @escaping () -> Void = {},
        @ViewBuilder icon: @escaping (ClashSymbol) -> Icon
    ) {
        self.snapshot = snapshot
        self.actions = actions
        self.presentationClass = presentationClass
        self.palette = palette
        self.customizationPresentation = customizationPresentation
        self.clearedLostPresentation = clearedLostPresentation
        self.icon = icon
        _favoriteCards = State(initialValue: snapshot.home.favoriteCards)
        _trafficScope = State(initialValue: snapshot.home.trafficScope)
    }

    public var body: some View {
        let _ = ClashPerf.count("home.body")
        Group {
            if regularShellScrollsContent {
                homeContent
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("home.root")
            } else {
                 
                 
                 
                 
                homeScrollView
            }
        }
         
         
         
         
         
         
         
        .clashHomePinnedTopBar(
            stableFootprint: headerCompactionEnabled,
            footprint: { topBar(compaction: 1) },
            bar: {
                if headerCompactionEnabled {
                    ClashHomeCompactingBar(state: headerCompaction) { progress in
                        topBar(compaction: progress)
                    }
                } else {
                    topBar(compaction: 0)
                }
            }
        )
        .background(rootCanvas)
         
         
         
         
         
         
         
        .clashFrameWatch("Home")
        .sheet(isPresented: $showsCardCustomization) {
            ClashHomeCardCustomizationView(
                cards: $favoriteCards,
                palette: palette,
                customizationPresentation: customizationPresentation,
                icon: icon
            )
            .clashModalPresentation(.form)
             
             
             
             
            .clashMacProductModalDismiss {
                showsCardCustomization = false
            }
        }
        .onChange(of: favoriteCards) { cards in
            send(.setCards(cards))
        }
        .onChange(of: snapshot.home.favoriteCards) { cards in
            let normalized = ClashHomeCatalog.normalized(cards)
            if favoriteCards != normalized {
                favoriteCards = normalized
            }
        }
        .onChange(of: snapshot.home.trafficScope) { scope in
            trafficScope = scope
        }
        .onChange(of: headerCompactionEnabled) { enabled in
            if !enabled { headerCompaction.reset() }
        }
    }

    @ViewBuilder
    private var rootCanvas: some View {
        if regularShellOwnsCanvas {
            Color.clear
        } else {
            palette.canvas.ignoresSafeArea()
        }
    }

     
     
     
     
    private var homeScrollView: AnyView {
         
         
         
         
         
        let scroll = ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id(clashHomeTopAnchor)
                    if headerCompactionEnabled {
                         
                         
                         
                         
                        Color.clear
                            .frame(height: headerExpansionDistance)
                    }
                    homeContent
                }
            }
        }
        .accessibilityIdentifier("home.root")

        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
             
             
             
             
            return AnyView(
                scroll.scrollClipDisabled()
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .clashTracksScrollDistance { updateHeaderCompaction(for: $0) }
            )
        }
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, *) {
            return AnyView(
                scroll.scrollClipDisabled()
                    .clashTracksScrollDistance { updateHeaderCompaction(for: $0) }
            )
        }
        return AnyView(scroll)
    }

     
     
     
     
     
    private func updateHeaderCompaction(for distance: CGFloat) {
        headerCompaction.update(
            distance: distance,
            range: headerExpansionDistance,
            enabled: headerCompactionEnabled
        )
    }

     
     
    private var headerCompactionEnabled: Bool {
        presentationClass == .compactTouch
            && !dynamicTypeSize.isAccessibilitySize
    }

     
     
    private var headerExpansionDistance: CGFloat {
        (ClashTheme.Spacing.section - ClashTheme.Spacing.tight)
            + (ClashTheme.Control.minimumHitTarget - 30)
            + ClashTheme.Spacing.row
            + statusRowHeight
            + (ClashTheme.Spacing.compact - ClashTheme.Spacing.tight)
    }

    private var homeContent: some View {
        VStack(spacing: ClashTheme.Spacing.section) {
            homeCards
        }
        .padding(.horizontal, ClashTheme.Spacing.standard)
        .padding(.top, contentTopInset)
        .padding(.bottom, ClashTheme.Spacing.section)
    }

     
     
     
     
     
    private var connection: ClashHomeConnectionPresentation {
        snapshot.selectedProfile == nil && !snapshot.home.profilesLoaded
            ? .loadingProfiles
            : snapshot.home.connection
    }

    @ViewBuilder
    private var homeCards: some View {
        if snapshot.selectedProfile == nil {
             
             
             
            if snapshot.home.profilesLoaded {
                unavailableProfileCard
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.top, ClashTheme.Spacing.section)
            }
        } else {
            commonContent
            runtimeConfigurationContent
        }
    }

    private var contentTopInset: CGFloat {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *),
           presentationClass == .regularTouch {
            return ClashTheme.Spacing.section * 2
        }
        return ClashTheme.Spacing.section
    }

    private func topBar(compaction: CGFloat) -> some View {
        VStack(spacing: 0) {
            header(compaction: compaction)
        }
    }

    private func header(compaction: CGFloat) -> some View {
        let distance = headerExpansionDistance * compaction
        let topReduction = ClashTheme.Spacing.section - ClashTheme.Spacing.tight
        let statusReductionStart = topReduction
        let spacingReductionStart = statusReductionStart + statusRowHeight
        let actionReductionStart = spacingReductionStart + ClashTheme.Spacing.row
        let bottomReductionStart = actionReductionStart
            + (ClashTheme.Control.minimumHitTarget - 30)
        let actionProgress = ClashHomeHeaderCompaction.progress(
            distance: distance - actionReductionStart,
            range: ClashTheme.Control.minimumHitTarget - 30
        )
         
         
         
        let statusOpacity = 1 - ClashHomeHeaderCompaction.progress(
            distance: distance,
            range: ClashTheme.Spacing.row
        )

         
         
         
         
        return VStack(
            alignment: .leading,
            spacing: ClashHomeHeaderCompaction.stagedValue(
                expanded: ClashTheme.Spacing.row,
                compact: 0,
                distance: distance,
                after: spacingReductionStart
            )
        ) {
            profileAndPrimaryAction(compaction: actionProgress)
                 
                .clashFeedbackBarBelow()
            if compaction < 1 {
                connectionStatus
                    .opacity(statusOpacity)
                    .frame(
                        height: ClashHomeHeaderCompaction.stagedValue(
                            expanded: statusRowHeight,
                            compact: 0,
                            distance: distance,
                            after: statusReductionStart
                        ),
                        alignment: .top
                    )
                    .clipped()
            }
        }
        .padding(.horizontal, ClashTheme.Spacing.standard)
        .padding(
            .top,
            ClashHomeHeaderCompaction.stagedValue(
                expanded: ClashTheme.Spacing.section,
                compact: ClashTheme.Spacing.tight,
                distance: distance,
                after: 0
            )
        )
        .padding(
            .bottom,
            ClashHomeHeaderCompaction.stagedValue(
                expanded: ClashTheme.Spacing.compact,
                compact: ClashTheme.Spacing.tight,
                distance: distance,
                after: bottomReductionStart
            )
        )
    }

    @ViewBuilder
    private func profileAndPrimaryAction(compaction: CGFloat) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(
                alignment: .leading,
                spacing: ClashTheme.Spacing.standard
            ) {
                profileButton
                primaryAction(compaction: compaction)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(alignment: .center, spacing: ClashTheme.Spacing.row) {
                profileButton
                Spacer(minLength: ClashTheme.Spacing.compact)
                primaryAction(compaction: compaction)
            }
        }
    }

    private var profileButton: some View {
        Button {
            send(.openProfiles)
        } label: {
            HStack(spacing: ClashTheme.Spacing.compact) {
                 
                 
                 
                 
                 
                 
                 
                icon(.sparklesRectangleStackFill)
                    .font(
                        dynamicTypeSize.isAccessibilitySize
                            ? .headline.weight(.bold)
                            : .title2.weight(.bold)
                    )
                    .foregroundStyle(.tint)
                 
                 
                 
                Text(clash: profileChip.title)
                .font(
                    dynamicTypeSize.isAccessibilitySize
                        ? .headline.weight(.bold)
                        : .title2.weight(.bold)
                )
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                 
                 
                 
                .minimumScaleFactor(0.85)
                .allowsTightening(true)
                .fixedSize(
                    horizontal: false,
                    vertical: dynamicTypeSize.isAccessibilitySize
                )
                switch profileChip.accessory {
                case .picker:
                    icon(.chevronDown)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.secondary)
                case .add:
                     
                     
                     
                    icon(.plusCircle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(Text(clash: profileChip.title))
        .accessibilityHint("Opens Profiles")
        .accessibilityIdentifier("home.profile.open")
    }

    private var profileChip: ClashHomeProfileChipPresentation {
        ClashHomeProfileChipPresenter.presentation(
            selectedProfile: snapshot.selectedProfile,
            isSystemFallback: snapshot.home.selectedProfileIsSystemFallback
        )
    }

     
     
     
     
     
     
     
    @ScaledMetric(relativeTo: .subheadline)
    private var statusRowHeight: CGFloat = 20

    private var connectionStatus: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(
                    alignment: .leading,
                    spacing: ClashTheme.Spacing.compact
                ) {
                    connectionState
                    connectionReason
                }
            } else {
                 
                 
                 
                 
                 
                 
                 
                 
                 
                 
                HStack(spacing: ClashTheme.Spacing.compact) {
                    if connection.issue != nil {
                        connectionReason
                    } else {
                        connectionState
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: statusRowHeight, alignment: .leading)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

     
     
     
     
     
     
     
    private var connectionState: some View {
         
         
         
         
         
         
         
         
         
         
         
         
         
         
         
        ClashHomeConnectionStatus(
            subtitle: ClashCopy.string(
                for: connection.subtitle,
                locale: locale
            ),
            coreStartedAtUnixSeconds:
                snapshot.home.traffic.coreStartedAtUnixSeconds,
            isConnected: connection.phase == .connected,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                && connection.title != "VPN Authorization"
        )
    }

     
     
     
     
     
     
     
     
     
     
    static var issueTint: Color { .orange }

     
     
    @ViewBuilder
    private var connectionReason: some View {
        if let issue = connection.issue {
            Button {
                 
                 
                 
                 
                send(issue.kind.lineTapResetsVPNProfile
                    ? .resetVPNProfile
                    : .showConnectionIssue)
            } label: {
                 
                 
                 
                 
                 
                Text(clash: issue.text)
                     
                     
                     
                    .multilineTextAlignment(.leading)
                     
                     
                     
                     
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
                     
                     
                     
                     
                     
                     
                     
                     
                     
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .contentShape(Rectangle())
             
             
             
             
             
             
            .foregroundStyle(Self.issueTint)
            .accessibilityIdentifier("home.connection.reason")
            .accessibilityValue(Text(clash: issue.text))
             
             
            .accessibilityHint(
                issue.kind.lineTapResetsVPNProfile
                    ? Text(clash: .copy("Reinstalls the VPN profile"))
                    : Text("")
            )
        }
    }

    private func primaryAction(compaction: CGFloat) -> some View {
        Group {
            if let title = connection.primaryActionTitle {
                Button {
                    send(
                        .performPrimaryAction(
                            connection.primaryAction
                        )
                    )
                } label: {
                    primaryActionLabel(title, compaction: compaction)
                }
                .clashPrimaryActionButtonStyle()
                .modifier(ClashHomeCapsuleButtonShape())
                .controlSize(.regular)
                .tint(
                    connection.primaryAction == .disconnect
                        ? .green
                        : .blue
                )
                .disabled(
                    !connection.primaryActionEnabled
                        || snapshot.home.isProfileActionInFlight
                )
                .accessibilityIdentifier("overview.connection.action")
            } else {
                 
                 
                 
                 
                 
                let cancellable =
                    connection.primaryAction == .cancel
                Button {
                    if cancellable {
                        send(.performPrimaryAction(.cancel))
                    }
                } label: {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                 
                 
                 
                 
                 
                 
                 
                .modifier(ClashHomeGlassSpinnerStyle())
                .modifier(ClashHomeCapsuleButtonShape())
                .controlSize(.regular)
                .disabled(!cancellable)
                .accessibilityLabel(
                    cancellable
                        ? ClashCopy.key("Cancel Connecting")
                        : ClashCopy.key(connection.title)
                )
                .accessibilityIdentifier("overview.connection.action")
            }
        }
        .frame(
            minWidth: 104,
            idealWidth: dynamicTypeSize.isAccessibilitySize ? nil : 104,
            maxWidth: dynamicTypeSize.isAccessibilitySize ? nil : 104,
            minHeight: primaryActionHeight(compaction: compaction),
            idealHeight: primaryActionHeight(compaction: compaction),
            maxHeight: dynamicTypeSize.isAccessibilitySize
                ? nil
                : primaryActionHeight(compaction: compaction)
        )
    }

     
     
     
     
     
     
     
    private func primaryActionHeight(compaction: CGFloat) -> CGFloat {
        ClashHomeHeaderCompaction.value(
            expanded: ClashTheme.Control.minimumHitTarget,
            compact: 30,
            progress: compaction
        )
    }

    @ViewBuilder
    private func primaryActionLabel(
        _ title: String,
        compaction: CGFloat
    ) -> some View {
        let label = Text(ClashCopy.key(title))
            .font(.subheadline.weight(.bold))
            .multilineTextAlignment(.center)
            .lineLimit(1)

        if dynamicTypeSize.isAccessibilitySize {
            label
                .fixedSize(horizontal: true, vertical: true)
                .frame(minHeight: 32)
        } else {
            label.frame(
                maxWidth: .infinity,
                minHeight: ClashHomeHeaderCompaction.value(
                    expanded: 32,
                    compact: 16,
                    progress: compaction
                )
            )
        }
    }

    private var commonContent: some View {
        Group {
            ForEach(ClashHomeCatalog.visibleCards(favoriteCards, mode: ClashHomeCatalog.ClashHomeCardMode(rawValue: snapshot.home.routing.mode.rawValue) ?? .rule)) { card in
                 
                 
                 
                 
                 
                 
                 
                ClashPerf.measure("home.card") {
                    commonCard(card)
                }
                .id(card.id)
            }
            if favoriteCards.isEmpty {
                ClashHomePrimaryPageCard(palette: palette) {
                    VStack(
                        alignment: .leading,
                        spacing: ClashTheme.Spacing.compact
                    ) {
                        Text(ClashCopy.key("No Favorite Cards"))
                            .font(.headline)
                        Text(
                            ClashCopy.key(
                                "Choose the controls you want to keep close at hand."
                            )
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("home.cards.empty")
            }
            Button {
                showsCardCustomization = true
            } label: {
                Label {
                    Text(ClashCopy.key("Customize Cards"))
                } icon: {
                    icon(.plus)
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, ClashTheme.Spacing.compact)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("home.cards.customize")
        }
    }

    @ViewBuilder
    private func commonCard(_ card: ClashHomeCard) -> some View {
        switch card {
        case .routing:
            ClashHomeRoutingCard(
                mode: snapshot.home.routing.mode,
                palette: palette,
                icon: icon
            ) { mode in
                Task {
                    try? await actions.perform(
                        .setOutboundMode(mode),
                        allowedBy: snapshot
                    )
                }
            }
            .equatable()
        case .proxies:
            ClashHomeDomainCountCard(
                card: card,
                snapshot: snapshot.home.proxies,
                identifier: "home.context.tile.proxies",
                palette: palette,
                icon: icon
            ) {
                send(.openProxies)
            }
            .equatable()
        case .rules:
            ClashHomeDomainCountCard(
                card: card,
                snapshot: snapshot.home.rules,
                identifier: "home.context.tile.rules",
                palette: palette,
                icon: icon
            ) {
                send(.openRules)
            }
            .equatable()
        case .traffic:
             
             
             
            ClashHomeTrafficCardFeed(
                fallback: snapshot.home.traffic,
                scope: $trafficScope,
                palette: palette,
                icon: icon
            )
            .onChange(of: trafficScope) { scope in
                send(.setTrafficScope(scope))
            }
        case .externalIP:
            ClashHomeExternalIPCard(
                snapshot: snapshot.home.egress,
                palette: palette,
                icon: icon
            ) {
                send(.refreshExternalIP)
            }
            .equatable()
        case .lanIP:
            ClashHomeLANIPCard(
                address: snapshot.home.lanAddress,
                palette: palette,
                icon: icon
            ) {
                send(.refreshLANIP)
            }
            .equatable()
        }
    }

    private var runtimeConfigurationContent: some View {
        Group {
            Button {
                send(.openRuntimeConfiguration)
            } label: {
                Label {
                    Text(
                        ClashCopy.key(
                            "View Runtime Configuration"
                        )
                    )
                } icon: {
                    icon(.docText)
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, ClashTheme.Spacing.compact)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityIdentifier(
                "home.modify.view-runtime-config"
            )
        }
    }

    private var unavailableProfileCard: some View {
        ClashHomePrimaryPageCard(palette: palette) {
            VStack(
                alignment: .leading,
                spacing: ClashTheme.Spacing.standard
            ) {
                ClashHomeCardTitle(
                    cardTitle: "Profile Unavailable",
                    symbol: .exclamationmarkTriangle,
                    tint: .orange,
                    icon: icon
                )
                Group {
                    if let reason = snapshot.home.profilesUnavailableReason,
                       !reason.isEmpty {
                        Text(verbatim: reason)
                    } else {
                        Text(
                            ClashCopy.key(
                                "Clash could not prepare its local Direct profile. Open Profiles to retry without replacing your data."
                            )
                        )
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Button {
                    send(.openProfiles)
                } label: {
                    Text(ClashCopy.key("Open Profiles"))
                }
                .clashPrimaryActionButtonStyle()
                .modifier(ClashHomeCapsuleButtonShape())
                .accessibilityIdentifier(
                    "home.unavailable.open-profiles"
                )
            }
        }
        .accessibilityIdentifier("home.card.profile-unavailable")
    }

    private func send(_ command: ClashHomeCommand) {
         
         
         
         
         
         
        if command.opensAPresentation, showsCardCustomization {
            showsCardCustomization = false
            clearedLostPresentation()
        }
        Task {
            try? await actions.perform(.home(command), allowedBy: snapshot)
        }
    }
}

extension ClashHomeCommand {
     
     
    var opensAPresentation: Bool {
        switch self {
        case .openProfiles, .showConnectionIssue, .openProxies, .openRules,
             .openRuntimeConfiguration:
            true
        case .performPrimaryAction(let action):
             
            action == .openProfiles || action == .connect || action == .retry
        case .resetVPNProfile, .setCards, .setTrafficScope, .refreshExternalIP,
             .refreshLANIP:
            false
        }
    }
}

private struct ClashHomeGlassSpinnerStyle: ViewModifier {
     
     
    func body(content: Content) -> AnyView {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
            return AnyView(content.buttonStyle(.glass))
        }
        return AnyView(content.buttonStyle(.bordered))
    }
}

private struct ClashHomeCapsuleButtonShape: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.buttonBorderShape(.capsule)
        } else {
            content
        }
    }
}

private struct ClashHomePrimaryPageCard<Content: View>: View {
    let palette: ClashProductPalette
    let isInteractive: Bool
     
     
     
     
     
     
     
    let managesHorizontalInsets: Bool
    let content: Content

    init(
        palette: ClashProductPalette,
        isInteractive: Bool = false,
        managesHorizontalInsets: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.palette = palette
        self.isInteractive = isInteractive
        self.managesHorizontalInsets = managesHorizontalInsets
        self.content = content()
    }

     
     
     
     
    var body: AnyView {
         
         
         
         
         
         
         
        let _ = ClashPerf.count("home.card.body")
        let padded = content
            .padding(
                managesHorizontalInsets ? .top : .all,
                ClashTheme.Spacing.standard
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        let traditionalCard = ClashCardSurface(
            fill: palette.card,
            separator: palette.separator,
             
             
             
             
            paintsInSettingsIdiom: true
        ) {
            padded
        }

         
         
         
         
         
         
         
         
         
         
         
         
         
         
         
         
        let wearsPlatformMaterial: Bool = {
            if ClashPerfExperiment.suppressesGlass { return false }
            if ClashPlatformLayout.primaryPageCardUsesLiquidGlass { return true }
            if ClashPlatformLayout.pageUsesSystemSettingsIdiom { return false }
             
             
             
            return ClashPlatformLayout.touchCardWearsSystemMaterial
        }()

         
         
         
         
         
         
         
         
         
        let cardCorner = ClashPlatformLayout.primaryPageCardUsesLiquidGlass
            ? ClashTheme.Radius.card
            : ClashTheme.Radius.liquidGlassCard

        if wearsPlatformMaterial,
           #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
             
             
             
             
             
             
             
            return AnyView(
                padded
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: cardCorner,
                            style: .continuous
                        )
                    )
                    .glassEffect(
                        isInteractive ? .regular.interactive() : .regular,
                        in: .rect(cornerRadius: cardCorner)
                    )
            )
        }
        return AnyView(traditionalCard)
    }
}

 
 
 
 
 
 
private struct ClashHomeConnectionStatus: View {
    let subtitle: String
    let coreStartedAtUnixSeconds: Int64
    let isConnected: Bool
    let isAccessibilitySize: Bool

    @State private var now = Date()
     
    @Environment(\.locale) private var locale

    var body: some View {
        let seconds = ClashConnectionDuration.secondsElapsed(
            sinceUnixSeconds: coreStartedAtUnixSeconds,
            now: now
        )
        Text(
            ClashHomeStatusLine.text(
                subtitle: subtitle,
                duration: seconds.map {
                    ClashConnectionDuration.text(secondsElapsed: $0, locale: locale)
                },
                isConnected: isConnected
            )
        )
        .monospacedDigit()
        .lineLimit(isAccessibilitySize ? 3 : 1)
         
         
         
        .truncationMode(.middle)
        .fixedSize(horizontal: false, vertical: isAccessibilitySize)
        .accessibilityLabel(
            ClashHomeStatusLine.accessibilityLabel(
                subtitle: subtitle,
                secondsElapsed: seconds,
                isConnected: isConnected
            )
        )
        .accessibilityIdentifier("home.connection.subtitle")
        .modifier(ClashHomeDurationTicker(now: $now))
    }
}

private struct ClashHomeCardTitle<Icon: View>: View {
    let cardTitle: String
    let symbol: ClashSymbol
    let tint: Color?
     
     
     
     
     
    let followsAccent: Bool
    let icon: (ClashSymbol) -> Icon

    init(
        cardTitle: String,
        symbol: ClashSymbol,
        icon: @escaping (ClashSymbol) -> Icon
    ) {
        self.cardTitle = cardTitle
        self.symbol = symbol
        self.tint = nil
        self.followsAccent = false
        self.icon = icon
    }

     
     
     
     
    init(
        cardTitle: String,
        symbol: ClashSymbol,
        followsAccent: Bool,
        icon: @escaping (ClashSymbol) -> Icon
    ) {
        self.cardTitle = cardTitle
        self.symbol = symbol
        self.tint = nil
        self.followsAccent = followsAccent
        self.icon = icon
    }

    init(
        cardTitle: String,
        symbol: ClashSymbol,
        tint: Color,
        followsAccent: Bool = false,
        icon: @escaping (ClashSymbol) -> Icon
    ) {
        self.cardTitle = cardTitle
        self.symbol = symbol
        self.tint = tint
        self.followsAccent = followsAccent
        self.icon = icon
    }

    var body: some View {
        ClashCardTitle(
            titleTint: tint ?? .primary,
            iconTint: tint ?? .primary,
            followsAccent: followsAccent
        ) {
            Text(ClashCopy.key(cardTitle))
        } icon: {
            icon(symbol)
                .modifier(ClashSymbolBreath(value: symbol))
                .modifier(ClashGlyphSlot())
        }
    }
}

 
 
 
 
 
 
private struct ClashSymbolBreath: ViewModifier {
    let value: ClashSymbol

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, *) {
            content
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.13), value: value)
        } else {
            content
        }
    }
}

 
 
 
 
 
 
 
 
private struct ClashGlyphSlot: ViewModifier {
    @ScaledMetric(relativeTo: .headline) private var width: CGFloat = 26

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: width, alignment: .center)
    }
}

 
 
 
private struct ClashHomeTrafficCardFeed<Icon: View>: View {
    let fallback: AppleClientTrafficSnapshot
    @Binding var scope: ClashHomeTrafficScope
    let palette: ClashProductPalette
    let icon: (ClashSymbol) -> Icon
    @Environment(\.clashTrafficFeed) private var feed

    var body: some View {
        if let feed {
            ClashHomeTrafficCardObserving(feed: feed, scope: $scope, palette: palette, icon: icon)
        } else {
            ClashHomeTrafficCard(traffic: fallback, scope: $scope, palette: palette, icon: icon)
                .equatable()
        }
    }
}

private struct ClashHomeTrafficCardObserving<Icon: View>: View {
    @ObservedObject var feed: ClashTrafficFeed
    @Binding var scope: ClashHomeTrafficScope
    let palette: ClashProductPalette
    let icon: (ClashSymbol) -> Icon

    var body: some View {
        ClashHomeTrafficCard(traffic: feed.traffic, scope: $scope, palette: palette, icon: icon)
            .equatable()
    }
}

private struct ClashHomeTrafficCard<Icon: View>: View {
     
     
    @Environment(\.locale) private var locale
    @Environment(\.clashThroughputUnit) private var throughputUnit
    let traffic: AppleClientTrafficSnapshot
    @Binding var scope: ClashHomeTrafficScope
    let palette: ClashProductPalette
    let icon: (ClashSymbol) -> Icon

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let _ = ClashPerf.count("home.traffic.card")
        ClashHomePrimaryPageCard(palette: palette) {
            VStack(
                alignment: .leading,
                spacing: ClashTheme.Spacing.standard
            ) {
                ClashHomeCardTitle(
                    cardTitle: ClashHomeCard.traffic.title,
                    symbol: ClashHomeCard.traffic.symbol,
                    icon: icon
                )
                metrics
                rateHistory
                ClashHomeTrafficScopeTabs(scope: $scope)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("home.traffic.scope")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.card.traffic")
        .modifier(ClashTrafficCardHeightWitness())
    }

    @ViewBuilder
    private var metrics: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: ClashTheme.Spacing.row) {
                uploadMetric
                downloadMetric
            }
        } else {
            HStack(
                alignment: .top,
                spacing: ClashTheme.Spacing.row
            ) {
                uploadMetric
                downloadMetric
            }
        }
    }

     
     
     
     
     
     
     
     
     
    @ViewBuilder
    private var rateHistory: some View {
        let series = ClashTrafficSeries.normalizedPair(
            upload: traffic.uploadRatesBytesPerSecond,
            download: traffic.downloadRatesBytesPerSecond
        )
        let hasShape = series.upload.count >= 2
            || series.download.count >= 2
        let hasTraffic = series.upload.contains { $0 > 0 }
            || series.download.contains { $0 > 0 }
         
         
         
         
         
         
        ZStack(alignment: .bottom) {
            if hasShape, hasTraffic {
                 
                 
                ClashRateSparkline(
                    series: [
                        .init(values: series.download, tint: .blue),
                        .init(values: series.upload, tint: .green),
                    ]
                )
                .accessibilityLabel(
                    "Upload and download over the last 30 seconds"
                )
                .accessibilityIdentifier("home.traffic.history")
            } else {
                 
                 
                 
                 
                 
                ClashRateSparkline(
                    series: [
                        .init(
                            values: [0, 0],
                            tint: palette.separator
                        ),
                    ]
                )
                .accessibilityLabel(
                    "No traffic in the last 30 seconds"
                )
                .accessibilityIdentifier("home.traffic.history.zero")
            }
        }
        .frame(height: 34)
    }

    private var uploadMetric: some View {
        metric(
            title: "Upload",
            symbol: .arrowUp,
            tint: .green,
            rate: ClashHomeByteRateFormatter.string(
                traffic.uploadBytesPerSecond, unit: throughputUnit
            ),
            total: ClashHomeByteCountFormatter.string(
                traffic.uploadTotalBytes
            )
        )
    }

    private var downloadMetric: some View {
        metric(
            title: "Download",
            symbol: .arrowDown,
            tint: .blue,
            rate: ClashHomeByteRateFormatter.string(
                traffic.downloadBytesPerSecond, unit: throughputUnit
            ),
            total: ClashHomeByteCountFormatter.string(
                traffic.downloadTotalBytes
            )
        )
    }

    private func metric(
        title: String,
        symbol: ClashSymbol,
        tint: Color,
        rate: String,
        total: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(ClashCopy.key(title))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            } icon: {
                icon(symbol).foregroundStyle(tint)
            }
             
             
            Text(rate)
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(
                verbatim: "\(total) \(ClashCopy.string("total", locale: locale))"
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

 
 
 
 
 
 
private struct ClashTrafficCardHeightWitness: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, tvOS 18.0, *) {
            content.onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                ClashPerf.emit("traffic-card height=\(Int(height))")
            }
        } else {
            content
        }
    }
}

private struct ClashHomeExternalIPCard<Icon: View>: View {
    let snapshot: ClashHomeEgressSnapshot
    let palette: ClashProductPalette
    let icon: (ClashSymbol) -> Icon
    let refresh: () -> Void

    var body: some View {
        ClashHomePrimaryPageCard(palette: palette) {
            VStack(
                alignment: .leading,
                spacing: ClashTheme.Spacing.compact
            ) {
                HStack(spacing: ClashTheme.Spacing.row) {
                    ClashHomeCardTitle(
                        cardTitle: ClashHomeCard.externalIP.title,
                        symbol: ClashHomeCard.externalIP.symbol,
                        icon: icon
                    )
                    Spacer(minLength: 0)
                    Button(action: refresh) {
                        icon(.arrowClockwise)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(
                                snapshot.canRefresh
                                    ? AnyShapeStyle(.tint)
                                    : AnyShapeStyle(.secondary)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!snapshot.canRefresh)
                    .accessibilityIdentifier("home.externalIP.check")
                }
                 
                 
                 
                 
                HStack(spacing: ClashTheme.Spacing.compact) {
                    if let address = snapshot.address,
                       !snapshot.flag.isEmpty {
                        let _ = address
                        ClashRegionalFlag.label(snapshot.flag, pointSize: 20, relativeTo: .title3).font(.title3)
                    }
                     
                     
                    Text(snapshot.address ?? "—")
                        .font(.title3.weight(.semibold).monospaced())
                        .foregroundStyle(
                            snapshot.address == nil ? .secondary : .primary
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                Group {
                    if snapshot.address != nil, !snapshot.detail.isEmpty {
                        Text(clash: .verbatim(snapshot.detail))
                    } else {
                        Text(ClashCopy.key(
                            snapshot.isChecking
                                ? "Checking…"
                                : "Connect Clash to check"
                        ))
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.card.externalIP")
    }
}

private struct ClashHomeLANIPCard<Icon: View>: View {
    let address: String?
    let palette: ClashProductPalette
    let icon: (ClashSymbol) -> Icon
    let refresh: () -> Void

    var body: some View {
        ClashHomePrimaryPageCard(palette: palette) {
            VStack(
                alignment: .leading,
                spacing: ClashTheme.Spacing.compact
            ) {
                HStack(spacing: ClashTheme.Spacing.row) {
                    ClashHomeCardTitle(
                        cardTitle: ClashHomeCard.lanIP.title,
                        symbol: ClashHomeCard.lanIP.symbol,
                        icon: icon
                    )
                    Spacer(minLength: 0)
                    Button(action: refresh) {
                        icon(.arrowClockwise)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.lanIP.refresh")
                }
                 
                 
                 
                Text(address ?? "—")
                    .font(.title3.weight(.semibold).monospaced())
                    .foregroundStyle(address == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(
                    ClashCopy.key(
                        address != nil
                            ? "This device"
                            : "Not on a local network"
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.card.lanIP")
        .onAppear(perform: refresh)
    }
}

private struct ClashHomeRoutingCard<Icon: View>: View {
    let mode: AppleClientOutboundMode
    let palette: ClashProductPalette
    let icon: (ClashSymbol) -> Icon
    let setMode: (AppleClientOutboundMode) -> Void

     
     
     
    @Namespace private var selectionBand

     
     
     
     
     
     
     
     
     
     
     
     
    @State private var isCollapsingSelection = false

     
     
    static func symbol(for mode: AppleClientOutboundMode) -> ClashSymbol {
        switch mode {
        case .global: .arrowTriangleMerge
        case .direct: .arrowLeftAndRight
        default: .arrowTriangleBranch
        }
    }

    var body: some View {
        ClashHomePrimaryPageCard(
            palette: palette,
            managesHorizontalInsets: true
        ) {
            VStack(
                alignment: .leading,
                spacing: ClashTheme.Spacing.standard
            ) {
                ClashHomeCardTitle(
                    cardTitle: ClashHomeCard.routing.title,
                    symbol: Self.symbol(for: mode),
                    followsAccent: true,
                    icon: icon
                )
                .padding(.horizontal, ClashTheme.Spacing.standard)
                VStack(spacing: 0) {
                    modeRows
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.card.routing")
    }

    @ViewBuilder
    private var modeRows: some View {
        modeRow(
            .global,
            title: "Global",
            subtitle:
                "Send all traffic through the selected proxy"
        )
        modeRow(
            .rule,
            title: "Rule",
            subtitle: "Route traffic by the profile rules"
        )
        modeRow(
            .direct,
            title: "Direct",
            subtitle: "Connect directly, without a proxy"
        )
    }


    private func modeRow(
        _ candidate: AppleClientOutboundMode,
        title: String,
        subtitle: String
    ) -> some View {
        let isSelected = mode == candidate
        return Button {
             
             
             
             
             
            withAnimation(
                .spring(response: 0.36, dampingFraction: 0.82)
            ) {
                setMode(candidate)
            }
        } label: {
            HStack(
                alignment: .center,
                spacing: ClashTheme.Spacing.row
            ) {
                 
                 
                 
                 
                ClashSelectionMark(isSelected: isSelected)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ClashCopy.key(title))
                        .font(
                            .title3.weight(
                                isSelected ? .bold : .semibold
                            )
                        )
                        .foregroundStyle(titleStyle(isSelected))
                    if isSelected, !isCollapsingSelection {
                        Text(ClashCopy.key(subtitle))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                             
                             
                             
                             
                             
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 0)
            }
             
             
             
             
             
             
             
            .padding(.vertical, ClashTheme.Spacing.row)
            .padding(.horizontal, ClashTheme.Spacing.standard)
            .frame(
                maxWidth: .infinity,
                minHeight: ClashHomeOutboundModeRowMetrics.minimumHeight,
                alignment: .leading
            )
            .background(selectionBackground(isSelected))
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityIdentifier("home.mode.\(candidate.rawValue)")
    }

    @ViewBuilder
    private func selectionBackground(_ isSelected: Bool) -> some View {
         
         
         
        if isSelected {
            selectionFill
                .matchedGeometryEffect(
                    id: "home.routing.selection",
                    in: selectionBand
                )
        }
    }

     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
    private func titleStyle(_ isSelected: Bool) -> AnyShapeStyle {
        isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary)
    }

     
     
     
     
     
    private var selectionFill: some View {
        Rectangle().fill(.quaternary)
    }
}

private struct ClashHomeDomainCountCard<Icon: View>: View {
    @Environment(\.locale)
    private var locale
    let card: ClashHomeCard
    let snapshot: ClashHomeDomainSnapshot
    let identifier: String
    let palette: ClashProductPalette
    let icon: (ClashSymbol) -> Icon
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ClashHomePrimaryPageCard(
            palette: palette,
            isInteractive: true
        ) {
            Button(action: action) {
                summary
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityIdentifier(identifier)
        }
        .accessibilityElement(children: .contain)
    }

    private var summary: some View {
        VStack(
            alignment: .leading,
            spacing: ClashTheme.Spacing.compact
        ) {
            HStack(spacing: 0) {
                ClashHomeCardTitle(
                    cardTitle: card.title,
                    symbol: card.symbol,
                    icon: icon
                )
                Spacer(minLength: ClashTheme.Spacing.compact)
                icon(.chevronForward)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            if let count = snapshot.count {
                countSummary(count)
            }
            if !snapshot.names.isEmpty {
                ClashRegionalFlag.label(snapshot.names.joined(separator: " · "), pointSize: 12, relativeTo: .caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(
                        dynamicTypeSize.isAccessibilitySize ? 3 : 1
                    )
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func countSummary(_ count: Int) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(
                alignment: .leading,
                spacing: ClashTheme.Spacing.tight
            ) {
                countLabel(count)
                breakdownLabel
            }
        } else {
            HStack(
                alignment: .firstTextBaseline,
                spacing: ClashTheme.Spacing.compact
            ) {
                countLabel(count)
                breakdownLabel
            }
        }
    }

     
     
     
     
    private func countLabel(_ count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(count, format: .number)
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            if let unit = snapshot.countUnit {
                Text(clash: .copy(unit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
         
         
         
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenCount(count))
        .accessibilityIdentifier("\(identifier).count")
    }

     
    private func spokenCount(_ count: Int) -> String {
        let number = count.formatted(.number.locale(locale))
        guard let unit = snapshot.countUnit else { return number }
        return "\(number) \(ClashCopy.string(unit, locale: locale))"
    }

    @ViewBuilder
    private var breakdownLabel: some View {
        if let breakdown = snapshot.breakdown {
            Text(breakdown)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(identifier).breakdown")
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                .fixedSize(
                    horizontal: false,
                    vertical: dynamicTypeSize.isAccessibilitySize
                )
        }
    }

    private var accessibilitySummary: String {
        var result = ClashCopy.string(card.title, locale: locale)
        if let count = snapshot.count {
            result = "\(count) \(result)"
        }
        if let breakdown = snapshot.breakdown {
            result += ", \(breakdown)"
        }
        return result
    }
}

private struct ClashHomeCardCustomizationView<Icon: View>: View {
    @Binding var cards: [ClashHomeCard]
    let palette: ClashProductPalette
    let customizationPresentation: (AnyView) -> AnyView
    let icon: (ClashSymbol) -> Icon

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var availableCards: [ClashHomeCard] {
        ClashHomeCatalog.optionalCards.filter { !cards.contains($0) }
    }

    var body: some View {
        ClashSingleColumnNavigationContainer {
            customizationPresentation(AnyView(content))
        }
         
         
         
         
         
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.cards.customization")
    }

    private var content: some View {
        List {
            if dynamicTypeSize.isAccessibilitySize {
                Text(ClashCopy.key("Customize Cards"))
                    .font(.largeTitle.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .listRowBackground(Color.clear)
            }

            Section {
                ForEach(cards) { card in
                    cardLabel(card)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        ClashCopy.key(card.title)
                    )
                    .accessibilityIdentifier(
                        "home.cards.favorite.\(card.rawValue)"
                    )
                    .accessibilityValue(
                        ClashHomeCatalog.requiredCards.contains(card)
                            ? "Required"
                            : "Optional"
                    )
                    .accessibilityHint(
                        ClashHomeCatalog.requiredCards.contains(card)
                            ? "Always stays on Home"
                            : "Can be removed from Home"
                    )
                    .deleteDisabled(
                        ClashHomeCatalog.requiredCards.contains(card)
                    )
                    .id("favorite.\(card.rawValue)")
                }
                .onDelete { offsets in
                    cards.remove(
                        atOffsets: IndexSet(
                            offsets.filter {
                                !ClashHomeCatalog.requiredCards.contains(
                                    cards[$0]
                                )
                            }
                        )
                    )
                }
                .onMove {
                    cards.move(fromOffsets: $0, toOffset: $1)
                }
            } header: {
                Text(ClashCopy.key("Favorites"))
            } footer: {
                Text(
                    ClashCopy.key(
                        "Outbound Mode, Proxies, and Rules always stay on Home. Drag any card to change the order."
                    )
                )
            }

            if !availableCards.isEmpty {
                Section(ClashCopy.key("Available")) {
                    ForEach(availableCards) { card in
                        Button {
                            cards.append(card)
                        } label: {
                            HStack {
                                cardLabel(card)
                                Spacer()
                                icon(.plus)
                                    .foregroundStyle(.tint)
                            }
                        }
                        .accessibilityIdentifier(
                            "home.cards.available.\(card.rawValue)"
                        )
                        .id("available.\(card.rawValue)")
                    }
                }
            }
        }
        .navigationTitle(
            dynamicTypeSize.isAccessibilitySize
                ? ""
                : ClashCopy.key("Customize Cards")
        )
        .clashToolbarUnlessInPanel {
             
             
             
            ToolbarItem(placement: .cancellationAction) {
                ClashSheetCloseButton { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(ClashCopy.key("Reset")) {
                    cards = ClashHomeCatalog.defaultCards
                }
            }
        }
    }

    @ViewBuilder
    private func cardLabel(_ card: ClashHomeCard) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            Text(ClashCopy.key(card.title))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label {
                Text(ClashCopy.key(card.title))
            } icon: {
                 
                 
                if card.symbol == .serverRack {
                    icon(card.symbol)
                        .font(.body.weight(.light))
                } else {
                    icon(card.symbol)
                }
            }
        }
    }
}

 
 
private enum ClashHomeByteRateFormatter {
    static func string(_ bytesPerSecond: Int64, unit: ClashThroughputUnit) -> String {
        ClashThroughputFormatter.rate(bytesPerSecond, unit: unit)
    }
}

 
 
private enum ClashHomeByteCountFormatter {
    static func string(_ bytes: Int64) -> String {
        ClashThroughputFormatter.usage(bytes)
    }
}

 
 
 
 
 
 
private struct ClashHomeDurationTicker: ViewModifier {
    @Binding var now: Date

    func body(content: Content) -> some View {
        content
            .onAppear { now = Date() }
            .modifier(ClashSecondTick(now: $now))
    }
}

private struct ClashSecondTick: ViewModifier {
    @Binding var now: Date

    func body(content: Content) -> some View {
        if ClashPerfExperiment.suppressesDurationTick {
            content
        } else if #available(iOS 15.0, macOS 12.0, tvOS 15.0, *) {
            content.task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    now = Date()
                }
            }
        } else {
            content
        }
    }
}

 
extension ClashProductPalette: Equatable {}

 

 
 
 
 
extension ClashHomeTrafficCard: @MainActor Equatable {
    static func == (a: Self, b: Self) -> Bool {
        a.traffic == b.traffic && a.scope == b.scope && a.palette == b.palette
    }
}

extension ClashHomeExternalIPCard: @MainActor Equatable {
    static func == (a: Self, b: Self) -> Bool {
        a.snapshot == b.snapshot && a.palette == b.palette
    }
}

extension ClashHomeLANIPCard: @MainActor Equatable {
    static func == (a: Self, b: Self) -> Bool {
        a.address == b.address && a.palette == b.palette
    }
}

extension ClashHomeRoutingCard: @MainActor Equatable {
    static func == (a: Self, b: Self) -> Bool {
        a.mode == b.mode && a.palette == b.palette
    }
}

extension ClashHomeDomainCountCard: @MainActor Equatable {
    static func == (a: Self, b: Self) -> Bool {
        a.card == b.card && a.snapshot == b.snapshot
            && a.identifier == b.identifier && a.palette == b.palette
    }
}

