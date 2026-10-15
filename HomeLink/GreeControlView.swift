import SwiftUI

/// 格力空调详情页，照着格力+ App 的样子做。
///
/// 上面一张按模式换色的大卡片：拨盘转设定温度、室温和模式风速读数、底下一个大圆开关；
/// 往下是模式、风速的芯片，再下面是功能和摆风瓦片。
///
/// 状态查询会把格力协议里那一排常用列一起问一遍，**设备没上报的列不显示**，
/// 所以不会给空调发它不支持的命令。
struct GreeControlView: View {
    @Environment(AppModel.self) private var model
    var device: IoTDevice

    @State private var climate: GreeClimate?
    @State private var draftTemperature = 26.0
    @State private var isLoading = false
    @State private var message: String?

    /// 格力+ 里那一排功能开关。onValue 是「打开」时写进去的值。
    private static let flags: [GreeFlag] = [
        GreeFlag(column: "SwUpDn", title: "上下摆风", symbol: "arrow.up.and.down"),
        GreeFlag(column: "SwingLfRig", title: "左右摆风", symbol: "arrow.left.and.right"),
        GreeFlag(column: "HdHeat", title: "辅热", symbol: "flame.fill"),
        GreeFlag(column: "Sleep", title: "睡眠", symbol: "moon.fill"),
        GreeFlag(column: "SwhSl", title: "节能", symbol: "leaf.fill"),
        GreeFlag(column: "Health", title: "健康", symbol: "sparkles"),
    ]

    private static let modes: [GreeOption] = [
        GreeOption(value: 0, title: "自动"),
        GreeOption(value: 1, title: "制冷"),
        GreeOption(value: 2, title: "除湿"),
        GreeOption(value: 3, title: "送风"),
        GreeOption(value: 4, title: "制热"),
    ]

