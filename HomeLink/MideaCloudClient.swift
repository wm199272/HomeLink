import Foundation

enum MideaCloudClient {
    private static let api = "https://mp-prod.smartmidea.net/mas/v5/app/proxy?alias="
    private static let appKey = "46579c15"
    private static let loginKey = "ad0ee21d48a64bf49f4fb583ab76e799"
    private static let iotKey = "prod_secret123@muc"
    private static let hmacKey = "PROD_VnoClJI9aikS8dyy"
    private static let fixedKey = "96c7acdfdb8af79a"
    private static let appID = "900"
    private static let powerKeys: Set<String> = ["power", "powerstatus", "onoffstatus", "onoff", "poweron"]

    static func login(username: String, password: String) async throws -> (session: MideaSession, displayName: String) {
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, !password.isEmpty else {
            throw CloudError.failed("请填写美的美居的手机号和密码")
        }
        let deviceID = String(CloudCrypto.md5("Hello, \(account)!").prefix(16))
        let loginID = try await loginID(account: account)
        let iam = CloudCrypto.md5(CloudCrypto.md5(password))
        let passwordHash = CloudCrypto.sha256(loginID + CloudCrypto.sha256(password) + loginKey)
        let stamp = stampNow()
        let body = PyValue.object([
            ("iotData", .object([
                ("clientType", .int(1)),
                ("deviceId", .string(deviceID)),
                ("iampwd", .string(iam)),
                ("iotAppId", .string(appID)),
                ("loginAccount", .string(account)),
                ("password", .string(passwordHash)),
                ("reqId", .string(CloudCrypto.randomHex(bytes: 16))),
                ("stamp", .string(stamp)),
            ])),
            ("data", .object([
                ("appKey", .string(appKey)),
                ("deviceId", .string(deviceID)),
                ("platform", .int(2)),
            ])),
            ("timestamp", .string(stamp)),
            ("stamp", .string(stamp)),
            ("reqId", .string(CloudCrypto.randomHex(bytes: 16))),
        ]).dumped()
        let data = try await post(endpoint: "/mj/user/login", body: body, token: nil)
        let mdata = data["mdata"] as? [String: Any]
        guard let token = jsonString(mdata?["accessToken"]), !token.isEmpty else {
            throw CloudError.failed("美的美居没有返回登录会话")
        }
        return finishLogin(account: account, deviceID: deviceID, token: token, data: data)
    }

    static func fetchHomes(account: LinkedAccount) async throws -> [IoTHome] {
        guard let session = account.midea else { throw CloudError.sessionExpired("美的美居") }
        let listBody = PyValue.object([
            ("reqId", .string(CloudCrypto.randomHex(bytes: 16))),
            ("stamp", .string(stampNow())),
        ]).dumped()
        let listed = try await post(endpoint: "/v1/homegroup/list/get", body: listBody, token: session.accessToken)
        guard let homeRows = listed["homeList"] as? [Any] else {
            throw CloudError.failed("美的美居没有返回家庭列表")
        }
        var homes: [IoTHome] = []
        for row in homeRows {
            guard let home = row as? [String: Any] else { continue }
            guard let homeID = jsonInt(home["homegroupId"]) ?? jsonString(home["homegroupId"]).flatMap({ Int($0) }) else { continue }
            let homeName = jsonString(home["name"]) ?? jsonString(home["homeName"]) ?? "美的家庭"
            let applianceBody = PyValue.object([
                ("homegroupId", .int(homeID)),
                ("reqId", .string(CloudCrypto.randomHex(bytes: 16))),
                ("stamp", .string(stampNow())),
            ]).dumped()
            let appliances = try await post(
                endpoint: "/v1/appliance/home/list/get",
                body: applianceBody,
                token: session.accessToken
            )
            guard let applianceHomes = appliances["homeList"] as? [Any] else {
                throw CloudError.failed("美的美居没有返回这个家庭的设备")
            }
            var rooms: [String: [IoTDevice]] = [:]
            var order: [String] = []
            for homeNode in applianceHomes {
                guard let homeNode = homeNode as? [String: Any] else { continue }
                for roomNode in homeNode["roomList"] as? [Any] ?? [] {
                    guard let roomNode = roomNode as? [String: Any] else { continue }
                    let roomName = jsonString(roomNode["name"]) ?? jsonString(roomNode["roomName"]) ?? "未分区"
                    for item in roomNode["applianceList"] as? [Any] ?? [] {
                        guard let item = item as? [String: Any] else { continue }
                        guard let code = jsonString(item["applianceCode"]) ?? jsonInt(item["applianceCode"]).map(String.init), !code.isEmpty else { continue }
                        let name = jsonString(item["name"]) ?? "美的设备"
                        let model = jsonString(item["productModel"]) ?? jsonString(item["sn8"]) ?? ""
                        let kind = jsonString(item["category"]) ?? ""
                        let device = IoTDevice(
                            id: "\(account.id.uuidString):\(code)",
                            did: code,
                            name: name,
                            model: model,
                            online: isOnline(item["onlineStatus"]),
                            specType: nil,
                            localIP: nil,
                            roomName: roomName,
                            homeName: homeName,
                            homeId: "\(account.id.uuidString):\(homeID)",
                            accountId: account.id,
                            platform: .midea,
                            category: DeviceCategory.resolve(model: "\(model) \(name) \(kind)", specType: nil),
                            power: nil
                        )
                        if rooms[roomName] == nil { order.append(roomName) }
                        rooms[roomName, default: []].append(device)
                    }
                }
            }
            let builtRooms = order.map { name in
                IoTRoom(id: "\(account.id.uuidString):\(homeID):\(name)", name: name, devices: rooms[name] ?? [])
            }
            homes.append(IoTHome(
                id: "\(account.id.uuidString):\(homeID)",
                homeId: String(homeID),
                name: homeName,
                platform: .midea,
                accountId: account.id,
                rooms: builtRooms
            ))
        }
        return await attachPower(homes, session: session)
    }

