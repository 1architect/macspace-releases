import MacSpaceApp
import SwiftUI

@main
struct MacSpaceMain: App {
    @StateObject private var host = ModuleHost()

    var body: some Scene {
        WindowGroup("MACSPACE") {
            MainView(host: host)
        }
        .windowResizability(.contentMinSize)
    }
}
