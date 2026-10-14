import Foundation
import HomeKit

struct HKTrait: Identifiable, Sendable {
    var id: String
    var title: String
    var isToggle: Bool
    var isOn: Bool
    var text: String
    var characteristicID: UUID
}

@MainActor
final class HomeKitBridge: NSObject, HMHomeManagerDelegate {
    var onUpdate: (@MainActor () -> Void)?
    private let manager: HMHomeManager

    override init() {
        let created = HMHomeManager()
        manager = created
        super.init()
        created.delegate = self
    }

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in
            self.onUpdate?()
        }
    }

    var isAuthorized: Bool {
        manager.authorizationStatus.contains(.authorized)
    }

    var statusText: String {
        let status = manager.authorizationStatus
        if status.contains(.authorized) {
            return "已允许访问家庭"
        }
        if status.contains(.restricted) {
            return "系统没有开放家庭数据。用付费开发者账号在 Xcode 里打开 HomeKit 能力后再试。"
        }
        return "正在请求家庭权限"
    }

    func makeHomes(accountId: UUID) -> [IoTHome] {
        manager.homes.map { home in
            var buckets: [String: [IoTDevice]] = [:]
            var order: [String] = []
            for accessory in home.accessories {
                let roomName = accessory.room?.name ?? "未分配房间"
                if buckets[roomName] == nil {
                    order.append(roomName)
                }
                let power = powerValue(of: accessory)
                let device = IoTDevice(
                    id: "\(accountId.uuidString)|homekit|\(accessory.uniqueIdentifier.uuidString)",
                    did: accessory.uniqueIdentifier.uuidString,
                    name: accessory.name,
                    model: modelName(of: accessory),
                    online: accessory.isReachable,
                    specType: nil,
                    localIP: nil,
                    roomName: roomName,
                    homeName: home.name,
                    homeId: home.uniqueIdentifier.uuidString,
                    accountId: accountId,
                    platform: .homekit,
                    category: category(of: accessory),
                    power: power
                )
                buckets[roomName, default: []].append(device)
            }
            let rooms = order.map { name in
                IoTRoom(
                    id: "\(accountId.uuidString)|\(home.uniqueIdentifier.uuidString)|\(name)",
                    name: name,
                    devices: (buckets[name] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                )
            }
            let finalRooms = rooms.isEmpty
                ? [IoTRoom(id: "\(home.uniqueIdentifier.uuidString)|empty", name: "全部设备", devices: [])]
                : rooms
            return IoTHome(
                id: "\(accountId.uuidString)|homekit|\(home.uniqueIdentifier.uuidString)",
                homeId: home.uniqueIdentifier.uuidString,
                name: home.name,
                platform: .homekit,
                accountId: accountId,
                rooms: finalRooms
            )
        }
    }

    func setPower(id: String, on: Bool) async throws {
        guard let characteristic = powerCharacteristic(id: id) else {
            throw XiaomiError.failed("这个家庭设备没有开关")
        }
        try await write(characteristic, value: NSNumber(value: on))
    }

    func setBool(accessoryID: String, characteristicID: UUID, on: Bool) async throws {
        guard let characteristic = find(accessoryID)?.services
            .flatMap(\.characteristics)
            .first(where: { $0.uniqueIdentifier == characteristicID }) else {
            throw XiaomiError.failed("没有找到这个控制项")
        }
        try await write(characteristic, value: NSNumber(value: on))
    }

    func traits(for accessoryID: String) async -> [HKTrait] {
        guard let accessory = find(accessoryID) else { return [] }
        var output: [HKTrait] = []
        for service in accessory.services {
            for characteristic in service.characteristics {
                if characteristic.characteristicType == HMCharacteristicTypeIdentify { continue }
                let readable = characteristic.properties.contains(HMCharacteristicPropertyReadable)
                let writable = characteristic.properties.contains(HMCharacteristicPropertyWritable)
                if readable {
                    await read(characteristic)
                }
                let isBool = characteristic.metadata?.format == HMCharacteristicMetadataFormatBool
                let title = Self.title(for: characteristic)
                if isBool && writable {
                    let isOn = (characteristic.value as? NSNumber)?.boolValue ?? false
                    output.append(HKTrait(
                        id: characteristic.uniqueIdentifier.uuidString,
                        title: title,
                        isToggle: true,
                        isOn: isOn,
                        text: "",
                        characteristicID: characteristic.uniqueIdentifier
                    ))
                } else if let text = Self.describe(characteristic), !text.isEmpty {
                    output.append(HKTrait(
                        id: characteristic.uniqueIdentifier.uuidString,
                        title: title,
                        isToggle: false,
                        isOn: false,
                        text: text,
                        characteristicID: characteristic.uniqueIdentifier
                    ))
                }
            }
        }
        return output
    }

    private func modelName(of accessory: HMAccessory) -> String {
        for service in accessory.services {
            if let characteristic = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeModel }),
               let text = characteristic.value as? String, !text.isEmpty {
                return text
            }
        }
        return ""
    }

    private func find(_ id: String) -> HMAccessory? {
        for home in manager.homes {
            if let accessory = home.accessories.first(where: { $0.uniqueIdentifier.uuidString == id }) {
                return accessory
            }
        }
        return nil
    }

    private func powerCharacteristic(id: String) -> HMCharacteristic? {
        guard let accessory = find(id) else { return nil }
        for service in accessory.services {
            if let characteristic = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypePowerState }) {
                return characteristic
            }
        }
        return nil
    }

    private func powerValue(of accessory: HMAccessory) -> PowerState? {
        for service in accessory.services {
            guard let characteristic = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypePowerState }) else {
                continue
            }
            guard characteristic.properties.contains(HMCharacteristicPropertyWritable) else { return .unavailable }
            let on = (characteristic.value as? NSNumber)?.boolValue ?? false
            return on ? .on : .off
        }
        return nil
    }

    private func category(of accessory: HMAccessory) -> DeviceCategory {
        let type = accessory.category.categoryType
        if #available(iOS 18.0, *), type == HMAccessoryCategoryTypeSpeaker {
            return .speaker
        }
        switch type {
        case HMAccessoryCategoryTypeLightbulb:
            return .light
        case HMAccessoryCategoryTypeOutlet, HMAccessoryCategoryTypeSwitch:
            return .outlet
        case HMAccessoryCategoryTypeFan:
            return .fan
        case HMAccessoryCategoryTypeAirConditioner, HMAccessoryCategoryTypeThermostat, HMAccessoryCategoryTypeAirHeater:
            return .airConditioner
        case HMAccessoryCategoryTypeAirPurifier:
            return .purifier
        case HMAccessoryCategoryTypeWindowCovering, HMAccessoryCategoryTypeWindow:
            return .curtain
        case HMAccessoryCategoryTypeDoorLock:
            return .lock
        case HMAccessoryCategoryTypeSensor:
            return .sensor
        default:
            return .other
        }
    }

    private func read(_ characteristic: HMCharacteristic) async {
        guard characteristic.properties.contains(HMCharacteristicPropertyReadable) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            characteristic.readValue { _ in
                continuation.resume()
            }
        }
    }

    private func write(_ characteristic: HMCharacteristic, value: Any) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristic.writeValue(value) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func title(for characteristic: HMCharacteristic) -> String {
        switch characteristic.characteristicType {
        case HMCharacteristicTypePowerState: "开关"
        case HMCharacteristicTypeBrightness: "亮度"
        case HMCharacteristicTypeHue: "色相"
        case HMCharacteristicTypeSaturation: "饱和度"
        case HMCharacteristicTypeColorTemperature: "色温"
        case HMCharacteristicTypeCurrentTemperature: "当前温度"
        case HMCharacteristicTypeTargetTemperature: "目标温度"
        case HMCharacteristicTypeCurrentRelativeHumidity: "湿度"
        case HMCharacteristicTypeTargetRelativeHumidity: "目标湿度"
        case HMCharacteristicTypeBatteryLevel: "电量"
        case HMCharacteristicTypeChargingState: "充电"
        case HMCharacteristicTypeOutletInUse: "使用中"
        case HMCharacteristicTypeRotationSpeed: "转速"
        case HMCharacteristicTypeCurrentPosition: "当前位置"
        case HMCharacteristicTypeTargetPosition: "目标位置"
        case HMCharacteristicTypePositionState: "运动状态"
        default: characteristic.localizedDescription
        }
    }

    private static func describe(_ characteristic: HMCharacteristic) -> String? {
        guard let value = characteristic.value else { return nil }
        if let number = value as? NSNumber {
            if characteristic.metadata?.format == HMCharacteristicMetadataFormatBool {
                return number.boolValue ? "开" : "关"
            }
            let numberText = number.doubleValue.rounded() == number.doubleValue
                ? String(number.intValue)
                : String(format: "%.1f", number.doubleValue)
            if let unit = characteristic.metadata?.units {
                return numberText + " " + unit
            }
            return numberText
        }
        if let text = value as? String, !text.isEmpty {
            return text
        }
        return nil
    }
}
