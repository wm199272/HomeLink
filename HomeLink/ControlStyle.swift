import SwiftUI

/// 米家 / 格力+ 的那套视觉：一张按模式换色的大卡片，下面是一排圆角瓦片和芯片。
///
/// 原来的详情页是一列系统 List 行，跟手机上的米家、格力+ 差得远。这里抽出两边共用的
/// 元件：大卡片、设定温度拨盘、圆开关、芯片、瓦片、滑杆行。
enum ControlPalette {
    static let cool = Color(red: 0.11, green: 0.42, blue: 0.92)
    static let heat = Color(red: 0.93, green: 0.35, blue: 0.18)
    static let dry = Color(red: 0.10, green: 0.62, blue: 0.62)
    static let wind = Color(red: 0.33, green: 0.45, blue: 0.64)
    static let idle = Color(red: 0.42, green: 0.44, blue: 0.47)

    /// 制冷蓝、制热橙、除湿青、送风灰蓝，跟米家按模式换色一致。
    static func accent(for raw: String?) -> Color {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return cool }
        if raw.contains("heat") || raw.contains("warm") { return heat }
        if raw.contains("dry") || raw.contains("dehumid") { return dry }
        if raw.contains("fan") || raw.contains("wind") || raw.contains("blow") { return wind }
        return cool
    }
}

/// 大卡片的渐变底，关机时褪成灰的。
struct HeroBackdrop: View {
    var tint: Color
    var dimmed = false