    static func setPower(session: MideaSession, deviceID: String, specType: String, on: Bool) async throws {
        let parts = specType.split(separator: ":")
        guard parts.count == 3, parts[0] == "lua" else {
            throw CloudError.failed("这台美的设备还没有读到开关")
        }
        let key = String(parts[1])
        let value: PyValue
        switch String(parts[2]) {
        case "bool": value = .bool(on)
        case "digit": value = .int(on ? 1 : 0)
        default: value = .string(on ? "on" : "off")
        }
        let body = PyValue.object([
            ("applianceCode", .string(deviceID)),
            ("command", .object([
                ("control", .object([(key, value)])),
            ])),
            ("reqId", .string(CloudCrypto.randomHex(bytes: 16))),
            ("stamp", .string(stampNow())),
        ]).dumped()
        _ = try await post(endpoint: "/mjl/v1/device/lua/control", body: body, token: session.accessToken)
    }

    private static func finishLogin(
        account: String,
        deviceID: String,
        token: String,
        data: [String: Any]
    ) -> (session: MideaSession, displayName: String) {
        var aesKey: String?
        if let wrapped = jsonString(data["key"]),
           let decoded = try? CloudCrypto.aesECBDecryptText(hexCipher: wrapped, asciiKey: fixedKey),
           [16, 24, 32].contains(Data(decoded.utf8).count) {
            aesKey = decoded
        }
        let userInfo = data["userInfo"] as? [String: Any]
        let nickname = jsonString(userInfo?["nickName"])
        let session = MideaSession(account: account, accessToken: token, deviceID: deviceID, aesKey: aesKey)
        let display = nickname?.isEmpty == false ? nickname! : maskedAccount(account, empty: "美的用户")
        return (session, display)
    }

    private static func loginID(account: String) async throws -> String {
        let body = PyValue.object([
            ("loginAccount", .string(account)),
            ("type", .string("1")),
            ("reqId", .string(CloudCrypto.randomHex(bytes: 16))),
            ("stamp", .string(stampNow())),
        ]).dumped()
        let data = try await post(endpoint: "/v1/user/login/id/get", body: body, token: nil)
        guard let loginID = jsonString(data["loginId"]), !loginID.isEmpty else {
            throw CloudError.failed("美的美居没有返回登录凭证")
        }
        return loginID
    }

    private static func attachPower(_ homes: [IoTHome], session: MideaSession) async -> [IoTHome] {
        let devices = homes.flatMap(\.devices).filter(\.online)
        var found: [String: (PowerState, String)] = [:]
        await withTaskGroup(of: (String, PowerState, String)?.self) { group in
            for device in devices {
                group.addTask {
                    await readPower(session: session, deviceID: device.did)
                }
            }
            for await item in group {
                if let item { found[item.0] = (item.1, item.2) }
            }
        }
        return homes.map { home in
            var home = home
            home.rooms = home.rooms.map { room in
                var room = room
                room.devices = room.devices.map { device in
                    guard let power = found[device.did] else { return device }
                    var device = device
                    device.power = power.0
                    device.specType = power.1
                    return device
                }
                return room
            }
            return home
        }
    }