    private static let fans: [GreeOption] = [
        GreeOption(value: 0, title: "自动"),
        GreeOption(value: 1, title: "低"),
        GreeOption(value: 2, title: "中"),
        GreeOption(value: 3, title: "高"),
    ]

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
                flagSection
                SectionCard("信息", symbol: "info.circle") {
                    DeviceInfoContent(device: device)
                }
                if let note = cloudNote(.gree) {
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
                HStack(spacing: 8) {
                    StepButton(symbol: "minus", enabled: controlsEnabled) {
                        adjustTemperature(by: -1)
                    }
                    DialControl(
                        value: $draftTemperature,
                        range: 16...30,
                        step: 1,
                        headline: "\(Int(draftTemperature.rounded()))°",
                        caption: "设定温度",
                        accent: accent,
                        enabled: controlsEnabled,
                        onCommit: { commitTemperature() }
                    )
                    StepButton(symbol: "plus", enabled: controlsEnabled) {
                        adjustTemperature(by: 1)
                    }
                }
                HStack(spacing: 10) {
                    if let ambient = ambientTemperature {
                        HeroReadout(title: "室温", value: String(format: "%.1f°C", ambient))
                    }
                    if let climate {
                        HeroReadout(title: "模式", value: modeTitle(climate.mode))
                        HeroReadout(title: "风速", value: fanTitle(climate.fan))
                    }
                }
                PowerButton(on: isOn, tint: accent, enabled: !isLoading && device.online) {
                    togglePower()
                }
            }
        }
    }

    // MARK: - 各组

    private var modeSection: some View {
        SectionCard("模式", symbol: "dial.medium") {
            WrapLayout(spacing: 10, lineSpacing: 10) {
                ForEach(Self.modes) { mode in
                    ChoiceChip(title: mode.title, selected: climate?.mode == mode.value) {
                        selectMode(mode.value)
                    }
                }
            }
        }
        .controlGroup(controlsEnabled)
    }

    private var fanSection: some View {
        SectionCard("风速", symbol: "fan.fill") {
            WrapLayout(spacing: 10, lineSpacing: 10) {
                ForEach(Self.fans) { fan in
                    ChoiceChip(title: fan.title, selected: climate?.fan == fan.value) {
                        selectFan(fan.value)
                    }
                }
            }
        }
        .controlGroup(controlsEnabled)
    }

    @ViewBuilder
    private var flagSection: some View {
        let reported = Self.flags.filter { climate?.raw[$0.column] != nil }
        if !reported.isEmpty {
            SectionCard("功能", symbol: "switch.2") {
                TileGrid {
                    ForEach(reported) { flag in
                        let on = isFlagOn(flag)
                        ControlTile(
                            title: flag.title,
                            symbol: flag.symbol,
                            value: on ? "开" : "关",
                            highlighted: on,
                            enabled: controlsEnabled
                        ) {
                            toggleFlag(flag)
                        }
                    }
                }
            }
            .controlGroup(controlsEnabled)
        }
    }

    // MARK: - 读写

    private func load() async {
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            let climate = try await model.readGree(device)
            self.climate = climate
            draftTemperature = Double(min(30, max(16, climate.temperature)))
        } catch {
            message = humanize(error)
        }
    }

    private func togglePower() {
        let previous = isOn
        let next = !previous
        mutate { $0.power = next }
        Task {
            await run {
                try await model.writeGree(device, power: next, mode: nil, temperature: nil, fan: nil)
            } rollback: {
                mutate { $0.power = previous }
            }
        }
    }

    private func selectMode(_ value: Int) {
        let previous = climate?.mode
        mutate { $0.mode = value }
        Task {
            await run {
                try await model.writeGree(device, power: nil, mode: value, temperature: nil, fan: nil)
            } rollback: {
                if let previous { mutate { $0.mode = previous } }
            }
        }
    }

    private func selectFan(_ value: Int) {
        let previous = climate?.fan
        mutate { $0.fan = value }
        Task {
            await run {
                try await model.writeGree(device, power: nil, mode: nil, temperature: nil, fan: value)
            } rollback: {
                if let previous { mutate { $0.fan = previous } }
            }
        }
    }

    private func toggleFlag(_ flag: GreeFlag) {
        let previous = climate?.raw[flag.column] ?? 0
        let next = previous == 0 ? 1 : 0
        mutate { $0.raw[flag.column] = next }
        Task {
            await run {
                try await model.writeGree(device, power: nil, mode: nil, temperature: nil, fan: nil, flags: [flag.column: next])
            } rollback: {
                mutate { $0.raw[flag.column] = previous }
            }
        }
    }

    private func adjustTemperature(by delta: Double) {
        draftTemperature = min(30, max(16, draftTemperature + delta))
        commitTemperature()
    }

    private func commitTemperature() {
        let target = Int(draftTemperature.rounded())
        mutate { $0.temperature = target }
        Task {
            await run {
                try await model.writeGree(device, power: nil, mode: nil, temperature: target, fan: nil)
            }
        }
    }

    private func mutate(_ change: (inout GreeClimate) -> Void) {
        guard var current = climate else { return }
        change(&current)
        climate = current
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

    private var isOn: Bool { climate?.power ?? true }
    private var dimmed: Bool { climate.map { !$0.power } ?? false }
    private var controlsEnabled: Bool { !isLoading && device.online && isOn }

    private var accent: Color {
        guard let mode = climate?.mode else { return ControlPalette.cool }
        switch mode {
        case 1: return ControlPalette.cool
        case 2: return ControlPalette.dry
        case 3: return ControlPalette.wind
        case 4: return ControlPalette.heat
        default: return ControlPalette.cool
        }
    }

    private var statusLine: String {
        guard let climate else { return "正在读取空调" }
        let state = climate.power ? "已开启" : "已关闭"
        return "\(state) · \(modeTitle(climate.mode)) · 风速\(fanTitle(climate.fan))"
    }

    /// 格力上报室温有两种口径：老固件是「实际温度 + 40」，新固件直接是实际温度。
    /// 两个都算一遍，只认落在合理区间里的那个，免得显示成 66 度。
    private var ambientTemperature: Double? {
        guard let raw = climate?.raw["TemSen"] else { return nil }
        for candidate in [Double(raw), Double(raw) - 40] where candidate >= -10 && candidate <= 45 {
            return candidate
        }
        return nil
    }

    private func isFlagOn(_ flag: GreeFlag) -> Bool {
        (climate?.raw[flag.column] ?? 0) != 0
    }

    private func modeTitle(_ value: Int) -> String {
        Self.modes.first { $0.value == value }?.title ?? "模式\(value)"
    }

    private func fanTitle(_ value: Int) -> String {
        Self.fans.first { $0.value == value }?.title ?? "风速\(value)"
    }
}

private struct GreeFlag: Identifiable {
    var column: String
    var title: String
    var symbol: String

    var id: String { column }
}

private struct GreeOption: Identifiable {
    var value: Int
    var title: String

    var id: Int { value }
}
