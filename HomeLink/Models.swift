import Foundation

enum PlatformKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case xiaomi
    case gree
    case qihoo
    case deye
    case broad
    case homerun
    case midea
    case haier
    case jbot
    case mai
    case homekit
    case huawei
    case tuya
    case aqara

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xiaomi: "米家"
        case .gree: "格力+"
        case .qihoo: "360 智慧生活"
        case .deye: "德业智能"
        case .broad: "远大空气管家"
        case .homerun: "霍曼宠物"
        case .midea: "美的美居"
        case .haier: "海尔智家"
        case .jbot: "Jbotsports Pro"
        case .mai: "70 迈"
        case .homekit: "Apple 家庭"
        case .huawei: "华为智慧生活"
        case .tuya: "涂鸦智能"
        case .aqara: "绿米 Aqara"
        }
    }

    var subtitle: String {
        switch self {
        case .xiaomi: "登录小米账号，管理该账号在米家中的设备"
        case .gree: "登录格力+账号，管理该账号下的空调"
        case .qihoo: "登录 360 账号，管理智慧生活中的设备"
        case .deye: "登录德业智能账号，管理该账号下的设备"
        case .broad: "登录远大空气管家账号，查看该账号下的设备"
        case .homerun: "公开的账号登录接口还不稳定"
        case .midea: "登录美的美居账号，管理该账号下的设备"
        case .haier: "登录海尔智家账号，查看该账号下的设备"
        case .jbot: "连接身边的发球机，不需要云账号"
        case .mai: "登录 70 迈账号，查看该账号下的记录仪"
        case .homekit: "管理已经加入 Apple「家庭」的设备"
        case .huawei: "适配位已留好，等待官方授权接口"
        case .tuya: "适配位已留好，等待涂鸦云授权"
        case .aqara: "适配位已留好，等待 Aqara 授权"
        }
    }

    var symbol: String {
        switch self {
        case .xiaomi: "house.fill"
        case .gree: "air.conditioner.horizontal.fill"
        case .qihoo: "circle.hexagongrid.fill"
        case .deye: "humidity.fill"
        case .broad: "wind"
        case .homerun: "pawprint.fill"
        case .midea: "washer.fill"
        case .haier: "refrigerator.fill"
        case .jbot: "figure.tennis"
        case .mai: "video.fill"
        case .homekit: "homekit"
        case .huawei: "wifi.router"
        case .tuya: "lightbulb.2.fill"
        case .aqara: "sensor.fill"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .xiaomi, .gree, .qihoo, .deye, .broad, .midea, .haier, .jbot, .mai, .homekit: true
        case .homerun, .huawei, .tuya, .aqara: false
        }
    }

    var sortOrder: Int {
        switch self {
        case .xiaomi: 0
        case .gree: 1
        case .qihoo: 2
        case .deye: 3
        case .broad: 4
        case .homerun: 5
        case .midea: 6
        case .haier: 7
        case .jbot: 8
        case .mai: 9
        case .homekit: 10
        case .huawei: 11
        case .tuya: 12
        case .aqara: 13
        }
    }
}

enum GreeRegion: String, CaseIterable, Identifiable, Sendable {
    case cn, hk, eu, na, sa, la, india, me, au, ru

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cn: "中国大陆"
        case .hk: "东南亚"
        case .eu: "欧洲"
        case .na: "北美"
        case .sa: "南美"
        case .la: "拉美"
        case .india: "印度"
        case .me: "中东"
        case .au: "澳大利亚"
        case .ru: "俄罗斯"
        }
    }

    var host: String {
        switch self {
        case .cn: "https://grih.gree.com"
        case .hk: "https://hkgrih.gree.com"
        case .eu: "https://eugrih.gree.com"
        case .na: "https://nagrih.gree.com"
        case .sa: "https://sagrih.gree.com"
        case .la: "https://lagrih.gree.com"
        case .india: "https://ingrih.gree.com"
        case .me: "https://megrih.gree.com"
        case .au: "https://augrih.gree.com"
        case .ru: "https://rugrih.gree.com"
        }
    }

    var mqttHost: String {
        switch self {
        case .cn: "mqtt.gree.com"
        case .hk: "mqtt-as.gree.com"
        case .eu: "mqtt-eu.gree.com"
        case .na: "mqtt-na.gree.com"
        case .sa: "mqtt-sa.gree.com"
        case .la: "mqtt-la.gree.com"
        case .india: "mqtt-in.gree.com"
        case .me: "mqtt-me.gree.com"
        case .au: "mqtt-au.gree.com"
        case .ru: "mqtt-ru.gree.com"
        }
    }

    static func title(for raw: String?) -> String {
        guard let raw, let region = GreeRegion(rawValue: raw) else { return "格力+" }
        return region.title
    }
}

