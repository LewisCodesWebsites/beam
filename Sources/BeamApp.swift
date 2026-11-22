import SwiftUI

@main
struct BeamApp: App {
    @StateObject private var caster = Caster()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(caster)
                .onOpenURL { caster.handleIncoming($0) }
        }
    }
}
