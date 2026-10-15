import Foundation
import SwiftUI

/// 扫地机的枚举值。
///
/// MIoT 描述里是英文，米家 App 里是「仅扫地 / 仅拖地 / 扫拖同时 / 先扫后拖」「安静 / 标准 / 强劲 / 超强」
/// 这套说法。同名枚举在别的设备上意思可能不同，所以这里按**属性名**分别翻译，不并进全局表。
enum VacuumNaming {
    static func optionTitle(_ raw: String, property: String) -> String {
        if let table = tables[property], let hit = table[normalize(raw)] { return hit }
        return MiotNaming.optionTitle(raw)
    }

    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static let tables: [String: [String: String]] = [
        "sweep-mop-type": [
            "sweep": "仅扫地",
            "mop": "仅拖地",
            "sweep mop": "扫拖同步",
            "sweep and mop": "扫拖同步",
            "sweep before mopping": "先扫后拖",
            "sweep before mop": "先扫后拖",
        ],
        "suction-level": [
            "silent": "安静",
            "quiet": "安静",
            "basic": "标准",
            "standard": "标准",
            "strong": "强力",
            "full speed": "超强",
            "max": "超强",
            "turbo": "超强",
        ],
        "fan-level": [
            "auto": "自动",
            "level1": "1档",
            "level2": "2档",
            "level3": "3档",
            "level4": "4档",
        ],
        "mop-water-output-level": [
            "off": "关",
            "level1": "1档",
            "level2": "2档",
            "level3": "3档",
        ],
        "sweep-route": [
            "fast": "快速清洁",
            "quick": "快速清洁",
            "rapid": "快速清洁",
            "daily": "日常清洁",
            "standard": "日常清洁",
            "normal": "日常清洁",
            "basic": "日常清洁",
            "fine": "精细清洁",
            "deep": "精细清洁",
            "thorough": "精细清洁",
            "intensive": "精细清洁",
            "precision": "精细清洁",
        ],
        "vacuum-route": [
            "fast": "快速清洁",
            "quick": "快速清洁",
            "rapid": "快速清洁",
            "daily": "日常清洁",
            "standard": "日常清洁",
            "normal": "日常清洁",
            "basic": "日常清洁",
            "fine": "精细清洁",
            "deep": "精细清洁",
            "thorough": "精细清洁",
            "intensive": "精细清洁",
            "precision": "精细清洁",
        ],
        "sweep-type": [
            "global": "全屋",
            "zone": "选区",
            "area": "划区",
            "edge": "沿边",
            "custom": "自定义",
            "point": "定点",
            "custom area": "自定义区域",
        ],
        "status": [
            "idle": "待机",
            "busy": "工作中",
            "delay": "延时中",
        ],
        "sweep-mop-status": [
            "idle": "待机",
            "sweeping": "清扫中",
            "mopping": "拖地中",
        ],
        "charging-state": [
            "charging": "充电中",
            "not charging": "未充电",
            "not chargeable": "无法充电",
        ],
        "water-tank-status": [
            "not empty": "有水",
            "empty": "缺水",
        ],
        "fault": [
            "no faults": "正常",
            "overheat": "过热",
        ],
    ]
}

/// 地图上的一个房间。
struct VacuumRoom: Identifiable, Hashable {
    var id: Int
    var name: String

    var displayName: String { name.isEmpty ? "房间 \(id)" : name }
}

