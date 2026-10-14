import Foundation

enum DeyeCloudClient {
    private static let endpoint = "https://api.deye.com.cn/v3/enduser"
    private static let appID = "a774310e-a430-11e7-9d4c-00163e0c1b21"
    private static let extend = "{\"cid\":\"63d5b0df098443db906f857003f29d12\",\"type\":\"1\"}"

    static func login(username: String, password: String) async throws -> DeyeSession {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try await send(
            path: "login/",
            method: "POST",
            token: nil,
            json: [
                "appid": appID,
                "extend": extend,
                "pushtype": "Ali",
                "loginname": name,
                "password": password,
            ]
        )
        guard let token = jsonString((data["data"] as? [String: Any])?["token"]), !token.isEmpty else {
            throw CloudError.failed("德业登录没有返回会话")
        }
        return DeyeSession(token: token, username: name, userId: jwtString(token, "enduserid"))
    }

    static func fetchHomes(account: LinkedAccount) async throws -> (homes: [IoTHome], token: String) {
        guard let session = account.deye else { throw CloudError.sessionExpired("德业智能") }
        let token = try await freshToken(session.token)
        let data = try await send(path: "deviceList/?app=new", method: "GET", token: token, json: nil)
        let rows = deviceRows(data["data"])
        var buckets: [String: [IoTDevice]] = [:]
        for row in rows {
            var device = makeDevice(account: account, row: row)
            if device.specType == "fog" {
                if let climate = try? await readClimate(token: token, deviceID: device.did) {
                    device.power = climate.power ? .on : .off
                }
            }
            buckets[device.roomName, default: []].append(device)
        }
        let rooms = buckets.keys.sorted().map { name in
            IoTRoom(
                id: "\(account.id.uuidString)|deye|\(name)",
                name: name,
                devices: buckets[name, default: []].sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            )
        }
        let home = IoTHome(
            id: "\(account.id.uuidString)|deye|home",
            homeId: "deye",
            name: "德业智能",
            platform: .deye,
            accountId: account.id,
            rooms: rooms.isEmpty ? [IoTRoom(id: "\(account.id.uuidString)|deye|all", name: "全部设备", devices: [])] : rooms
        )
        return ([home], token)
    }

    static func renew(_ session: DeyeSession) async throws -> DeyeSession {
        var copy = session
        copy.token = try await freshToken(session.token)
        copy.userId = jwtString(copy.token, "enduserid") ?? session.userId
        return copy
    }

    static func readClimate(session: DeyeSession, deviceID: String) async throws -> DeyeClimate {
        let token = try await freshToken(session.token)
        return try await readClimate(token: token, deviceID: deviceID)
    }

    static func write(
        session: DeyeSession,
        deviceID: String,
        power: Bool?,
        mode: Int?,
        humidity: Int?,
        fan: Int?
    ) async throws {
        var params: [String: Int] = [:]
        if let power { params["Power"] = power ? 1 : 0 }
        if let mode { params["Mode"] = mode }
        if let humidity { params["SetHumidity"] = humidity }
        if let fan { params["WindSpeed"] = fan }
        guard !params.isEmpty else { return }
        let token = try await freshToken(session.token)
        _ = try await send(
            path: "set/properties/",
            method: "POST",
            token: token,
            json: ["device_id": deviceID, "params": params]
        )
    }

