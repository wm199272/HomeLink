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

/// 带出处的属性引用：UI 层要按名字挑属性，摊平后还得知道它属于哪个服务。
struct MiotPropertyRef: Identifiable, Sendable {
    var service: MiotService
    var property: MiotProperty

    var id: String { "\(service.iid).\(property.iid)" }
    var name: String { MiotNaming.identifier(property.type) }
    var serviceName: String { MiotNaming.identifier(service.type) }
}

/// 同上，动作版本。
struct MiotActionRef: Identifiable, Sendable {
    var service: MiotService
    var action: MiotAction

    var id: String { "\(service.iid).\(action.iid)" }
    var name: String { MiotNaming.identifier(action.type) }
}

extension MiotSpec {
    /// 摆在界面上的服务和属性，摊平成一维，方便按名字找。
    var uiServices: [MiotService] { services.filter(\.showsInUI) }

    var uiProperties: [MiotPropertyRef] {
        uiServices.flatMap { service in
            service.properties.map { MiotPropertyRef(service: service, property: $0) }
        }
    }

    var uiActions: [MiotActionRef] {
        uiServices.flatMap { service in
            service.actions.map { MiotActionRef(service: service, action: $0) }
        }
    }
}

extension MiotProperty {
    /// value-range 是 [最小值, 最大值, 步进]，步进可能缺省。
    var sliderBounds: ClosedRange<Double>? {
        guard let valueRange, valueRange.count >= 2, valueRange[0] < valueRange[1] else { return nil }
        return valueRange[0]...valueRange[1]
    }

    var sliderStep: Double {
        let step = valueRange?.dropFirst(2).first ?? 1
        if step <= 0 { return format == "float" ? 0.1 : 1 }
        return step
    }
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

