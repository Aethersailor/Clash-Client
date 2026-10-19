#if os(iOS) || os(macOS)
import ClashClientUI
import SwiftUI

 
 
 
 
 
 
struct AdBlockPageHost: View {
    @ObservedObject var model: AdBlockPageModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale

     
    static let pollInterval: UInt64 = 5_000_000_000

    var body: some View {
        ClashClientUI.ClashAdBlockView(
            snapshot: model.snapshot,
            perform: { model.perform($0) },
            detail: { model.details[$0] }
        ) { dismiss in
            AdBlockAddModuleSheet(
                isAdding: model.isAdding,
                refusal: model.addRefusal,
                add: { input in
                    Task { if await model.add(input) { dismiss() } }
                },
                cancel: {
                    model.addRefusal = nil
                    dismiss()
                },
                edited: { model.addRefusal = nil }
            )
        }
        .onAppear { AdBlockModuleTextPlatform.installIfNeeded() }
        .task {
            model.locale = locale
             
             
            model.sceneIsActive = scenePhase == .active
            await model.reload()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollInterval)
                 
                 
                guard !Task.isCancelled, model.sceneIsActive else { continue }
                await model.refreshRuntime()
            }
        }
        .onChange(of: scenePhase) { phase in
            model.sceneIsActive = phase == .active
            guard phase == .active else { return }
            Task { await model.reload() }
        }
        .onChange(of: locale) { newLocale in
            model.locale = newLocale
            Task { await model.reload() }
        }
    }
}
#endif
