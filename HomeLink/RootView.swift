import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.accounts.isEmpty {
                NavigationStack {
                    PlatformSelectView(mode: .onboarding)
                }
            } else {
                MainView()
            }
        }
        .background(Color.paper)
        .task {
            await model.bootstrap()
        }
    }
}

struct MainView: View {
    var body: some View {
        TabView {
            NavigationStack {
                DeviceHomeView()
            }
            .tabItem {
                Label("设备", systemImage: "house.fill")
            }

            NavigationStack {
                PlatformManageView()
            }
            .tabItem {
                Label("平台", systemImage: "square.grid.2x2.fill")
            }
        }
    }
}
