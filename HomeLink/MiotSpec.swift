import Foundation

struct MiotSpec: Decodable, Sendable {
    var type: String
    var description: String
    var services: [MiotService]

    static func powerProperty(in spec: MiotSpec) -> (siid: Int, piid: Int)? {
        for service in spec.services {
            for property in service.properties {
                let name = MiotNaming.identifier(property.type)
                if name == "on", property.format == "bool", property.access.contains("write") {
                    return (service.iid, property.iid)
                }
            }
        }
        return nil
    }
}

struct MiotService: Decodable, Identifiable, Sendable {
    var iid: Int
    var type: String
    var description: String
    var properties: [MiotProperty]
    var actions: [MiotAction]

    var id: Int { iid }

    var showsInUI: Bool {
        MiotNaming.identifier(type) != "device-information"
    }
}

struct MiotProperty: Decodable, Identifiable, Sendable {
    var iid: Int
    var type: String
    var description: String
    var format: String
    var access: [String]
    var unit: String?
    var valueRange: [Double]?
    var valueList: [MiotValueOption]?

    var id: Int { iid }
    var canRead: Bool { access.contains("read") }
    var canWrite: Bool { access.contains("write") }

    var visible: Bool {
        let name = MiotNaming.identifier(type)
        let hidden = ["serial-number", "serial-no", "manufacturer", "model", "firmware-revision", "hardware-revision"]
        return (canRead || canWrite) && !hidden.contains(name)
    }
}

struct MiotValueOption: Decodable, Hashable, Sendable {
    var value: JSONScalar
    var description: String
}

struct MiotAction: Decodable, Identifiable, Sendable {
    var iid: Int
    var type: String
    var description: String
    var inputs: [MiotActionInput]

    var id: Int { iid }
    var canRunWithoutInput: Bool { inputs.isEmpty }
}

struct MiotActionInput: Decodable, Sendable {
    var piid: Int?
}

extension MiotSpec {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        services = try container.decodeIfPresent([MiotService].self, forKey: .services) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case type, description, services
    }
}

extension MiotService {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        iid = try container.decode(Int.self, forKey: .iid)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        properties = try container.decodeIfPresent([MiotProperty].self, forKey: .properties) ?? []
        actions = try container.decodeIfPresent([MiotAction].self, forKey: .actions) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case iid, type, description, properties, actions
    }
}

extension MiotProperty {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        iid = try container.decode(Int.self, forKey: .iid)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        format = try container.decodeIfPresent(String.self, forKey: .format) ?? ""
        access = try container.decodeIfPresent([String].self, forKey: .access) ?? []
        unit = try container.decodeIfPresent(String.self, forKey: .unit)
        valueRange = Self.decodeRange(container)
        valueList = try container.decodeIfPresent([MiotValueOption].self, forKey: .valueList)
    }

    private enum CodingKeys: String, CodingKey {
        case iid, type, description, format, access, unit
        case valueRange = "value-range"
        case valueList = "value-list"
    }

    private static func decodeRange(_ container: KeyedDecodingContainer<CodingKeys>) -> [Double]? {
        guard var nested = try? container.nestedUnkeyedContainer(forKey: .valueRange) else { return nil }
        var values: [Double] = []
        while !nested.isAtEnd {
            if let value = try? nested.decode(Double.self) {
                values.append(value)
            } else if let value = try? nested.decode(Int.self) {
                values.append(Double(value))
            } else {
                break
            }
        }
        return values.count >= 2 ? values : nil
    }
}

extension MiotAction {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        iid = try container.decode(Int.self, forKey: .iid)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        inputs = (try? container.decode([MiotActionInput].self, forKey: .inputs)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case iid, type, description
        case inputs = "in"
    }
}

enum MiotNaming {
    static func identifier(_ urn: String) -> String {
        let parts = urn.split(separator: ":")
        guard parts.count > 3 else { return urn }
        return String(parts[3])
    }

    static func title(type: String, fallback: String) -> String {
        let key = identifier(type)
        return names[key] ?? (fallback.isEmpty ? key : fallback)
    }

    static func unitSuffix(_ unit: String?) -> String {
        switch unit {
        case "percentage": "%"
        case "celsius": "°C"
        case "kelvin": "K"
        case "seconds": "秒"
        case "minutes": "分钟"
        case "hours": "小时"
        case "lux": " lx"
        case "watt": " W"
        default: ""
        }
    }

    private static let names: [String: String] = [
        "on": "开关",
        "brightness": "亮度",
        "color-temperature": "色温",
        "color": "颜色",
        "mode": "模式",
        "status": "状态",
        "fault": "故障",
        "temperature": "温度",
        "target-temperature": "目标温度",
        "relative-humidity": "湿度",
        "humidity": "湿度",
        "fan-level": "风速",
        "fan-control": "风扇",
        "heating": "加热",
        "eco": "节能",
        "sleep-mode": "睡眠",
        "uv": "紫外线",
        "anion": "负离子",
        "heater": "辅热",
        "dryer": "干燥",
        "target-position": "目标位置",
        "current-position": "当前位置",
        "motor-control": "电机",
        "battery-level": "电量",
        "illumination": "光照",
        "pm2.5-density": "PM2.5",
        "pm10-density": "PM10",
        "air-quality": "空气质量",
        "filter-life-level": "滤芯寿命",
        "filter-used-time": "滤芯已用",
        "physical-controls-locked": "童锁",
        "alarm": "报警",
        "volume": "音量",
        "mute": "静音",
        "light": "灯",
        "switch": "开关",
        "power": "电源",
        "toggle": "切换",
        "air-conditioner": "空调",
        "fan": "风扇",
        "air-purifier": "空气净化器",
        "lightbulb": "灯",
        "curtain": "窗帘",
        "vacuum": "扫地机",
        "humidifier": "加湿器",
        "dehumidifier": "除湿机",
        "camera-control": "摄像机",
        "speaker": "音箱",
        "gateway": "网关",
        "motion-sensor": "人体传感器",
        "magnet-sensor": "门窗传感器",
        "temperature-humidity-sensor": "温湿度传感器",
        "submersion-sensor": "水浸传感器",
        "occupancy-sensor": "存在传感器",
        "battery": "电池",
        "indicator-light": "指示灯",
        "environment": "环境",
        "filter": "滤芯",
    ]
}
