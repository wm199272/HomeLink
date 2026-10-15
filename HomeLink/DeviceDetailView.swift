import SwiftUI

/// 设备详情页的入口。
///
/// 米家和格力各自有专门的界面（照着米家 App、格力+ App 做）：
/// 米家走 `MiotControlView`（按设备描述自动摆功能），格力走 `GreeControlView`。
/// 其余平台沿用原来的列表样式。
struct DeviceDetailView: View {
    @Environment(AppModel.self) private var model
    var deviceID: String
    @State private var traits: [HKTrait] = []
    @State private var isLoading = false
    @State private var message: String?
    @State private var deyePower = false
    @State private var deyeMode = 0
    @State private var deyeHumidity = 60.0
    @State private var deyeFan = 1
    @State private var deyeAmbient: Int?
    @State private var deyeReady = false

    private var device: IoTDevice? {
        model.device(id: deviceID)
    }

    var body: some View {
        Group {
            if let device {
                if device.platform == .xiaomi, device.specType != nil {
                    MiotControlView(device: device)
                } else if device.platform == .gree {
                    GreeControlView(device: device)
                } else {
                    controls(for: device)
                }
            } else {
                ContentUnavailableView("设备不在列表里", systemImage: "questionmark.circle")
            }
        }
        .background(Color.paper)
        .navigationTitle(device?.name ?? "设备")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: deviceID) {
            await load()
        }
    }

    @ViewBuilder
    private func controls(for device: IoTDevice) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: device.category.symbol)
                            .font(.title2)
                            .foregroundStyle(Color.moss)
                            .frame(width: 44, height: 44)
                            .background(Color.moss.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.homeName)
                            Text(device.online ? "在线" : "离线")
                                .font(.subheadline)
                                .foregroundStyle(device.online ? Color.moss : .secondary)
                        }
                    }
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if device.platform == .homekit {
                Section("控制") {
                    if traits.isEmpty && !isLoading {
                        Text("没有可读的控制项")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(traits) { trait in
                        if trait.isToggle {
                            Toggle(trait.title, isOn: Binding(
                                get: { trait.isOn },
                                set: { newValue in
                                    updateTrait(trait.id, on: newValue)
                                    Task {
                                        await run {
                                            try await model.setHomeKitBool(
                                                device: device,
                                                characteristicID: trait.characteristicID,
                                                on: newValue
                                            )
                                        }
                                    }
                                }
                            ))
                        } else {
                            LabeledContent(trait.title, value: trait.text)
                        }
                    }
                }
            } else if device.platform == .qihoo {
                qihooControls(device)
            } else if device.platform == .deye {
                deyeControls(device)
            } else if device.platform == .midea {
                mideaControls(device)
            } else if device.platform == .jbot {
                JbotControlSection(peripheralID: device.did)
            } else if device.platform == .broad || device.platform == .haier || device.platform == .mai {
                Section("设备") {
                    Text(listOnlyNote(device.platform))
                        .foregroundStyle(.secondary)
                }
            } else if isLoading {
                Section {
                    ProgressView("正在读取功能")
                }
            } else if device.platform == .xiaomi, device.specType == nil {
                Section {
                    Text("米家没有公开这个设备的功能描述，目前只能查看在线状态。")
                        .foregroundStyle(.secondary)
                }
            }

            Section("信息") {
                DeviceInfoContent(device: device)
            }
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            if let note = cloudNote(device.platform) {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private func qihooControls(_ device: IoTDevice) -> some View {
        Section("控制") {
            if device.specType == "vacuum" {
                Button("开始清扫") { Task { await run { try await model.sendVacuum(device, command: .start); message = "已开始清扫" } } }
                    .disabled(!device.online)
                Button("暂停") { Task { await run { try await model.sendVacuum(device, command: .pause); message = "已暂停" } } }
                    .disabled(!device.online)
                Button("回充") { Task { await run { try await model.sendVacuum(device, command: .dock); message = "正在回充" } } }
                    .disabled(!device.online)
            } else {
                Text("这台设备已经从 360 智慧生活同步过来。家联目前能为扫地机器人发送清扫、暂停和回充。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func mideaControls(_ device: IoTDevice) -> some View {
        Section("设备") {
            if device.power == .on || device.power == .off {
                Toggle("开关", isOn: Binding(
                    get: { device.power == .on },
                    set: { newValue in
                        Task { await run { try await model.setMideaPower(device, on: newValue) } }
                    }
                ))
                .disabled(!device.online)
            } else {
                Text("这台设备已经从美的美居同步过来。家联没有读到统一的开关字段，所以这里先显示在线状态。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func listOnlyNote(_ platform: PlatformKind) -> String {
        switch platform {
        case .broad:
            "这台设备已经从远大空气管家同步过来。目前可以查看它是否在线。"
        case .haier:
            "这台设备已经从海尔智家同步过来。目前可以查看它是否在线。"
        case .mai:
            "这台记录仪已经在 70 迈账号下。家联同步的是设备列表，远程视频不在这里播放。"
        default:
            "这台设备已经同步过来。"
        }
    }

    @ViewBuilder
    private func deyeControls(_ device: IoTDevice) -> some View {
        Section("设备") {
            if device.specType != "fog" {
                Text("这台设备使用旧协议，家联目前只能查看它是否在线。新协议的除湿机可以在这里调节。")
                    .foregroundStyle(.secondary)
            } else {
                if !deyeReady {
                    Text(isLoading ? "正在读取除湿机" : "暂时没有读到状态，仍然可以在下面调节。")
                        .foregroundStyle(.secondary)
                }
                if let deyeAmbient {
                    LabeledContent("环境湿度", value: "\(deyeAmbient)%")
                }
                Toggle("开关", isOn: Binding(
                    get: { deyePower },
                    set: { newValue in
                        let old = deyePower
                        deyePower = newValue
                        Task {
                            await run({
                                try await model.writeDeye(device, power: newValue, mode: nil, humidity: nil, fan: nil)
                            }, rollback: { deyePower = old })
                        }
                    }
                ))
                .disabled(!device.online)
                Picker("模式", selection: Binding(
                    get: { deyeMode },
                    set: { newValue in
                        let old = deyeMode
                        deyeMode = newValue
                        Task {
                            await run({
                                try await model.writeDeye(device, power: nil, mode: newValue, humidity: nil, fan: nil)
                            }, rollback: { deyeMode = old })
                        }
                    }
                )) {
                    Text("手动").tag(0)
                    Text("干衣").tag(1)
                    Text("净化").tag(2)
                    Text("自动").tag(3)
                    Text("强力").tag(4)
                    Text("睡眠").tag(6)
                }
                .disabled(!device.online)
                VStack(alignment: .leading) {
                    HStack {
                        Text("目标湿度")
                        Spacer()
                        Text("\(Int(deyeHumidity.rounded()))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $deyeHumidity, in: 25...80, step: 1, onEditingChanged: { editing in
                        guard !editing else { return }
                        let target = Int(deyeHumidity.rounded())
                        Task {
                            await run {
                                try await model.writeDeye(device, power: nil, mode: nil, humidity: target, fan: nil)
                            }
                        }
                    })
                    .disabled(!device.online)
                }
                Picker("风速", selection: Binding(
                    get: { deyeFan },
                    set: { newValue in
                        let old = deyeFan
                        deyeFan = newValue
                        Task {
                            await run({
                                try await model.writeDeye(device, power: nil, mode: nil, humidity: nil, fan: newValue)
                            }, rollback: { deyeFan = old })
                        }
                    }
                )) {
                    Text("低").tag(1)
                    Text("中").tag(2)
                    Text("高").tag(3)
                    Text("强").tag(4)
                    Text("自动").tag(5)
                }
                .disabled(!device.online)
            }
        }
    }

    private func load() async {
        guard let device else { return }
        isLoading = true
        message = nil
        defer { isLoading = false }
        if device.platform == .homekit {
            traits = await model.homeKitTraits(for: device)
            return
        }
        if device.platform == .deye {
            guard device.specType == "fog" else { return }
            do {
                let climate = try await model.readDeye(device)
                deyePower = climate.power
                deyeMode = climate.mode
                deyeHumidity = Double(min(80, max(25, climate.humidity)))
                deyeFan = climate.fan
                deyeAmbient = climate.ambientHumidity
                deyeReady = true
            } catch {
                message = humanize(error)
            }
            return
        }
    }

    private func run(_ work: () async throws -> Void, rollback: (() -> Void)? = nil) async {
        do {
            try await work()
            message = nil
        } catch {
            rollback?()
            message = humanize(error)
        }
    }

    private func updateTrait(_ id: String, on: Bool) {
        guard let index = traits.firstIndex(where: { $0.id == id }) else { return }
        traits[index].isOn = on
    }
}
