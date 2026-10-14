import Foundation

enum MaiCloudClient {
    private static let base = "https://eu-api.70mai.com"
    private static let channel = 3001013
    private static let secret = "0c5269735ed4b129"
    private static let userAgent = "70%E8%BF%88/46 CFNetwork/3860.700.1 Darwin/25.6.0"

    static func login(username: String, password: String) async throws -> (session: MaiSession, displayName: String) {
        let email = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            throw CloudError.failed("请填写 70 迈的账号和密码")
        }
        let uuid = UUID().uuidString
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let passwordHash = CloudCrypto.md5("dashcam\(password)\(secret)")
        let sig = CloudCrypto.md5("3\(email)null\(passwordHash)\(ts)\(secret)")
        let body: [String: Any] = [
            "email": email,
            "ts": ts,
            "passWord": passwordHash,
            "channel": channel,
            "uuid": uuid,
            "deviceType": 3,
            "sig": sig,
        ]
        let json = try await post(path: "/accountApi/V3/userLoginPwd", body: body)
        let result = json["resultBodyObject"] as? [String: Any]
        guard let token = jsonString(result?["token"]), !token.isEmpty else {
            throw CloudError.failed(errorText(json) ?? "70 迈没有返回登录会话")
        }
        let session = MaiSession(
            email: email,
            uuid: uuid,
            token: token,
            userID: jsonString(result?["userID"]) ?? jsonInt(result?["userID"]).map(String.init)
        )
        let name = jsonString(result?["userName"])
        let display = name?.isEmpty == false ? name! : maskedAccount(email, empty: "70迈用户")
        return (session, display)
    }

    static func fetchHomes(account: LinkedAccount) async throws -> [IoTHome] {
        guard let session = account.mai else { throw CloudError.sessionExpired("70 迈") }
        var devices: [IoTDevice] = []
        var seen = Set<String>()
        var cursor: Any = NSNull()
        for _ in 0..<6 {
            let page = try await devicePage(session: session, cursor: cursor)
            if page.isEmpty { break }
            var oldest: Int?
            var added = 0
            for item in page {
                guard let deviceID = jsonString(item["deviceId"]), !deviceID.isEmpty else { continue }
                if let bind = jsonInt(item["bindTime"]) {
                    oldest = min(oldest ?? bind, bind)
                }
                guard seen.insert(deviceID).inserted else { continue }
                added += 1
                let nickname = jsonString(item["nickName"])
                let ssid = jsonString(item["ssid"])
                let name = (nickname?.isEmpty == false ? nickname : nil) ?? (ssid?.isEmpty == false ? ssid : nil) ?? "70迈记录仪"
                let type = jsonInt(item["type"]).map(String.init) ?? ""
                devices.append(IoTDevice(
                    id: "\(account.id.uuidString):\(deviceID)",
                    did: deviceID,
                    name: name,
                    model: type.isEmpty ? "70mai" : "70mai \(type)",
                    online: true,
                    specType: "dashcam",
                    localIP: nil,
                    roomName: "记录仪",
                    homeName: "70 迈",
                    homeId: account.id.uuidString,
                    accountId: account.id,
                    platform: .mai,
                    category: .camera,
                    power: nil
                ))
            }
            if added == 0 || page.count < 50 { break }
            guard let oldest else { break }
            cursor = oldest
        }
        let room = IoTRoom(id: "\(account.id.uuidString):dashcam", name: "记录仪", devices: devices)
        return [IoTHome(
            id: account.id.uuidString,
            homeId: account.id.uuidString,
            name: "70 迈",
            platform: .mai,
            accountId: account.id,
            rooms: devices.isEmpty ? [] : [room]
        )]
    }

    private static func devicePage(session: MaiSession, cursor: Any) async throws -> [[String: Any]] {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let sig = CloudCrypto.md5("\(session.token)\(session.uuid)\(channel)\(ts)\(secret)")
        var body: [String: Any] = [
            "uuid": session.uuid,
            "channel": channel,
            "ts": ts,
            "token": session.token,
            "lastBindTime": cursor,
            "pageCount": 50,
            "sig": sig,
        ]
        if cursor is NSNull {
            body["lastBindTime"] = NSNull()
        }
        let json = try await post(path: "/accountApi/V3/getAllDeviceForUser", body: body)
        if let list = json["resultBodyObject"] as? [Any] {
            return list.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    private static func post(path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: base + path) else { throw CloudError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json;application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("UTF-8", forHTTPHeaderField: "Charset")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.invalidResponse
        }
        let failed = isJSONBool(json["error"]) && (json["error"] as! NSNumber).boolValue
        if failed || jsonInt(json["errorCode"]) == 500001 {
            let text = errorText(json) ?? "70 迈没有完成这次请求"
            if jsonInt(json["errorCode"]) == 500001 || text.contains("token") {
                throw CloudError.sessionExpired("70 迈")
            }
            throw CloudError.failed(text)
        }
        return json
    }

    private static func errorText(_ json: [String: Any]) -> String? {
        let text = jsonString(json["errorMessage"]) ?? jsonString(json["message"])
        return text?.isEmpty == false ? text : nil
    }
}
