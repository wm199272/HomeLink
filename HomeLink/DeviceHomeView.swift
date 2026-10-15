import SwiftUI
import UIKit

struct DeviceHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selectedPlatform: PlatformKind?

    private var linkedPlatforms: [PlatformKind] {
        let platforms = Set(model.accounts.map(\.platform))
        return PlatformKind.allCases.filter { platforms.contains($0) }.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// 选中「全部」时不该只挑一个家庭出来。
    /// 之前 `activeHome` 无论选没选平台都只返回一个 home，
    /// 所以「全部」实际只显示了第一（或上次选中的）那个家庭的设备。
    private var showingAll: Bool { selectedPlatform == nil }

    private var visibleHomes: [IoTHome] {
        guard let platform = selectedPlatform else { return model.homes }
        return model.homes.filter { $0.platform == platform }
    }

    private var activeHome: IoTHome? {
        if let home = model.selectedHome, visibleHomes.contains(where: { $0.id == home.id }) {
            return home
        }
        return visibleHomes.first
    }

    var body: some View {
        Group {
            if showingAll {
                if model.homes.isEmpty {
                    emptyState
                } else {
                    allDevicesList
                }
            } else if let home = activeHome {
                deviceList(home)
            } else if model.isRefreshing {
                ProgressView("正在同步设备")
            } else {
                emptyState
            }
        }
        .background(Color.paper)
        .navigationTitle(selectedPlatform?.title ?? "全部设备")
        .navigationDestination(for: DeviceRoute.self) { route in
            DeviceDetailView(deviceID: route.id)
        }
        .searchable(text: $query, prompt: "搜索设备")
        .refreshable {
            await model.refresh()
        }
        .safeAreaInset(edge: .top) {
            if !linkedPlatforms.isEmpty {
                platformFilter
            }
        }
        .toolbar {
            if showingAll {
                if model.pinnedDeviceIDs.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                    }
                }
            } else if visibleHomes.count > 1 {
                ToolbarItem(placement: .topBarLeading) {
                    homeMenu
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

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有设备", systemImage: "house")
        } description: {
            Text("下拉可以重新同步。登录过期或选错地区时，到「平台」里重新关联。")
        }
    }

    private var homeMenu: some View {
        Menu {
            ForEach(visibleHomes) { home in
                Button {
                    model.selectedHomeID = home.id
                } label: {
                    if home.id == activeHome?.id {
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

    /// 平台筛选标签。改成自动换行，标签多了也不会被挤到屏幕外。
    private var platformFilter: some View {
        WrapLayout(spacing: 10, lineSpacing: 8) {
            platformChip(nil, title: "全部", symbol: "square.grid.2x2.fill")
            ForEach(linkedPlatforms) { platform in
                platformChip(platform, title: platform.title, symbol: platform.symbol)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func platformChip(_ platform: PlatformKind?, title: String, symbol: String) -> some View {
        let active = selectedPlatform == platform
        return Button {
            selectedPlatform = platform
            if let first = visibleHomes.first { model.selectedHomeID = first.id }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption)
                Text(title)
                    .font(.subheadline.weight(active ? .semibold : .regular))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(active ? Color.paper : Color.moss)
            .background {
                if active {
                    Capsule().fill(Color.moss)
                } else {
                    Capsule().fill(Color.moss.opacity(0.1))
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 全部设备

    /// 搜索过滤后的全部设备，跨账号、跨家庭、跨房间。
    private var filteredDevices: [IoTDevice] {
        let all = visibleHomes.flatMap(\.devices)
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return all }
        return all.filter { device in
            device.name.localizedCaseInsensitiveContains(keyword)
                || device.model.localizedCaseInsensitiveContains(keyword)
                || device.roomName.localizedCaseInsensitiveContains(keyword)
                || device.homeName.localizedCaseInsensitiveContains(keyword)
                || device.platform.title.localizedCaseInsensitiveContains(keyword)
        }
    }

    private var allDevicesList: some View {
        let devices = filteredDevices
        let pinnedSet = Set(model.pinnedDeviceIDs)
        let pinned = model.pinnedDeviceIDs.compactMap { id in
            devices.first { $0.id == id }
        }
        let rooms = groupedRooms(devices.filter { !pinnedSet.contains($0.id) })
        return List {
            if devices.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "还没有设备" : "没有匹配的设备",
                    systemImage: query.isEmpty ? "house" : "magnifyingglass"
                )
                .listRowBackground(Color.clear)
            }
            if !pinned.isEmpty {
                Section {
                    ForEach(pinned) { device in
                        DeviceRow(device: device, showPlatform: true)
                            .swipeActions(edge: .trailing) { pinAction(device) }
                    }
                    .onMove { source, destination in
                        model.movePinned(
                            fromOffsets: source,
                            toOffset: destination,
                            visible: pinned.map(\.id)
                        )
                    }
                } header: {
                    Text("置顶")
                } footer: {
                    Text("点右上角「编辑」可以拖动调整顺序，左滑取消置顶。")
                }
            }
            ForEach(rooms) { room in
                Section(room.name) {
                    ForEach(room.devices) { device in
                        DeviceRow(device: device, showPlatform: true)
                            .swipeActions(edge: .trailing) { pinAction(device) }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.paper)
    }

    /// 把设备按房间合并：不同平台、不同家庭里同名的房间会并到一起，
    /// 顺序沿用家庭和房间原有的顺序，结果稳定不会来回跳。
    private func groupedRooms(_ devices: [IoTDevice]) -> [IoTRoom] {
        var order: [String] = []
        var grouped: [String: [IoTDevice]] = [:]
        for device in devices {
            let key = groupTitle(for: device)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(device)
        }
        return order.map { IoTRoom(id: "all:\($0)", name: $0, devices: grouped[$0] ?? []) }
    }

    /// 有些平台不给房间信息，把设备全塞进一个叫「全部设备」的假房间里。
    /// 合并展示时这类名字会让人误解，换成家庭名。
    private static let placeholderRooms: Set<String> = ["全部设备", "设备", "未分组"]

    private func groupTitle(for device: IoTDevice) -> String {
        let room = device.roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        if room.isEmpty || Self.placeholderRooms.contains(room) {
            return device.homeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "未分组"
                : device.homeName
        }
        return room
    }

    private func pinAction(_ device: IoTDevice) -> some View {
        let pinned = model.isPinned(device.id)
        return Button {
            model.togglePin(device.id)
        } label: {
            Label(pinned ? "取消置顶" : "置顶", systemImage: "pin")
        }
        .tint(pinned ? Color.gray : Color.moss)
    }

    // MARK: 单个平台

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
    /// 「全部」页里设备来自多个平台，标出平台名才分得清是哪台。
    var showPlatform = false

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
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(device.name)
                                .foregroundStyle(.primary)
                            if showPlatform && model.isPinned(device.id) {
                                Image(systemName: "pin.fill")
                                    .font(.caption2)
                                    .foregroundStyle(Color.moss)
                            }
                        }
                        HStack(spacing: 6) {
                            if showPlatform {
                                Text(device.platform.title)
                                    .font(.caption2)
                                    .foregroundStyle(Color.moss)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.moss.opacity(0.12), in: Capsule())
                            }
                            Text(device.online ? device.roomName : "\(device.roomName) · 离线")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
