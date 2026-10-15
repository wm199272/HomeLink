import SwiftUI

struct DeviceDetailView: View {
    @Environment(AppModel.self) private var model
    var deviceID: String
    @State private var spec: MiotSpec?
    @State private var values: [String: JSONScalar] = [:]
    @State private var traits: [HKTrait] = []
    @State private var drafts: [String: Double] = [:]
    @State private var isLoading = false
    @State private var message: String?
    @State private var greePower = false
    @State private var greeMode = 0
    @State private var greeTemp = 26.0
    @State private var greeFan = 0
    @State private var greeReady = false
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
                controls(for: device)
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
            } else if let spec {
                ForEach(spec.services.filter(\.showsInUI)) { service in
                    let properties = service.properties.filter(\.visible)
                    let actions = service.actions.filter(\.canRunWithoutInput)
                    if !properties.isEmpty || !actions.isEmpty {
                        Section(MiotNaming.title(type: service.type, fallback: service.description)) {
                            ForEach(properties) { property in
                                propertyRow(device: device, service: service, property: property)
                            }
                            ForEach(actions) { action in
                                Button(MiotNaming.title(type: action.type, fallback: action.description)) {
                                    Task {
                                        await run {
                                            try await model.runAction(device: device, siid: service.iid, aiid: action.iid)
                                            message = "已执行"
                                        }
                                    }
                                }
                                .disabled(!device.online)
                            }
                        }
                    }
                }
            } else if device.platform == .gree {
                greeControls(device)
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
                LabeledContent("平台", value: device.platform.title)
                if !device.model.isEmpty {
                    LabeledContent("型号", value: device.model)
                }
                LabeledContent("设备 ID", value: device.did)
                if let ip = device.localIP, !ip.isEmpty {
                    LabeledContent("局域网地址", value: ip)
                }
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
    private func greeControls(_ device: IoTDevice) -> some View {
        Section("空调") {
            if !greeReady {
                Text(isLoading ? "正在读取空调" : "暂时没有读到空调状态，仍然可以在下面调节。")
                    .foregroundStyle(.secondary)
            }
            Toggle("开关", isOn: Binding(
                get: { greePower },
                set: { newValue in
                    let old = greePower
                    greePower = newValue
                    Task {
                        await run({
                            try await model.writeGree(device, power: newValue, mode: nil, temperature: nil, fan: nil)
                        }, rollback: { greePower = old })
                    }
                }
            ))
            .disabled(!device.online)
            Picker("模式", selection: Binding(
                get: { greeMode },
                set: { newValue in
                    let old = greeMode
                    greeMode = newValue
                    Task {
                        await run({
                            try await model.writeGree(device, power: nil, mode: newValue, temperature: nil, fan: nil)
                        }, rollback: { greeMode = old })
                    }
                }
            )) {
                Text("自动").tag(0)
                Text("制冷").tag(1)
                Text("除湿").tag(2)
                Text("送风").tag(3)
                Text("制热").tag(4)
            }
            .disabled(!device.online)
            VStack(alignment: .leading) {
                HStack {
                    Text("温度")
                    Spacer()
                    Text("\(Int(greeTemp.rounded()))°C")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $greeTemp, in: 16...30, step: 1, onEditingChanged: { editing in
                    guard !editing else { return }
                    let target = Int(greeTemp.rounded())
                    Task {
                        await run {
                            try await model.writeGree(device, power: nil, mode: nil, temperature: target, fan: nil)
                        }
                    }
                })
                .disabled(!device.online)
            }
            Picker("风速", selection: Binding(
                get: { greeFan },
                set: { newValue in
                    let old = greeFan
                    greeFan = newValue
                    Task {
                        await run({
                            try await model.writeGree(device, power: nil, mode: nil, temperature: nil, fan: newValue)
                        }, rollback: { greeFan = old })
                    }
                }
            )) {
                Text("自动").tag(0)
                Text("低").tag(1)
                Text("中").tag(2)
                Text("高").tag(3)
            }
            .disabled(!device.online)
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

    private func cloudNote(_ platform: PlatformKind) -> String? {
        switch platform {
        case .xiaomi: "开关和调节会发给小米云端，设备需要保持在线。"
        case .gree: "调节会发给格力云端，空调需要保持在线。个别老固件只会在格力+里响应。"
        case .qihoo: "清扫指令会发给 360 云端，设备需要保持在线。"
        case .deye: "调节会发给德业云端，设备需要保持在线。"
        case .midea: "开关会发给美的美居云端，设备需要保持在线。"
        case .broad: "设备列表来自远大空气管家。各机型的开关还没有统一的公开指令。"
        case .haier: "在线状态来自海尔智家。各机型的细项控制走设备影子，这一版先同步设备。"
        case .mai: "记录仪列表来自 70 迈账号。远程视频走记录仪自己的点对点通道。"
        case .jbot: "开始和停止通过蓝牙直接发给身边的发球机。"
        default: nil
        }
    }

    @ViewBuilder
    private func propertyRow(device: IoTDevice, service: MiotService, property: MiotProperty) -> some View {
        let key = "\(service.iid).\(property.iid)"
        let title = MiotNaming.title(type: property.type, fallback: property.description)
        let value = values[key]

        if property.format == "bool", property.canWrite {
            Toggle(title, isOn: Binding(
                get: { boolValue(value) },
                set: { newValue in
                    let old = values[key]
                    values[key] = .bool(newValue)
Task {
                    await run({
                        try await model.setProperty(device: device, siid: service.iid, piid: property.iid, value: .bool(newValue))
                    }, rollback: {
                        values[key] = old
                    })
                }
                }
            ))
            .disabled(!device.online)
        } else if property.canWrite, let options = property.valueList, !options.isEmpty {
            Picker(title, selection: Binding(
                get: { value ?? options[0].value },
                set: { newValue in
                    let old = values[key]
                    values[key] = newValue
Task {
                    await run({
                        try await model.setProperty(device: device, siid: service.iid, piid: property.iid, value: newValue)
                    }, rollback: {
                        values[key] = old
                    })
                }
                }
            )) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(MiotNaming.optionTitle(option.description)).tag(option.value)
                }
            }
            .disabled(!device.online)
        } else if property.canWrite, let range = sliderRange(property) {
            VStack(alignment: .leading) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(sliderText(drafts[key] ?? range.lowerBound, unit: property.unit))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { drafts[key] ?? numeric(value) ?? range.lowerBound },
                        set: { drafts[key] = $0 }
                    ),
                    in: range,
                    step: sliderStep(property),
                    onEditingChanged: { editing in
                        guard !editing else { return }
                        let number = drafts[key] ?? numeric(value) ?? range.lowerBound
                        let scalar = scalarValue(number, format: property.format)
                        let old = values[key]
                        values[key] = scalar
                        Task {
                            await run({
                                try await model.setProperty(device: device, siid: service.iid, piid: property.iid, value: scalar)
                            }, rollback: {
                                values[key] = old
                            })
                        }
                    }
                )
                .disabled(!device.online)
            }
        } else {
            LabeledContent(title) {
                Text(readOnlyText(value, unit: property.unit))
                    .foregroundStyle(.secondary)
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
        if device.platform == .gree {
            do {
                let climate = try await model.readGree(device)
                greePower = climate.power
                greeMode = climate.mode
                greeTemp = Double(min(30, max(16, climate.temperature)))
                greeFan = climate.fan
                greeReady = true
            } catch {
                message = humanize(error)
            }
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
        if device.platform == .qihoo { return }
        guard device.platform == .xiaomi, device.specType != nil else { return }
        do {
            let loaded = try await model.spec(for: device)
            spec = loaded
            var refs: [(siid: Int, piid: Int)] = []
            for service in loaded.services where service.showsInUI {
                for property in service.properties where property.visible && property.canRead {
                    refs.append((service.iid, property.iid))
                }
            }
            let readings = try await model.readProperties(device: device, refs: refs)
            var next: [String: JSONScalar] = [:]
            for reading in readings {
                guard reading.code == 0 || reading.code == 1, let value = reading.value else { continue }
                next["\(reading.siid).\(reading.piid)"] = value
            }
            values = next
        } catch {
            message = humanize(error)
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

    private func boolValue(_ value: JSONScalar?) -> Bool {
        switch value {
        case let .bool(on): on
        case let .int(number): number != 0
        default: false
        }
    }

    private func numeric(_ value: JSONScalar?) -> Double? {
        switch value {
        case let .int(number): Double(number)
        case let .double(number): number
        case let .bool(on): on ? 1 : 0
        default: nil
        }
    }

    private func sliderRange(_ property: MiotProperty) -> ClosedRange<Double>? {
        guard let raw = property.valueRange, raw.count >= 2, raw[0] < raw[1] else { return nil }
        return raw[0]...raw[1]
    }

    private func sliderStep(_ property: MiotProperty) -> Double {
        let step = property.valueRange?.dropFirst(2).first ?? 1
        if step <= 0 { return property.format == "float" ? 0.1 : 1 }
        return step
    }

    private func scalarValue(_ number: Double, format: String) -> JSONScalar {
        if format == "float" { return .double(number) }
        return .int(Int(number.rounded()))
    }

    private func sliderText(_ number: Double, unit: String?) -> String {
        let body = number.rounded() == number ? String(Int(number)) : String(format: "%.1f", number)
        return body + MiotNaming.unitSuffix(unit)
    }

    private func readOnlyText(_ value: JSONScalar?, unit: String?) -> String {
        guard let value else { return "—" }
        return value.displayText + MiotNaming.unitSuffix(unit)
    }
}