    var body: some View {
        LinearGradient(
            colors: [
                dimmed ? ControlPalette.idle : tint,
                (dimmed ? ControlPalette.idle : tint).opacity(0.62),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// 页面顶部那张大卡片。里面放拨盘、读数和开关按钮。
struct HeroCard<Content: View>: View {
    var tint: Color
    var dimmed: Bool
    private let content: Content

    init(tint: Color, dimmed: Bool = false, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.dimmed = dimmed
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 16) { content }
            .padding(.horizontal, 18)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
            .background {
                HeroBackdrop(tint: tint, dimmed: dimmed)
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            }
            .shadow(color: (dimmed ? ControlPalette.idle : tint).opacity(0.25), radius: 16, y: 8)
    }
}

/// 大卡片里的读数，比如室温、湿度。
struct HeroReadout: View {
    var title: String
    var value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            Text(value)
                .font(.title3.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 大卡片底部的开关按钮，米家就是个大白圆。
struct PowerButton: View {
    var on: Bool
    var tint: Color
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(on ? tint : Color.white)
                .frame(width: 66, height: 66)
                .background(on ? Color.white : Color.white.opacity(0.18), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// 拨盘两边的小加减，比只靠转动好按。
struct StepButton: View {
    var symbol: String
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.16), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// 米家那种圆环拨盘：在圆里拖动改数值，中间显示大字。
///
/// 表盘留了个缺口（扫过 268°），角度按 SwiftUI 的约定算：0° 在三点钟，顺时针为正。
/// 起点落在 136°，正好是左下，跟米家空调卡片一致。
struct DialControl: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var headline: String
    var caption: String?
    var accent: Color
    var enabled: Bool
    var onCommit: () -> Void

    private let sweep: Double = 268
    private let startAngle: Double = 136

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .trim(from: 0, to: sweep / 360)
                    .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(startAngle))
                Circle()
                    .trim(from: 0, to: sweep / 360 * fraction)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(startAngle))
                VStack(spacing: 2) {
                    Text(headline)
                        .font(.system(size: side * 0.27, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if let caption {
                        Text(caption)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
                .padding(.horizontal, 30)
            }
            .frame(width: side, height: side)
            .contentShape(Circle())
            .gesture(dragGesture(side: side))
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .opacity(enabled ? 1 : 0.55)
    }

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    private func dragGesture(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard enabled else { return }
                var path = (degrees(at: gesture.location, side: side) - startAngle)
                    .truncatingRemainder(dividingBy: 360)
                if path < 0 { path += 360 }
                // 缺口里松手就往最近的一端贴，别让手指滑到缺口时数值乱跳。
                if path > sweep + (360 - sweep) / 2 { path = 0 }
                let clamped = min(max(path, 0), sweep)
                let span = range.upperBound - range.lowerBound
                value = quantize(range.lowerBound + span * clamped / sweep)
            }
            .onEnded { _ in
                guard enabled else { return }
                onCommit()
            }
    }

    private func degrees(at point: CGPoint, side: CGFloat) -> Double {
        let dx = Double(point.x - side / 2)
        let dy = Double(point.y - side / 2)
        var degrees = atan2(dy, dx) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    private func quantize(_ raw: Double) -> Double {
        guard step > 0 else { return raw }
        let steps = ((raw - range.lowerBound) / step).rounded()
        return min(max(range.lowerBound + steps * step, range.lowerBound), range.upperBound)
    }
}

/// 一排里选一个的芯片，米家、格力+ 都是这个形状。
struct ChoiceChip: View {
    var title: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.78))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(selected ? Color.moss : Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 方瓦片：左上角图标，右上角当前值，底下一行名字。
struct ControlTile: View {
    var title: String
    var symbol: String
    var value: String?
    var highlighted = false
    var enabled = true
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { tile }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.55)
        } else {
            tile.opacity(enabled ? 1 : 0.55)
        }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(highlighted ? Color.white : Color.moss)
                    .frame(width: 30, height: 30)
                    .background(highlighted ? Color.white.opacity(0.22) : Color.moss.opacity(0.12), in: Circle())
                Spacer(minLength: 0)
                if let value {
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(highlighted ? Color.white : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            Text(title)
                .font(.footnote)
                .foregroundStyle(highlighted ? Color.white.opacity(0.82) : Color.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 94, alignment: .topLeading)
        .background(highlighted ? Color.moss : Color.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(highlighted ? 0 : 0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
    }
}

/// 扫地机页底部那两颗大按钮（基座 / 开始清洁），米家是两张白卡并排。
struct BigActionButton: View {
    var title: String
    var caption: String?
    var symbol: String
    var tint: Color
    var highlighted = false
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(highlighted ? Color.white : tint)
                    .frame(width: 40, height: 40)
                    .background(
                        highlighted ? Color.white.opacity(0.22) : tint.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(highlighted ? Color.white : Color.primary)
                    if let caption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(highlighted ? Color.white.opacity(0.8) : Color.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(highlighted ? tint : Color.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(highlighted ? 0 : 0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
    }
}

/// 「区域 全屋 ›」这种一行，点开去设置。扫地机页的区域、模式就是它。
struct SettingRow: View {
    var title: String
    var value: String
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                    Text(value)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
    }
}

/// 只读的读数瓦片，用在「实时数据」里。
struct ReadoutTile: View {
    var title: String
    var symbol: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.moss)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
    }
}

/// 白底圆角分组卡，带一行小标题。
struct SectionCard<Content: View>: View {
    var title: String?
    var symbol: String?
    private let content: Content

    init(_ title: String? = nil, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(spacing: 6) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.moss)
                    }
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
    }
}

/// 两列瓦片。
struct TileGrid<Content: View>: View {
    var columns = 2
    private let content: Content

    init(columns: Int = 2, @ViewBuilder content: () -> Content) {
        self.columns = columns
        self.content = content()
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: max(columns, 1)),
            spacing: 12
        ) {
            content
        }
    }
}

/// 卡片里的一行「标题 + 当前值 + 滑杆」。
struct SliderRow: View {
    var title: String
    var symbol: String
    var text: String
    var value: Binding<Double>
    var range: ClosedRange<Double>
    var step: Double
    var enabled: Bool
    var onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.footnote)
                    .foregroundStyle(Color.moss)
                Text(title)
                    .font(.subheadline)
                Spacer(minLength: 0)
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step) { editing in
                if !editing { onCommit() }
            }
            .disabled(!enabled)
        }
    }
}

