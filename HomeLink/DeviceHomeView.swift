import SwiftUI
import UIKit

struct DeviceHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        Group {
            if let home = model.selectedHome {
                deviceList(home)
            } else if model.isRefreshing {
                ProgressView("正在同步设备")
            } else {
                ContentUnavailableView {
                    Label("还没有设备", systemImage: "house")
                } description: {
                    Text("下拉可以重新同步。登录过期或选错地区时，到「平台」里重新关联。")
                }
            }
        }
        .background(Color.paper)
        .navigationTitle(model.selectedHome?.name ?? "设备")
        .navigationDestination(for: DeviceRoute.self) { route in
            DeviceDetailView(deviceID: route.id)
        }
        .searchable(text: $query, prompt: "搜索设备")
        .refreshable {
            await model.refresh()
        }
        .toolbar {
            if model.homes.count > 1 {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(model.homes) { home in
                            Button {
                                model.selectedHomeID = home.id
                            } label: {
                                if home.id == model.selectedHome?.id {
                                    Label(homeLabel(home), systemImage: "checkmark")
                                } else {
                                    Text(homeLabel(home))
                                }
                            }
                        }
                    } label: {
                        Label("家庭", systemImage: "house")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshing)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = model.lastError {
                HStack(alignment: .top, spacing: 12) {
                    Text(error)
                        .font(.footnote)
                    Spacer(minLength: 8)
                    Button("关闭") { model.lastError = nil }
                        .font(.footnote)
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    private func deviceList(_ home: IoTHome) -> some View {
        let rooms = filteredRooms(in: home)
        return List {
            if rooms.allSatisfy({ $0.devices.isEmpty }) {
                ContentUnavailableView("没有匹配的设备", systemImage: "magnifyingglass")
                    .listRowBackground(Color.clear)
            }
            ForEach(rooms) { room in
                Section(room.name) {
                    ForEach(room.devices) { device in
                        DeviceRow(device: device)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.paper)
    }

    private func filteredRooms(in home: IoTHome) -> [IoTRoom] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return home.rooms.filter { !$0.devices.isEmpty } }
        return home.rooms.compactMap { room in
            let devices = room.devices.filter { device in
                device.name.localizedCaseInsensitiveContains(keyword)
                    || device.model.localizedCaseInsensitiveContains(keyword)
                    || room.name.localizedCaseInsensitiveContains(keyword)
            }
            guard !devices.isEmpty else { return nil }
            var copy = room
            copy.devices = devices
            return copy
        }
    }

    private func homeLabel(_ home: IoTHome) -> String {
        let platform = home.platform == .homekit ? "家庭" : home.platform.title
        return "\(home.name) · \(platform)"
    }
}

private struct DeviceRow: View {
    @Environment(AppModel.self) private var model
    var device: IoTDevice

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: DeviceRoute(id: device.id)) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.moss.opacity(device.online ? 0.14 : 0.08))
                        Image(systemName: device.category.symbol)
                            .foregroundStyle(device.online ? Color.moss : .secondary)
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .foregroundStyle(.primary)
                        Text(device.online ? device.roomName : "\(device.roomName) · 离线")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if device.canToggle {
                Toggle("开关", isOn: Binding(
                    get: { device.power == .on },
                    set: { _ in
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        Task { await model.toggle(device) }
                    }
                ))
                .labelsHidden()
                .disabled(!device.online)
            }
        }
        .opacity(device.online ? 1 : 0.55)
    }
}
