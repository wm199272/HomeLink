import Foundation

enum HaierCloudClient {
    private static let appID = "MB-UZHSH-0001"
    private static let appKey = "5dfca8714eb26e3a776e58a8273c8752"
    private static let loginURL = URL(string: "https://zj.haier.net/oauthserver/account/v1/login")!
    private static let refreshURL = URL(string: "https://zj.haier.net/api-gw/oauthserver/account/v1/refreshToken")!
    private static let userURL = URL(string: "https://account-api.haier.net/v2/haier/userinfo")!
    private static let devicesURL = URL(string: "https://uws.haier.net/uds/v1/protected/deviceinfos")!

    static func login(username: String, password: String) async throws -> (session: HaierSession, displayName: String) {
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, !password.isEmpty else {
            throw CloudError.failed("请填写海尔智家的账号和密码")
        }
        let clientID = UUID().uuidString
        let body = "{\"username\":\"\(escaped(account))\",\"password\":\"\(escaped(password))\",\"phoneType\":\"iPhone16,2\"}"
        let json = try await send(
            url: loginURL,
            method: "POST",
            body: body,
            token: nil,
            clientID: clientID,
            signBody: body
        )
        let token = try parseToken(json)
        let profile = await userProfile(token: token.token)
        let session = HaierSession(
            clientID: clientID,
            token: token.token,
            refreshToken: token.refresh,
            expiresAt: token.expiresAt,
            userID: profile.userID,
            username: account
        )
        let display = profile.mobile.isEmpty ? maskedAccount(account, empty: "海尔用户") : maskedAccount(profile.mobile, empty: "海尔用户")
        return (session, display)
    }

    static func fetchHomes(account: LinkedAccount) async throws -> (homes: [IoTHome], session: HaierSession) {
        guard var session = account.haier else { throw CloudError.sessionExpired("海尔智家") }
        session = try await renewIfNeeded(session)
        let json = try await send(
            url: devicesURL,
            method: "GET",
            body: nil,
            token: session.token,
            clientID: session.clientID,
            signBody: ""
        )
        guard let rows = json["deviceinfos"] as? [Any] else {
            throw CloudError.invalidResponse
        }
        var groups: [String: [String: [IoTDevice]]] = [:]
        var homeOrder: [String] = []
        var roomOrder: [String: [String]] = [:]
        for row in rows {
            guard let item = row as? [String: Any] else { continue }
            guard let deviceID = jsonString(item["deviceId"]), !deviceID.isEmpty else { continue }
            let homeName = jsonString(item["familyName"]) ?? jsonString(item["family"]) ?? "海尔智家"
            let roomName = jsonString(item["roomName"]) ?? jsonString(item["room"]) ?? "全部设备"
            let name = jsonString(item["deviceName"]) ?? deviceID
            let model = jsonString(item["productNameT"]) ?? jsonString(item["productCodeT"]) ?? jsonString(item["deviceType"]) ?? ""
            let device = IoTDevice(
                id: "\(account.id.uuidString):\(deviceID)",
                did: deviceID,
                name: name,
                model: model,
                online: isOnline(item["online"] ?? item["isOnline"] ?? item["onlineStatus"]),
                specType: nil,
                localIP: nil,
                roomName: roomName,
                homeName: homeName,
                homeId: "\(account.id.uuidString):\(homeName)",
                accountId: account.id,
                platform: .haier,
                category: DeviceCategory.resolve(model: "\(model) \(name)", specType: nil),
                power: nil
            )
            if groups[homeName] == nil { homeOrder.append(homeName) }
            if groups[homeName]?[roomName] == nil {
                roomOrder[homeName, default: []].append(roomName)
            }
            groups[homeName, default: [:]][roomName, default: []].append(device)
        }
        let homes = homeOrder.map { homeName in
            let rooms = (roomOrder[homeName] ?? []).map { roomName in
                IoTRoom(
                    id: "\(account.id.uuidString):\(homeName):\(roomName)",
                    name: roomName,
                    devices: groups[homeName]?[roomName] ?? []
                )
            }
            return IoTHome(
                id: "\(account.id.uuidString):\(homeName)",
                homeId: homeName,
                name: homeName,
                platform: .haier,
                accountId: account.id,
                rooms: rooms
            )
        }
        return (homes, session)
    }

