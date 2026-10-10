import SwiftUI

public extension View {
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
     
    func clashPinnedTopBar<Bar: View>(
        @ViewBuilder _ bar: @escaping () -> Bar
    ) -> AnyView {
        if ClashPinnedTopBarPolicy.usesSystemScrollPocket {
             
             
             
             
             
             
             
             
             
            if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
                return AnyView(safeAreaBar(edge: .top, spacing: 0, content: bar))
            }
            return AnyView(self)
        }
        return AnyView(
            safeAreaInset(edge: .top, spacing: 0) {
                bar().modifier(ClashPreScrollEdgeBarGround())
            }
        )
    }

     
     
     
     
     
     
     
    @ViewBuilder
    func clashStablePinnedTopBar<Footprint: View, Bar: View>(
        @ViewBuilder footprint: @escaping () -> Footprint,
        @ViewBuilder bar: @escaping () -> Bar
    ) -> some View {
        if ClashPinnedTopBarPolicy.usesSystemScrollPocket {
            clashPinnedTopBar {
                footprint()
                    .hidden()
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                    .overlay(alignment: .top) {
                        bar()
                    }
            }
             
             
             
             
             
             
             
            .overlay(alignment: .top) {
                 
                 
                 
                 
                bar()
                    .opacity(0.001)
                    .allowsHitTesting(true)
                    .accessibilityHidden(true)
                    .accessibilityRepresentation { Color.clear }
            }
        } else {
            clashPinnedTopBar {
                footprint()
                    .hidden()
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                    .overlay(alignment: .top) {
                         
                         
                         
                         
                        bar().modifier(ClashPreScrollEdgeBarGround())
                    }
            }
        }
    }
}

 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
 
enum ClashPinnedTopBarPolicy {
    static var usesSystemScrollPocket: Bool {
#if os(macOS)
        return false
#else
        if #available(iOS 26.0, tvOS 26.0, *) { return true }
        return false
#endif
    }
}

private struct ClashPreScrollEdgeBarGround: ViewModifier {
    @Environment(\.clashDetailCanvas) private var canvas
    @Environment(\.clashRegularShellOwnsCanvas) private var shellOwnsCanvas

    func body(content: Content) -> some View {
        if shellOwnsCanvas, let canvas {
            content.background(canvas)
        } else {
            content.background(.bar)
        }
    }
}
