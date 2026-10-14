import SwiftUI

@main
struct HomeLinkApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Color.moss)
        }
    }
}