    private static func renewIfNeeded(_ session: HaierSession) async throws -> HaierSession {
        let now = Int(Date().timeIntervalSince1970)
        guard session.expiresAt - now < 3600 else { return session }
        let compact = "{\"refreshToken\":\"\(escaped(session.refreshToken))\"}"
        let spaced = "{\"refreshToken\": \"\(escaped(session.refreshToken))\"}"
        let json = try await send(
            url: refreshURL,
            method: "POST",
            body: spaced,
            token: session.token,
            clientID: session.clientID,
            signBody: compact
        )
        let token = try parseToken(json)
        var next = session
        next.token = token.token
        next.refreshToken = token.refresh
        next.expiresAt = token.expiresAt
        return next
    }

    private static func userProfile(token: String) async -> (userID: String, mobile: String) {
        var request = URLRequest(url: userURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["error_description"] == nil else {
            return ("", "")
        }
        return (jsonString(json["userId"]) ?? "", jsonString(json["mobile"]) ?? "")
    }

    private static func send(
        url: URL,
        method: String,
        body: String?,
        token: String?,
        clientID: String,
        signBody: String
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let sequence = sequenceID()
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "accessToken")
        }
        request.setValue(appID, forHTTPHeaderField: "appId")
        request.setValue(appKey, forHTTPHeaderField: "appKey")
        request.setValue(clientID, forHTTPHeaderField: "clientId")
        request.setValue(sequence, forHTTPHeaderField: "sequenceId")
        request.setValue(timestamp, forHTTPHeaderField: "timestamp")
        request.setValue("+8", forHTTPHeaderField: "timezone")
        request.setValue("zh-CN", forHTTPHeaderField: "language")
        request.setValue(
            CloudCrypto.sha256(url.path + signBody + appID + appKey + timestamp),
            forHTTPHeaderField: "sign"
        )
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body!.utf8)
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.invalidResponse
        }
        if let code = jsonString(json["retCode"]), code != "00000" {
            let info = jsonString(json["retInfo"]) ?? "海尔智家没有完成这次请求"
            if code == "43005" || info.contains("登录") || info.contains("token") || info.contains("过期") {
                throw CloudError.sessionExpired("海尔智家")
            }
            throw CloudError.failed(info)
        }
        return json
    }

    private static func parseToken(_ json: [String: Any]) throws -> (token: String, refresh: String, expiresAt: Int) {
        let data = json["data"] as? [String: Any]
        let info = data?["tokenInfo"] as? [String: Any]
        guard let token = jsonString(info?["accountToken"]), !token.isEmpty,
              let refresh = jsonString(info?["refreshToken"]), !refresh.isEmpty else {
            throw CloudError.failed(jsonString(json["retInfo"]) ?? "海尔智家没有返回登录会话")
        }
        let expiresIn = jsonInt(info?["expiresIn"]) ?? 0
        let now = Int(Date().timeIntervalSince1970)
        let expiresAt = expiresIn > 1_000_000_000 ? expiresIn : now + max(expiresIn, 0)
        return (token, refresh, expiresAt)
    }

    private static func isOnline(_ value: Any?) -> Bool {
        if value == nil || value is NSNull { return true }
        if isJSONBool(value) { return (value as! NSNumber).boolValue }
        if let number = jsonInt(value) { return number != 0 }
        let text = jsonString(value)?.lowercased() ?? ""
        return text == "true" || text == "1" || text == "online" || text == "在线"
    }

    private static func sequenceID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: Date()) + String(format: "%06d", Int.random(in: 0...999999))
    }

    private static func escaped(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case ..<0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
