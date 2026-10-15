import SwiftUI

/// 米家设备详情页，照着米家 App 的样子做。
///
/// 上面一张按模式换色的大卡片：拨盘转设定温度、室温湿度读数、底下一个大圆开关。
/// 往下依次是模式、风速的芯片，摆风和其余开关的瓦片，再下面是精细调节、实时数据、
/// 快捷功能，最后是设备信息。
///
/// 功能全部从米家的设备描述（MIoT spec）里认出来，认不出来的属性按类型落到
/// 开关瓦片、滑杆、选项和实时数据里，所以什么设备都能用同一套界面。
struct MiotControlView: View {
    @Environment(AppModel.self) private var model
    var device: IoTDevice

    @State private var roles = MiotRoles()
    @State private var values: [String: JSONScalar] = [:]
    @State private var drafts: [String: Double] = [:]
    @State private var isLoading = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Color.clay)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.clay.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                hero
                modeSection
                fanSection
                swingSection
                toggleSection
                sliderSection
                chooserSection
                readingSection
                actionSection
                SectionCard("信息", symbol: "info.circle") {
                    DeviceInfoContent(device: device)
                }
                if let note = cloudNote(device.platform) {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 30)
        }
        .background(Color.paper)
        .task(id: device.id) { await load() }
    }

    // MARK: - 大卡片

    private var hero: some View {
        HeroCard(tint: accent, dimmed: dimmed) {
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    Text(statusLine)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer(minLength: 0)
                    if isLoading {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }
                if let target = roles.target, let range = target.property.sliderBounds {
                    HStack(spacing: 8) {
                        StepButton(symbol: "minus", enabled: controlsEnabled) {
                            step(target, by: -target.property.sliderStep)
                        }
                        DialControl(
                            value: Binding(
                                get: { draft(target, range: range) },
                                set: { drafts[target.id] = $0 }
                            ),
                            range: range,
                            step: target.property.sliderStep,
                            headline: dialText(target, range: range),
                            caption: "设定温度",
                            accent: accent,
                            enabled: controlsEnabled,
                            onCommit: { commit(target) }
                        )
                        StepButton(symbol: "plus", enabled: controlsEnabled) {
                            step(target, by: target.property.sliderStep)
                        }
                    }
                } else if let brightness = roles.brightness, let range = brightness.property.sliderBounds {
                    VStack(spacing: 14) {
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.white.opacity(0.9))
                        Slider(
                            value: Binding(
                                get: { draft(brightness, range: range) },
                                set: { drafts[brightness.id] = $0 }
                            ),
                            in: range,
                            step: brightness.property.sliderStep,
                            onEditingChanged: { editing in
                                if !editing { commit(brightness) }
                            }
                        )
                        .tint(.white)
                        Text(draftText(brightness, range: range))
                            .font(.title3.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    .padding(.vertical, 4)
                } else {
                    Image(systemName: device.category.symbol)
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(height: 130)
                }
                HStack(spacing: 10) {
                    ForEach(Array(heroReadouts.enumerated()), id: \.offset) { _, item in
                        HeroReadout(title: item.title, value: item.value)
                    }
                }
                if roles.power != nil {
                    PowerButton(on: isOn, tint: accent, enabled: !isLoading && device.online) {
                        togglePower()
                    }
                }
            }
        }
    }

    // MARK: - 各组

    @ViewBuilder
    private var modeSection: some View {
        if let mode = roles.mode, let options = mode.property.valueList, !options.isEmpty {
            SectionCard("模式", symbol: "dial.medium") {
                WrapLayout(spacing: 10, lineSpacing: 10) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        ChoiceChip(
                            title: MiotNaming.optionTitle(option.description),
                            selected: values[mode.id] == option.value
                        ) {
                            write(mode, value: option.value)
                        }
                    }
                }
            }
            .controlGroup(controlsEnabled)
        }
    }

    @ViewBuilder
    private var fanSection: some View {
        if let fan = roles.fan {
            if let options = fan.property.valueList, !options.isEmpty {
                SectionCard("风速", symbol: "fan.fill") {
                    WrapLayout(spacing: 10, lineSpacing: 10) {
                        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                            ChoiceChip(
                                title: MiotNaming.optionTitle(option.description),
                                selected: values[fan.id] == option.value
                            ) {
                                write(fan, value: option.value)
                            }
                        }
                    }
                }
                .controlGroup(controlsEnabled)
            } else if fan.property.sliderBounds != nil {
                SectionCard("风速", symbol: "fan.fill") {
                    sliderRow(fan)
                }
                .controlGroup(controlsEnabled)
            }
        }
    }

    @ViewBuilder
    private var swingSection: some View {
        let swings = [roles.verticalSwing, roles.horizontalSwing].compactMap { $0 }
        if !swings.isEmpty {
            SectionCard("摆风", symbol: "wind") {
                TileGrid {
                    ForEach(swings) { ref in
                        boolTile(ref)
                    }
                }
            }
            .controlGroup(controlsEnabled)
        }
    }

    @ViewBuilder
    private var toggleSection: some View {
        if !roles.toggles.isEmpty {
            SectionCard("开关", symbol: "switch.2") {
                TileGrid {
                    ForEach(roles.toggles) { ref in
                        boolTile(ref)
                    }
                }
            }
            .controlGroup(controlsEnabled)
        }
    }

    @ViewBuilder
    private var sliderSection: some View {
        if !roles.sliders.isEmpty {
            SectionCard("精细调节", symbol: "slider.horizontal.3") {
                VStack(spacing: 18) {
                    ForEach(roles.sliders) { ref in
                        sliderRow(ref)
                    }
                }
            }
            .controlGroup(controlsEnabled)
        }
    }

    @ViewBuilder
    private var chooserSection: some View {
        if !roles.choosers.isEmpty {
            SectionCard("选项", symbol: "list.bullet") {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(roles.choosers) { ref in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(title(of: ref))
                                .font(.subheadline)
                            WrapLayout(spacing: 10, lineSpacing: 10) {
                                ForEach(Array((ref.property.valueList ?? []).enumerated()), id: \.offset) { _, option in
                                    ChoiceChip(
                                        title: MiotNaming.optionTitle(option.description),
                                        selected: values[ref.id] == option.value
                                    ) {
                                        write(ref, value: option.value)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .controlGroup(controlsEnabled)
        }
    }

    @ViewBuilder
    private var readingSection: some View {
        let readings = roles.readings.filter { values[$0.id] != nil }
        if !readings.isEmpty {
            SectionCard("实时数据", symbol: "waveform.path.ecg") {
                TileGrid {
                    ForEach(readings) { ref in
                        ReadoutTile(
                            title: title(of: ref),
                            symbol: ControlIcon.symbol(for: ref.name),
                            value: readoutText(ref)
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        if !roles.actions.isEmpty {
            SectionCard("快捷功能", symbol: "bolt.fill") {
                WrapLayout(spacing: 10, lineSpacing: 10) {
                    ForEach(roles.actions) { ref in
                        Button {
                            runAction(ref)
                        } label: {
                            Text(MiotNaming.title(type: ref.action.type, fallback: ref.action.description))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.moss)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .background(Color.moss.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - 瓦片与滑杆

    private func boolTile(_ ref: MiotPropertyRef) -> some View {
        let on = boolValue(values[ref.id])
        return ControlTile(
            title: title(of: ref),
            symbol: ControlIcon.symbol(for: ref.name),
            value: on ? "开" : "关",
            highlighted: on,
            enabled: controlsEnabled
        ) {
            write(ref, value: .bool(!on))
        }
    }

    @ViewBuilder
    private func sliderRow(_ ref: MiotPropertyRef, overriding: ClosedRange<Double>? = nil) -> some View {
        if let range = overriding ?? ref.property.sliderBounds {
            SliderRow(
                title: title(of: ref),
                symbol: ControlIcon.symbol(for: ref.name),
                text: draftText(ref, range: range),
                value: Binding(
                    get: { draft(ref, range: range) },
                    set: { drafts[ref.id] = $0 }
                ),
                range: range,
                step: ref.property.sliderStep,
                enabled: controlsEnabled,
                onCommit: { commit(ref) }
            )
        }
    }

    // MARK: - 读写

    private func load() async {
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            let spec = try await model.spec(for: device)
            roles = MiotRoles(spec: spec)
            var refs: [(siid: Int, piid: Int)] = []
            for ref in spec.uiProperties where ref.property.visible && ref.property.canRead {
                refs.append((ref.service.iid, ref.property.iid))
            }
            let readings = try await model.readProperties(device: device, refs: refs)
            var next: [String: JSONScalar] = [:]
            for reading in readings where reading.code == 0 || reading.code == 1 {
                guard let value = reading.value else { continue }
                next["\(reading.siid).\(reading.piid)"] = value
            }
            values = next
            drafts = [:]
        } catch {
            message = humanize(error)
        }
    }

    private func write(_ ref: MiotPropertyRef, value: JSONScalar) {
        let previous = values[ref.id]
        values[ref.id] = value
        Task {
            await run {
                try await model.setProperty(device: device, siid: ref.service.iid, piid: ref.property.iid, value: value)
            } rollback: {
                values[ref.id] = previous
            }
        }
    }

    private func commit(_ ref: MiotPropertyRef) {
        guard let range = ref.property.sliderBounds else { return }
        let number = draft(ref, range: range)
        drafts[ref.id] = nil
        let scalar: JSONScalar = ref.property.format == "float" ? .double(number) : .int(Int(number.rounded()))
        write(ref, value: scalar)
    }

    private func step(_ ref: MiotPropertyRef, by delta: Double) {
        guard let range = ref.property.sliderBounds else { return }
        drafts[ref.id] = min(max(draft(ref, range: range) + delta, range.lowerBound), range.upperBound)
        commit(ref)
    }

    private func togglePower() {
        guard let power = roles.power else { return }
        write(power, value: .bool(!isOn))
    }

    private func runAction(_ ref: MiotActionRef) {
        Task {
            await run {
                try await model.runAction(device: device, siid: ref.service.iid, aiid: ref.action.iid)
            }
            if message == nil { message = "已执行" }
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

    // MARK: - 展示

    private var accent: Color {
        if let mode = roles.mode, let value = values[mode.id],
           let option = mode.property.valueList?.first(where: { $0.value == value }) {
            return ControlPalette.accent(for: option.description)
        }
        return roles.target == nil ? Color.moss : ControlPalette.cool
    }

    private var statusLine: String {
        var parts: [String] = []
        if roles.power != nil {
            parts.append(isOn ? "已开启" : "已关闭")
        }
        if let mode = roles.mode, let value = values[mode.id],
           let option = mode.property.valueList?.first(where: { $0.value == value }) {
            parts.append(MiotNaming.optionTitle(option.description))
        }
        if let fan = roles.fan, let value = values[fan.id],
           let option = fan.property.valueList?.first(where: { $0.value == value }) {
            parts.append("风速" + MiotNaming.optionTitle(option.description))
        }
        return parts.isEmpty ? device.homeName : parts.joined(separator: " · ")
    }

    /// 还没读到开关状态时先别把界面锁死，不然一进页面全是灰的。
    private var isOn: Bool {
        guard let power = roles.power, let value = values[power.id] else { return true }
        return boolValue(value)
    }

    private var isPowerKnown: Bool {
        guard let power = roles.power else { return false }
        return values[power.id] != nil
    }

    private var dimmed: Bool { isPowerKnown && !isOn }

    private var controlsEnabled: Bool { !isLoading && device.online && isOn }

    /// 大卡片底下那两格读数。优先室温湿度；没有的话退到前两个能读到的数据，
    /// 免得净化器、传感器这类设备的卡片空着。
    private var heroReadouts: [(title: String, value: String)] {
        var items: [(title: String, value: String)] = []
        if let ambient = roles.ambient, values[ambient.id] != nil {
            items.append(("室温", readoutText(ambient)))
        }
        if let humidity = roles.humidity, values[humidity.id] != nil {
            items.append(("湿度", readoutText(humidity)))
        }
        if items.isEmpty {
            for ref in roles.readings where values[ref.id] != nil {
                items.append((title(of: ref), readoutText(ref)))
                if items.count == 2 { break }
            }
        }
        return Array(items.prefix(2))
    }

    private func title(of ref: MiotPropertyRef) -> String {
        MiotNaming.title(type: ref.property.type, fallback: ref.property.description)
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

    private func draft(_ ref: MiotPropertyRef, range: ClosedRange<Double>) -> Double {
        if let draft = drafts[ref.id] { return draft }
        if let number = numeric(values[ref.id]) {
            return min(max(number, range.lowerBound), range.upperBound)
        }
        return range.lowerBound
    }

    private func draftText(_ ref: MiotPropertyRef, range: ClosedRange<Double>) -> String {
        numberText(draft(ref, range: range)) + MiotNaming.unitSuffix(ref.property.unit)
    }

    private func dialText(_ ref: MiotPropertyRef, range: ClosedRange<Double>) -> String {
        let text = numberText(draft(ref, range: range))
        if ref.property.unit == "celsius" { return text + "°" }
        return text + MiotNaming.unitSuffix(ref.property.unit)
    }

    private func numberText(_ number: Double) -> String {
        number.rounded() == number ? String(Int(number)) : String(format: "%.1f", number)
    }

    private func readoutText(_ ref: MiotPropertyRef) -> String {
        guard let value = values[ref.id] else { return "—" }
        if let option = ref.property.valueList?.first(where: { $0.value == value }) {
            return MiotNaming.optionTitle(option.description)
        }
        return value.displayText + MiotNaming.unitSuffix(ref.property.unit)
    }
}

/// 从设备描述里认出来的角色。
///
/// 米家的界面只关心这十来个常用功能（开关、模式、设定温度、室温湿度、风速、摆风），
/// 其余的按「开关 / 滑杆 / 选项 / 只读」分桶，一个都不丢。
struct MiotRoles {
    var power: MiotPropertyRef?
    var mode: MiotPropertyRef?
    var target: MiotPropertyRef?
    var ambient: MiotPropertyRef?
    var humidity: MiotPropertyRef?
    var fan: MiotPropertyRef?
    var verticalSwing: MiotPropertyRef?
    var horizontalSwing: MiotPropertyRef?
    var brightness: MiotPropertyRef?
    var toggles: [MiotPropertyRef] = []
    var sliders: [MiotPropertyRef] = []
    var choosers: [MiotPropertyRef] = []
    var readings: [MiotPropertyRef] = []
    var actions: [MiotActionRef] = []

    init() {}

    init(spec: MiotSpec) {
        let props = spec.uiProperties

        func pick(
            _ candidates: [String],
            services: [String] = [],
            check: (MiotProperty) -> Bool = { _ in true }
        ) -> MiotPropertyRef? {
            for candidate in candidates {
                if let hit = props.first(where: { ref in
                    ref.name == candidate
                        && (services.isEmpty || services.contains(ref.serviceName))
                        && check(ref.property)
                }) {
                    return hit
                }
            }
            return nil
        }

        let climates = ["air-conditioner", "heater", "water-heater", "thermostat", "air-condition-outlet", "air-fresh"]

        power = pick(["on", "power", "switch"], check: { $0.format == "bool" && $0.canWrite })
        mode = pick(["mode"], check: { $0.canWrite && !($0.valueList ?? []).isEmpty })
        target = pick(
            ["target-temperature", "target-temp", "set-temperature", "temperature"],
            services: climates,
            check: { $0.canWrite && $0.sliderBounds != nil }
        )
        ambient = pick(["temperature"], services: ["environment"], check: { $0.canRead })
            ?? pick(["temperature"], check: { $0.canRead && $0.sliderBounds != nil && $0.canWrite == false })
        humidity = pick(["relative-humidity", "humidity"], check: { $0.canRead })
        fan = pick(
            ["fan-level", "fan-speed", "wind-speed", "speed-level"],
            check: { $0.canWrite && ($0.sliderBounds != nil || !($0.valueList ?? []).isEmpty) }
        )
        verticalSwing = pick(
            ["vertical-swing", "up-down-swing", "vertical-swing-included-angle"],
            check: { $0.canWrite && ($0.format == "bool" || !($0.valueList ?? []).isEmpty) }
        )
        horizontalSwing = pick(
            ["horizontal-swing", "left-right-swing", "horizontal-swing-included-angle"],
            check: { $0.canWrite && ($0.format == "bool" || !($0.valueList ?? []).isEmpty) }
        )
        brightness = pick(["brightness"], check: { $0.canWrite && $0.sliderBounds != nil })

        let claimed = Set(
            [power, mode, target, ambient, humidity, fan, verticalSwing, horizontalSwing, brightness]
                .compactMap { $0?.id }
        )
        let noisy = ["fault", "abnormal-condition"]

        for ref in props where ref.property.visible && !claimed.contains(ref.id) {
            let property = ref.property
            if property.canWrite, !noisy.contains(ref.name) {
                if property.format == "bool" {
                    toggles.append(ref)
                } else if !(property.valueList ?? []).isEmpty {
                    choosers.append(ref)
                } else if property.sliderBounds != nil {
                    sliders.append(ref)
                }
                continue
            }
            if property.canRead {
                readings.append(ref)
            }
        }
        actions = spec.uiActions.filter { $0.action.canRunWithoutInput }
    }
}