/// `room-information` / `room-name` 的解析。
///
/// 这几列各家固件写法不一样：有的一整段 JSON 数组，有的是「编号 → 名字」的对象，
/// 有的只有逗号隔开的编号。能认的写法都认，实在没有名字就叫「房间 1」。
enum VacuumRooms {
    static func parse(
        roomInformation: JSONScalar?,
        roomName: JSONScalar?,
        roomIds: JSONScalar?
    ) -> [VacuumRoom] {
        var names: [Int: String] = [:]
        var order: [Int] = []

        func remember(_ id: Int, _ name: String) {
            guard id > 0 else { return }
            if !order.contains(id) { order.append(id) }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !looksLikeNumber(trimmed) { names[id] = trimmed }
        }

        if let text = text(of: roomInformation) {
            if let parsed = json(text) {
                collect(parsed, remember: remember)
            } else {
                for (offset, token) in tokens(text).enumerated() {
                    if let id = Int(token) {
                        remember(id, "")
                    } else {
                        remember(offset + 1, token)
                    }
                }
            }
        }
        if let text = text(of: roomName), let parsed = json(text) {
            collect(parsed) { id, name in
                if id > 0 { names[id] = name.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }

        // 编号是主：有些固件只在 room-information 里放编号，名字单独在 room-name 里。
        let listed = text(of: roomIds).map { tokens($0).compactMap { Int($0) } } ?? []
        for id in listed where !order.contains(id) { order.append(id) }
        for id in names.keys.sorted() where !order.contains(id) { order.append(id) }

        return order.sorted().map { VacuumRoom(id: $0, name: names[$0] ?? "") }
    }

    /// 当前选中的房间编号，取不到就给空集合（表示全屋）。
    static func selected(from value: JSONScalar?) -> Set<Int> {
        guard let text = text(of: value) else { return [] }
        if let parsed = json(text), let list = parsed as? [Any] {
            return Set(list.compactMap { item in
                if let number = item as? NSNumber { return number.intValue }
                if let dictionary = item as? [String: Any] { return firstInt(in: dictionary) }
                if let string = item as? String { return Int(string) }
                return nil
            })
        }
        return Set(tokens(text).compactMap { Int($0) })
    }

    private static func text(of value: JSONScalar?) -> String? {
        guard let value else { return nil }
        switch value {
        case let .string(raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let .int(number):
            return String(number)
        default:
            return nil
        }
    }

    private static func json(_ text: String) -> Any? {
        guard let first = text.first, first == "[" || first == "{" else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]\"'")) }
            .filter { !$0.isEmpty }
    }

    private static func looksLikeNumber(_ text: String) -> Bool { Int(text) != nil }

    private static func firstInt(in dictionary: [String: Any]) -> Int? {
        for key in ["id", "roomId", "room_id", "roomid", "rid", "value"] {
            if let number = dictionary[key] as? NSNumber { return number.intValue }
            if let string = dictionary[key] as? String, let number = Int(string) { return number }
        }
        for value in dictionary.values {
            if let number = value as? NSNumber { return number.intValue }
        }
        return nil
    }

    private static func firstName(in dictionary: [String: Any]) -> String {
        for key in ["name", "roomName", "room_name", "name_id", "description", "nickname", "text"] {
            if let string = dictionary[key] as? String, !string.isEmpty { return string }
        }
        return ""
    }

    private static func collect(_ parsed: Any, remember: (Int, String) -> Void) {
        if let list = parsed as? [Any] {
            for (offset, item) in list.enumerated() {
                if let dictionary = item as? [String: Any] {
                    remember(firstInt(in: dictionary) ?? (offset + 1), firstName(in: dictionary))
                } else if let string = item as? String {
                    if let id = Int(string) {
                        remember(id, "")
                    } else {
                        remember(offset + 1, string)
                    }
                } else if let number = item as? NSNumber {
                    remember(number.intValue, "")
                }
            }
            return
        }
        if let dictionary = parsed as? [String: Any] {
            for (key, value) in dictionary {
                if let id = Int(key), let name = value as? String {
                    remember(id, name)
                } else if let name = value as? [String: Any], let id = firstInt(in: name) ?? Int(key) {
                    remember(id, firstName(in: name))
                }
            }
        }
    }
}

/// 扫地机只用到快捷操作：开始 / 暂停 / 停止、清洁选择、基座三件套。
/// 其余属性一律认下来藏掉，不再落到通用开关、滑杆里。
struct VacuumRoles {
    var status: MiotPropertyRef?
    var sweepStatus: MiotPropertyRef?
    var fault: MiotPropertyRef?
    var sweepMopType: MiotPropertyRef?
    var suction: MiotPropertyRef?
    var waterLevel: MiotPropertyRef?
    var route: MiotPropertyRef?
    var batteryLevel: MiotPropertyRef?
    var chargingState: MiotPropertyRef?
    var chargeProgress: MiotPropertyRef?
    var lastClean: MiotPropertyRef?
    var progress: MiotPropertyRef?
    var cleanedArea: MiotPropertyRef?
    var cleanedDuration: MiotPropertyRef?
    var stationStatus: MiotPropertyRef?
    var mopWashLeft: MiotPropertyRef?
    var dryLeft: MiotPropertyRef?
    var dustLeft: MiotPropertyRef?
    var on: MiotPropertyRef?
    var start: MiotActionRef?
    var stop: MiotActionRef?
    var dock: MiotActionRef?
    var pause: MiotActionRef?
    var resume: MiotActionRef?
    var mopWash: MiotActionRef?
    var dry: MiotActionRef?
    var dustArrest: MiotActionRef?

    var claimed: Set<String> = []
    /// 已经摆在界面上的动作，不再重复出现在「更多功能」里。
    var claimedActions: Set<String> = []