/// 关机、离线时整块控件一起变灰，跟米家、格力+ 里不可用的样子一致。
extension View {
    func controlGroup(_ enabled: Bool) -> some View {
        disabled(!enabled).opacity(enabled ? 1 : 0.6)
    }
}

/// 详情页底部的「信息」，新老页面共用同一份字段。
struct DeviceInfoContent: View {    var device: IoTDevice

    var body: some View {
        Group {
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
}

/// 页面底部那行云端说明。米家、格力+ 两个新页面和原来的列表页共用。
func cloudNote(_ platform: PlatformKind) -> String? {
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

/// 属性名到图标的对照。认不出来的给个通用图标，绝不会因为名字没收录就空着。
///
/// **键不能重复。** Swift 的字典字面量遇到重复键会直接 `fatalError`，
/// 详情页第一次画瓦片就会闪退。
enum ControlIcon {
    static func symbol(for identifier: String) -> String {
        if let hit = table[identifier] { return hit }
        for part in identifier.split(separator: "-") {
            if let hit = table[String(part)] { return hit }
        }
        return "slider.horizontal.3"
    }

    private static let table: [String: String] = [
        "on": "power",
        "power": "power",
        "switch": "power",
        "toggle": "power",
        "mode": "dial.medium",
        "status": "info.circle",
        "fault": "exclamationmark.triangle",
        "alarm": "bell.fill",
        "abnormal": "exclamationmark.triangle",
        "brightness": "sun.max.fill",
        "color": "paintpalette.fill",
        "color-temperature": "thermometer.medium",
        "temperature": "thermometer.medium",
        "target-temperature": "thermometer.medium",
        "humidity": "humidity.fill",
        "relative-humidity": "humidity.fill",
        "fan": "fan.fill",
        "fan-level": "fan.fill",
        "fan-control": "fan.fill",
        "wind": "wind",
        "wind-speed": "fan.fill",
        "speed": "speedometer",
        "swing": "arrow.left.and.right",
        "horizontal-swing": "arrow.left.and.right",
        "vertical-swing": "arrow.up.and.down",
        "heating": "flame.fill",
        "heater": "flame.fill",
        "heat": "flame.fill",
        "eco": "leaf.fill",
        "sleep": "moon.fill",
        "sleep-mode": "moon.fill",
        "mute": "speaker.slash.fill",
        "volume": "speaker.wave.2.fill",
        "indicator-light": "lightbulb.fill",
        "light": "lightbulb.fill",
        "night-light": "moon.stars.fill",
        "ambient-light": "lightbulb.led.fill",
        "lock": "lock.fill",
        "child-lock": "lock.fill",
        "physical-controls-locked": "lock.fill",
        "door": "door.left.hand.open",
        "door-state": "door.left.hand.open",
        "curtain": "curtains.closed",
        "motion": "figure.walk",
        "motion-detection": "figure.walk",
        "occupancy": "person.fill",
        "illumination": "sun.max.fill",
        "uv": "sun.max.fill",
        "uv-index": "sun.max.fill",
        "anion": "sparkles",
        "plasma": "sparkles",
        "dryer": "wind",
        "air-quality": "aqi.medium",
        "air-quality-index": "aqi.medium",
        "pm2": "aqi.medium",
        "pm10": "aqi.medium",
        "pm25": "aqi.medium",
        "density": "aqi.medium",
        "tvoc": "aqi.low",
        "voc": "aqi.low",
        "hcho": "aqi.low",
        "co2": "aqi.medium",
        "smoke": "smoke.fill",
        "filter": "line.3.horizontal.decrease",
        "filter-life-level": "line.3.horizontal.decrease",
        "filter-used-time": "line.3.horizontal.decrease",
        "filter-left-time": "line.3.horizontal.decrease",
        "life": "line.3.horizontal.decrease",
        "left-time": "timer",
        "left-times": "timer",
        "countdown": "timer",
        "timer": "timer",
        "time": "clock.fill",
        "current-time": "clock.fill",
        "battery": "battery.100",
        "battery-level": "battery.100",
        "level": "battery.100",
        "charging": "bolt.fill",
        "charging-state": "bolt.fill",
        "charge": "bolt.fill",
        "voltage": "bolt.fill",
        "current": "bolt.fill",
        "position": "arrow.left.and.right",
        "target-position": "arrow.left.and.right",
        "angle": "angle",
        "motor": "gearshape.fill",
        "motor-control": "gearshape.fill",
        "water": "drop.fill",
        "water-level": "drop.fill",
        "flow": "drop.fill",
        "screen": "display",
        "speaker": "hifispeaker.fill",
        "video": "video.fill",
        "play": "playpause.fill",
        "play-control": "playpause.fill",
        "volume-level": "speaker.wave.2.fill",
        "air-conditioner": "air.conditioner.horizontal.fill",
        "air-purifier": "air.purifier.fill",
        "humidifier": "humidifier.fill",
        "dehumidifier": "dehumidifier.fill",
        "washer": "washer.fill",
        "fridge": "refrigerator.fill",
        "oven": "oven.fill",
        "microwave": "microwave.fill",
        "vacuum": "robotic.vacuum.fill",
        "robot": "robotic.vacuum.fill",
        "sweep": "sparkles",
        "sweep-mop-type": "drop.fill",
        "sweep-mop-status": "sparkles",
        "sweep-type": "square.grid.3x3.fill",
        "suction-level": "fan.fill",
        "mop-water-output-level": "drop.fill",
        "mop-wash-left-time": "timer",
        "mop-life-level": "drop.fill",
        "dust-arrest-left-time": "timer",
        "dust-bag-life-level": "bag.fill",
        "dust-bag-left-time": "timer",
        "carpet-boost": "square.grid.2x2",
        "sweep-ai-detection": "eye",
        "auto-dust-arrest": "arrow.down.circle.fill",
        "auto-mop-dry": "wind",
        "dry-left-time": "timer",
        "drying-time": "wind",
        "cleaning-progress": "gauge.with.dots.needle.50percent",
        "statistical-clean-area": "square.dashed",
        "statistical-cleaning-duration": "clock.fill",
        "statistical-cleaning-times": "number",
        "last-clean-time": "clock.arrow.circlepath",
        "base-station-working-status": "house.fill",
        "cleaning-area": "square.dashed",
        "cleaning-time": "clock.fill",
        "room-information": "square.grid.3x3.fill",
        "water-tank-status": "drop.fill",
        "water-tank-level": "drop.fill",
        "charge-progress": "bolt.fill",
        "cooker": "cooktop.fill",
        "dryer-machine": "dryer.fill",
        "dishwasher": "dishwasher.fill",
        "wifi": "wifi",
        "network": "network",
        "signal": "antenna.radiowaves.left.and.right",
        "rssi": "antenna.radiowaves.left.and.right",
        "bluetooth": "bluetooth",
        "cpu": "cpu",
        "storage": "externaldrive.fill",
        "speed-level": "speedometer",
        "working-time": "clock.fill",
        "used-time": "clock.fill",
        "usage": "clock.fill",
        "child": "figure.child",
        "baby": "figure.child",
        "milk": "cup.and.saucer.fill",
        "massage": "hand.raised.fill",
        "strength": "gauge.with.dots.needle.33percent",
        "backrest": "figure.seated.side",
        "seat": "figure.seated.side",
        "leg": "figure.walk",
        "height": "ruler",
        "weight": "scalemass.fill",
        "heart": "heart.fill",
        "respiratory": "lungs.fill",
        "battery-health": "heart.fill",
        "camera": "camera.fill",
        "detection": "viewfinder",
        "tracking": "viewfinder",
        "zoom": "magnifyingglass",
        "record": "record.circle",
        "recording": "record.circle",
        "night-shot": "moon.circle.fill",
        "hdr": "camera.filters",
        "language": "globe",
        "steam": "humidity.fill",
        "keep-warm": "thermometer.sun.fill",
        "warm": "thermometer.sun.fill",
        "quick": "hare.fill",
        "strong": "bolt.fill",
        "quiet": "speaker.slash.fill",
        "turbo": "bolt.fill",
    ]
}