    private static func readPower(session: MideaSession, deviceID: String) async -> (String, PowerState, String)? {
        let body = PyValue.object([
            ("applianceCode", .string(deviceID)),
            ("command", .object([
                ("query", .object([])),
            ])),
            ("reqId", .string(CloudCrypto.randomHex(bytes: 16))),
            ("stamp", .string(stampNow())),
        ]).dumped()
        guard let data = try? await post(endpoint: "/mjl/v1/device/status/lua/get", body: body, token: session.accessToken),
              let power = findPower(data) else { return nil }
        return (deviceID, power.0, power.1)
    }

    private static func findPower(_ value: Any) -> (PowerState, String)? {
        if let dict = value as? [String: Any] {
            for (key, item) in dict where powerKeys.contains(key.lowercased()) {
                if let parsed = interpret(item) {
                    return (parsed.state, "lua:\(key):\(parsed.style)")
                }
            }
            for item in dict.values {
                if let found = findPower(item) { return found }
            }
        } else if let list = value as? [Any] {
            for item in list {
                if let found = findPower(item) { return found }
            }
        }
        return nil
    }

    private static func interpret(_ value: Any) -> (state: PowerState, style: String)? {
        if isJSONBool(value) {
            return ((value as! NSNumber).boolValue ? .on : .off, "bool")
        }
        if let number = jsonInt(value) {
            if number == 1 { return (.on, "digit") }
            if number == 0 { return (.off, "digit") }
        }
        if let text = jsonString(value)?.lowercased() {
            if ["on", "open", "true", "1"].contains(text) { return (.on, "onoff") }
            if ["off", "close", "false", "0"].contains(text) { return (.off, "onoff") }
        }
        return nil
    }

    private static func isOnline(_ value: Any?) -> Bool {
        if isJSONBool(value) { return (value as! NSNumber).boolValue }
        if let number = jsonInt(value) { return number == 1 }
        return jsonString(value) == "1" || jsonString(value)?.lowercased() == "true"
    }

    private static func post(endpoint: String, body: String, token: String?) async throws -> [String: Any] {
        guard let url = URL(string: api + endpoint) else { throw CloudError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let random = String(Int(Date().timeIntervalSince1970))
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "secretVersion")
        request.setValue(CloudCrypto.hmacSHA256(iotKey + body + random, key: hmacKey), forHTTPHeaderField: "sign")
        request.setValue(random, forHTTPHeaderField: "random")
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "accesstoken")
        }
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                throw CloudError.sessionExpired("美的美居")
            }
            throw CloudError.invalidResponse
        }
        let code = jsonInt(json["code"]) ?? -1
        let message = jsonString(json["msg"]) ?? jsonString(json["message"]) ?? ""
        if code == 40002 || code == 7400 || message.contains("token校验不通过") || tokenLooksMissing(message) {
            throw CloudError.sessionExpired("美的美居")
        }
        if code != 0 {
            throw CloudError.failed(message.isEmpty ? "美的美居没有完成这次请求" : message)
        }
        return json["data"] as? [String: Any] ?? [:]
    }

    private static func tokenLooksMissing(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("user token not exist") || (lower.contains("token") && lower.contains("not exist"))
    }

    private static func stampNow() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: Date())
    }
}

private enum PyValue {
    case object([(String, PyValue)])
    case string(String)
    case int(Int)
    case bool(Bool)

    func dumped() -> String {
        switch self {
        case let .object(pairs):
            let body = pairs.map { "\($0.0.pyQuoted()): \($0.1.dumped())" }.joined(separator: ", ")
            return "{\(body)}"
        case let .string(value):
            return value.pyQuoted()
        case let .int(value):
            return String(value)
        case let .bool(value):
            return value ? "true" : "false"
        }
    }
}

private extension String {
    func pyQuoted() -> String {
        var out = "\""
        for scalar in unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x20..<0x7F:
                out.unicodeScalars.append(scalar)
            default:
                if scalar.value < 0x10000 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    let value = scalar.value - 0x10000
                    let high = 0xD800 + (value >> 10)
                    let low = 0xDC00 + (value & 0x3FF)
                    out += String(format: "\\u%04x\\u%04x", high, low)
                }
            }
        }
        out += "\""
        return out
    }
}