    init?(spec: MiotSpec) {
        let properties = spec.uiProperties
        // 扫地机的主体服务就叫 vacuum；有些固件把清扫状态挂在别的服务下，所以也认标志性属性。
        let looksLikeVacuum = spec.uiServices.contains { $0.type.contains(":vacuum:") }
            || properties.contains { $0.name == "sweep-mop-type" }
        guard looksLikeVacuum else { return nil }

        func pick(_ names: [String], services: [String] = []) -> MiotPropertyRef? {
            for name in names {
                if let hit = properties.first(where: { ref in
                    ref.name == name && (services.isEmpty || services.contains(ref.serviceName))
                }) {
                    return hit
                }
            }
            return nil
        }

        func action(_ names: [String]) -> MiotActionRef? {
            for name in names {
                if let hit = spec.uiActions.first(where: { $0.name == name }) { return hit }
            }
            return nil
        }

        // 只认 vacuum 服务上的 status。别的服务也有同名列（电池、通用设备），
        // 数字含义完全不同，拿来判断会不会在扫会把待机当成工作中。
        status = pick(["status"], services: ["vacuum"])
        sweepStatus = pick(["sweep-mop-status"])
        fault = pick(["fault"])
        sweepMopType = pick(["sweep-mop-type"])
        suction = pick(["suction-level", "fan-level", "speed-level"])
        waterLevel = pick(["mop-water-output-level"])
        route = pick(["sweep-route", "vacuum-route"])
        batteryLevel = pick(["battery-level"], services: ["battery"])
        chargingState = pick(["charging-state"], services: ["battery"])
        chargeProgress = pick(["charge-progress"], services: ["battery"])
        lastClean = pick(["last-clean-time"])
        progress = pick(["cleaning-progress"])
        cleanedArea = pick(["statistical-clean-area", "cleaning-area"])
        cleanedDuration = pick(["statistical-cleaning-duration", "cleaning-time"])
        stationStatus = pick(["base-station-working-status"])
        mopWashLeft = pick(["mop-wash-left-time"])
        dryLeft = pick(["dry-left-time"])
        dustLeft = pick(["dust-arrest-left-time"])
        on = pick(["on"])

        start = action(["start-sweep", "start-sweep-mop", "start-only-sweep", "start-custom-sweep"])
        stop = action(["stop-sweeping", "stop-working"])
        dock = action(["stop-and-gocharge", "start-gocharge", "gocharge"])
        pause = action(["pause-sweeping", "pause-build-map"])
        resume = action(["continue-sweep", "sweep"])
        mopWash = action(["start-mop-wash"])
        dry = action(["start-dry"])
        dustArrest = action(["start-dust-arrest"])

        for ref in properties where ["vacuum", "battery", "mop", "dust-bag", "vacuum-map"].contains(ref.serviceName) {
            claimed.insert(ref.id)
        }
        for ref in [
            status, sweepStatus, fault, sweepMopType, suction, waterLevel, route,
            batteryLevel, chargingState, chargeProgress, lastClean, progress,
            cleanedArea, cleanedDuration, stationStatus, mopWashLeft, dryLeft, dustLeft, on,
        ].compactMap({ $0 }) {
            claimed.insert(ref.id)
        }
        claimedActions = Set(spec.uiActions.map(\.id))
    }
}

/// 扫地机页的两个弹窗：基座三件套、清洁选择。
enum VacuumSheet: String, Identifiable {
    case station
    case settings

    var id: String { rawValue }
}

/// 米家里那种圆按钮：扫拖模式、吸力、水量、基站动作都是它。
struct VacuumCircleButton: View {
    var title: String
    var symbol: String
    var selected = false
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.55))
                    .frame(width: 64, height: 64)
                    .background(selected ? Color.vacuumBlue : Color.primary.opacity(0.06), in: Circle())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.vacuumBlue : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

extension Color {
    /// 米家扫地机选中态那个蓝。
    fileprivate static let vacuumBlue = Color(red: 0.18, green: 0.55, blue: 0.98)
}

enum VacuumGlyph {
    static func sweepMop(_ raw: String) -> String {
        switch VacuumNaming.optionTitle(raw, property: "sweep-mop-type") {
        case "仅扫地": "house"
        case "扫拖同步": "arrow.triangle.2.circlepath"
        case "先扫后拖": "square.split.2x1"
        default: "drop.fill"
        }
    }

    static func suction(_ raw: String) -> String {
        switch VacuumNaming.optionTitle(raw, property: "suction-level") {
        case "安静": "fan"
        case "标准": "fan.fill"
        case "强力": "wind"
        default: "tornado"
        }
    }

    static func water(_ raw: String) -> String {
        switch VacuumNaming.optionTitle(raw, property: "mop-water-output-level") {
        case "关": "drop"
        case "1档": "drop"
        case "2档": "drop.fill"
        default: "drop.fill"
        }
    }

    static func route(_ raw: String) -> String {
        switch VacuumNaming.optionTitle(raw, property: "sweep-route") {
        case "快速清洁": "point.topleft.down.to.point.bottomright.curvepath"
        case "精细清洁": "square.grid.3x3.fill"
        default: "s.circle"
        }
    }
}

/// 扫地机页顶那颗浅灰胶囊：左边最近清洁的时间，右边电量。跟米家那颗一样。
struct VacuumStatusChip: View {
    var lastClean: String?
    var battery: String?
    var batterySymbol: String
    var batteryTint: Color

    var body: some View {
        HStack(spacing: 18) {
            if let lastClean {
                VStack(spacing: 2) {
                    Text(lastClean)
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                    Text("最近清洁")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let battery {
                HStack(spacing: 6) {
                    Image(systemName: batterySymbol)
                        .font(.subheadline)
                        .foregroundStyle(batteryTint)
                    Text(battery)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}