enum XiaomiRegion: String, CaseIterable, Identifiable, Sendable {
    case cn, sg, us, de, ru, tw, ind = "in", i2

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cn: "中国大陆"
        case .sg: "新加坡"
        case .us: "美国"
        case .de: "欧洲"
        case .ru: "俄罗斯"
        case .tw: "中国台湾"
        case .ind: "印度"
        case .i2: "印度（备用）"
        }
    }

    static func title(for raw: String?) -> String {
        guard let raw, let region = XiaomiRegion(rawValue: raw) else { return "未选地区" }
        return region.title
    }
}

struct XiaomiSession: Codable, Hashable, Sendable {
    var userId: String
    var ssecurity: String
    var serviceToken: String
    var cUserId: String?
    var server: String
    var deviceId: String
    var userAgent: String
}

struct GreeSession: Codable, Hashable, Sendable {
    var userId: String
    var token: String
    var host: String
    var mqttHost: String
    var username: String
    /// 每台空调的通信密钥。只随账号放在钥匙串里，不写入设备缓存。
    var deviceKeys: [String: String]
}

struct QihooDeviceIdentity: Codable, Hashable, Sendable {
    var mid: String
    var androidId: String
    var m2: String
}

struct QihooSession: Codable, Hashable, Sendable {
    var q: String
    var t: String
    var qid: String
    var sid: String
    var device: QihooDeviceIdentity
}

struct DeyeSession: Codable, Hashable, Sendable {
    var token: String
    var username: String
    var userId: String?
}

struct BroadSession: Codable, Hashable, Sendable {
    var userID: String
    var token: String
    var username: String
}

struct MideaSession: Codable, Hashable, Sendable {
    var account: String
    var accessToken: String
    var deviceID: String
    /// 登录后下发的报文密钥。只放钥匙串，设备缓存里不写。
    var aesKey: String?
}

struct HaierSession: Codable, Hashable, Sendable {
    var clientID: String
    var token: String
    var refreshToken: String
    var expiresAt: Int
    var userID: String
    var username: String
}

struct MaiSession: Codable, Hashable, Sendable {
    var email: String
    var uuid: String
    var token: String
    var userID: String?
}

struct JbotSession: Codable, Hashable, Sendable {
    var peripheralID: String
    var name: String
}

struct LinkedAccount: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var platform: PlatformKind
    var displayName: String
    var region: String?
    var linkedAt: Date
    var needsRelogin: Bool
    var xiaomi: XiaomiSession? = nil
    var gree: GreeSession? = nil
    var qihoo: QihooSession? = nil
    var deye: DeyeSession? = nil
    var broad: BroadSession? = nil
    var midea: MideaSession? = nil
    var haier: HaierSession? = nil
    var mai: MaiSession? = nil
    var jbot: JbotSession? = nil

    var detail: String {
        switch platform {
        case .xiaomi:
            let region = XiaomiRegion.title(for: region)
            return needsRelogin ? "\(region) · 需要重新登录" : region
        case .gree:
            let name = GreeRegion.title(for: region)
            return needsRelogin ? "\(name) · 需要重新登录" : name
        case .qihoo:
            return needsRelogin ? "需要重新登录" : "360 账号"
        case .deye:
            return needsRelogin ? "需要重新登录" : "德业账号"
        case .broad, .midea, .haier, .mai:
            return needsRelogin ? "需要重新登录" : platform.subtitle
        case .jbot:
            return jbot?.name ?? "发球机"
        case .homekit:
            return "本机「家庭」"
        case .homerun, .huawei, .tuya, .aqara:
            return platform.subtitle
        }
    }
}

enum DeviceCategory: String, Codable, Hashable, Sendable {
    case light
    case outlet
    case wallSwitch
    case airConditioner
    case fan
    case purifier
    case curtain
    case sensor
    case camera
    case lock
    case vacuum
    case humidifier
    case speaker
    case gateway
    case other

    var symbol: String {
        switch self {
        case .light: "lightbulb.fill"
        case .outlet: "powerplug.fill"
        case .wallSwitch: "switch.2"
        case .airConditioner: "air.conditioner.horizontal.fill"
        case .fan: "fan.fill"
        case .purifier: "aqi.medium"
        case .curtain: "curtains.closed"
        case .sensor: "sensor.fill"
        case .camera: "video.fill"
        case .lock: "lock.fill"
        case .vacuum: "robotic.vacuum.fill"
        case .humidifier: "humidifier.fill"
        case .speaker: "hifispeaker.fill"
        case .gateway: "wifi.router.fill"
        case .other: "cube.fill"
        }
    }

    static func resolve(model: String, specType: String?) -> DeviceCategory {
        let specName = specType.flatMap { MiotNaming.identifier($0) } ?? ""
        let blob = (model + " " + specName).lowercased()
        let pairs: [(String, DeviceCategory)] = [
            ("light", .light),
            ("lamp", .light),
            ("bulb", .light),
            ("outlet", .outlet),
            ("plug", .outlet),
            ("switch", .wallSwitch),
            ("ctrl_ln", .wallSwitch),
            ("air-conditioner", .airConditioner),
            ("aircondition", .airConditioner),
            ("air-purifier", .purifier),
            ("airpurifier", .purifier),
            ("fan", .fan),
            ("curtain", .curtain),
            ("window-opener", .curtain),
            ("camera", .camera),
            ("lock", .lock),
            ("vacuum", .vacuum),
            ("humidifier", .humidifier),
            ("dehumidifier", .humidifier),
            ("speaker", .speaker),
            ("gateway", .gateway),
            ("sensor", .sensor),
            ("magnet", .sensor),
            ("motion", .sensor),
        ]
        for (needle, category) in pairs where blob.contains(needle) {
            return category
        }
        return .other
    }
}