    private static func readClimate(token: String, deviceID: String) async throws -> DeyeClimate {
        let random = String(Double.random(in: 0...1))
        let data = try await send(
            path: "get/properties/?device_id=\(deviceID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceID)&random=\(random)",
            method: "GET",
            token: token,
            json: nil
        )
        let props = ((data["data"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
        return DeyeClimate(
            power: (jsonInt(props["Power"]) ?? 0) != 0,
            mode: jsonInt(props["Mode"]) ?? 0,
            humidity: jsonInt(props["SetHumidity"]) ?? 60,
            fan: jsonInt(props["WindSpeed"]) ?? 1,
            ambientHumidity: jsonInt(props["CurrentEnvironmentalHumidity"]),
            supportsControl: true
        )
    }

    private static func freshToken(_ token: String) async throws -> String {
        if let exp = jwtNumber(token, "exp"), exp - Date().timeIntervalSince1970 > 24 * 60 * 60 {
            return token
        }
        let data = try await send(path: "refreshToken/", method: "POST", token: nil, json: ["token": token])
        guard let next = jsonString((data["data"] as? [String: Any])?["token"]), !next.isEmpty else {
            throw CloudError.sessionExpired("德业智能")
        }
        return next
    }

    private static func send(path: String, method: String, token: String?, json: [String: Any]?) async throws -> [String: Any] {
        guard let url = URL(string: endpoint + "/" + path) else { throw CloudError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("JWT \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CloudError.failed("德业服务器暂时没有响应")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.invalidResponse
        }
        let meta = object["meta"] as? [String: Any]
        let code = jsonInt(meta?["code"]) ?? -1
        if code != 0 {
            let message = jsonString(meta?["message"]) ?? "德业请求失败（\(code)）"
            if code == 10001 || message.localizedCaseInsensitiveContains("jwt") || message.localizedCaseInsensitiveContains("token") {
                throw CloudError.sessionExpired("德业智能")
            }
            throw CloudError.failed(message)
        }
        return object
    }

    private static func deviceRows(_ data: Any?) -> [[String: Any]] {
        if let rows = data as? [Any] {
            return rows.compactMap { $0 as? [String: Any] }
        }
        if let bag = data as? [String: Any], let rows = bag["list"] as? [Any] {
            return rows.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    private static func makeDevice(account: LinkedAccount, row: [String: Any]) -> IoTDevice {
        let deviceID = jsonString(row["device_id"]) ?? jsonString(row["deviceid"]) ?? UUID().uuidString
        let product = jsonString(row["product_name"]) ?? ""
        let alias = (jsonString(row["alias"]) ?? jsonString(row["device_name"]) ?? product).trimmingCharacters(in: .whitespaces)
        let kind = jsonString(row["product_type"]) ?? ""
        let platform = jsonInt(row["platform"]) ?? 0
        let combo = (row["is_combo"] as? Bool ?? false) && jsonString(row["protocol_version"]) == "combo_V1.0"
        let fog = platform == 2 || platform == 3
        let spec = fog ? "fog" : (combo ? "combo" : "classic")
        var category = DeviceCategory.resolve(model: product + " " + kind, specType: nil)
        if category == .other, kind.contains("dehumid") || product.localizedCaseInsensitiveContains("除湿") {
            category = .humidifier
        }
        return IoTDevice(
            id: "\(account.id.uuidString)|deye|\(deviceID)",
            did: deviceID,
            name: alias.isEmpty ? (product.isEmpty ? "德业设备" : product) : alias,
            model: product,
            online: onlineFlag(row["online"]),
            specType: spec,
            localIP: nil,
            roomName: roomName(kind),
            homeName: "德业智能",
            homeId: "deye",
            accountId: account.id,
            platform: .deye,
            category: category,
            power: nil
        )
    }

    private static func roomName(_ kind: String) -> String {
        let value = kind.lowercased()
        if value.contains("dehumid") { return "除湿机" }
        if value.contains("air") { return "空调" }
        if value.contains("humid") { return "加湿器" }
        return "全部设备"
    }

    private static func onlineFlag(_ value: Any?) -> Bool {
        if isJSONBool(value) { return (value as? NSNumber)?.boolValue ?? false }
        if let number = jsonInt(value) { return number != 0 }
        if let text = jsonString(value) { return text == "1" || text == "true" }
        return false
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var text = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private static func jwtString(_ token: String, _ key: String) -> String? {
        jsonString(jwtPayload(token)?[key])
    }

    private static func jwtNumber(_ token: String, _ key: String) -> TimeInterval? {
        if let number = jwtPayload(token)?[key] as? NSNumber { return number.doubleValue }
        return nil
    }
}