enum PowerState: String, Codable, Hashable, Sendable {
    case on
    case off
    case unavailable
}

struct IoTDevice: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var did: String
    var name: String
    var model: String
    var online: Bool
    var specType: String?
    var localIP: String?
    var roomName: String
    var homeName: String
    var homeId: String
    var accountId: UUID
    var platform: PlatformKind
    var category: DeviceCategory
    var power: PowerState?

    var canToggle: Bool {
        power == .on || power == .off
    }
}

struct IoTRoom: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var devices: [IoTDevice]
}

struct IoTHome: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var homeId: String
    var name: String
    var platform: PlatformKind
    var accountId: UUID
    var rooms: [IoTRoom]

    var devices: [IoTDevice] {
        rooms.flatMap(\.devices)
    }
}

struct DeviceRoute: Hashable, Sendable {
    var id: String
}

enum JSONScalar: Codable, Hashable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        self = .string("")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        }
    }

    var jsonObject: Any {
        switch self {
        case let .bool(value): value
        case let .int(value): value
        case let .double(value): value
        case let .string(value): value
        }
    }

    var displayText: String {
        switch self {
        case let .bool(value):
            return value ? "开" : "关"
        case let .int(value):
            return String(value)
        case let .double(value):
            if value.rounded() == value { return String(Int(value)) }
            return String(format: "%.1f", value)
        case let .string(value):
            return value
        }
    }

    static func from(_ any: Any?) -> JSONScalar? {
        guard let any, !(any is NSNull) else { return nil }
        if isJSONBool(any) {
            return .bool((any as! NSNumber).boolValue)
        }
        if let number = any as? NSNumber {
            let double = number.doubleValue
            if double.rounded() == double, abs(double) < Double(Int.max) {
                return .int(number.intValue)
            }
            return .double(double)
        }
        if let text = any as? String {
            return .string(text)
        }
        return nil
    }
}

func isJSONBool(_ any: Any?) -> Bool {
    guard let number = any as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
}

func jsonInt(_ any: Any?) -> Int? {
    guard let any, !isJSONBool(any) else { return nil }
    if let value = any as? Int { return value }
    if let number = any as? NSNumber { return number.intValue }
    if let text = any as? String { return Int(text) }
    return nil
}

func jsonString(_ any: Any?) -> String? {
    guard let any, !(any is NSNull) else { return nil }
    if let text = any as? String { return text }
    if isJSONBool(any) { return nil }
    if let number = any as? NSNumber { return number.stringValue }
    return nil
}

enum CloudError: LocalizedError {
    case invalidResponse
    case failed(String)
    case sessionExpired(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "服务器返回了无法识别的数据"
        case let .failed(message):
            message
        case let .sessionExpired(name):
            "\(name)登录已过期，请在「平台」里重新关联"
        }
    }
}

struct GreeClimate: Sendable {
    var power: Bool
    var mode: Int
    var temperature: Int
    var fan: Int
}

struct DeyeClimate: Sendable {
    var power: Bool
    var mode: Int
    var humidity: Int
    var fan: Int
    var ambientHumidity: Int?
    var supportsControl: Bool
}

enum VacuumCommand: Sendable {
    case start
    case pause
    case dock
}

enum XiaomiError: LocalizedError {
    case invalidResponse
    case failed(String)
    case sessionExpired
    case qrExpired

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "小米服务器返回了无法识别的数据"
        case let .failed(message):
            message
        case .sessionExpired:
            "小米登录已过期，请在「平台」里重新关联"
        case .qrExpired:
            "二维码已过期，请刷新后再试"
        }
    }
}

func humanize(_ error: Error) -> String {
    if let error = error as? XiaomiError {
        return error.localizedDescription
    }
    if let error = error as? CloudError {
        return error.localizedDescription
    }
    if error is CancellationError {
        return "已取消"
    }
    if let error = error as? URLError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "没有网络连接"
        case .timedOut:
            return "连接超时，请再试一次"
        case .cancelled:
            return "已取消"
        default:
            return "网络请求失败"
        }
    }
    return error.localizedDescription
}

func maskedAccount(_ raw: String, empty: String = "小米用户") -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let at = trimmed.firstIndex(of: "@") {
        let name = trimmed[..<at]
        let host = trimmed[at...]
        let keep = name.prefix(2)
        return "\(keep)***\(host)"
    }
    let digits = trimmed.filter(\.isNumber)
    if digits.count >= 7 {
        return "\(digits.prefix(3))****\(digits.suffix(4))"
    }
    return trimmed.isEmpty ? empty : trimmed
}
