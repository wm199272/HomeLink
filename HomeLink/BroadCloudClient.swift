import Foundation

enum BroadCloudClient {
    private static let root = "https://broadair.remotcon.mobi"

    static func login(username: String, password: String) async throws -> (session: BroadSession, displayName: String) {
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, !password.isEmpty else {
            throw CloudError.failed("请填写远大空气管家的账号和密码")
        }
        let json = try await post(
            path: "/api/Account/Login",
            body: ["user_id": account, "pass_word": password],
            token: nil
        )
        let data = object(json, "Body", "Data")
        let token = jsonString(data?["token"]) ?? ""
        guard !token.isEmpty else {
            throw CloudError.failed(message(json) ?? "远大空气管家没有返回登录会话")
        }
        let userID = jsonString(data?["user_id"]) ?? account
        let name = jsonString(data?["user_name"])
        let session = BroadSession(userID: userID, token: token, username: account)
        let display = name?.isEmpty == false ? name! : maskedAccount(account, empty: "远大用户")
        return (session, display)
    }

    static func fetchHomes(account: LinkedAccount) async throws -> [IoTHome] {
        guard let session = account.broad else { throw CloudError.sessionExpired("远大空气管家") }
        let json = try await post(
            path: "/api/Equipment/GetEquipmentsList",
            body: [
                "user_id": session.userID,
                "pageIndex": "1",
                "pageSize": "100",
            ],
            token: session.token
        )
        let rows = dictionaries(in: (json["Body"] as? [String: Any])?["Data"] ?? json["Body"] ?? json)
        var devices: [IoTDevice] = []
        var seen = Set<String>()
        for item in rows {
            guard let deviceID = firstString(item, keys: ["eq_guid", "eqGuid", "guid", "eq_id", "id"]), !deviceID.isEmpty else { continue }
            guard seen.insert(deviceID).inserted else { continue }
            let name = firstString(item, keys: ["eq_name", "eqName", "name", "equipmentName"]) ?? firstString(item, keys: ["eq_model", "eqModel"]) ?? "远大设备"
            let model = firstString(item, keys: ["eq_model", "eqModel", "eqType", "eq_type"]) ?? ""
            devices.append(IoTDevice(
                id: "\(account.id.uuidString):\(deviceID)",
                did: deviceID,
                name: name,
                model: model,
                online: !isOffline(item["eqStatus"] ?? item["status"] ?? item["online"]),
                specType: nil,
                localIP: nil,
                roomName: "设备",
                homeName: "远大空气管家",
                homeId: account.id.uuidString,
                accountId: account.id,
                platform: .broad,
                category: DeviceCategory.resolve(model: "\(model) \(name) purifier", specType: nil),
                power: nil
            ))
        }
        let room = IoTRoom(id: "\(account.id.uuidString):equipment", name: "设备", devices: devices)
        return [IoTHome(
            id: account.id.uuidString,
            homeId: account.id.uuidString,
            name: "远大空气管家",
            platform: .broad,
            accountId: account.id,
            rooms: devices.isEmpty ? [] : [room]
        )]
    }

    private static func post(path: String, body: [String: Any], token: String?) async throws -> [String: Any] {
        guard let url = URL(string: root + path) else { throw CloudError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "token")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.invalidResponse
        }
        let head = json["Head"] as? [String: Any]
        let code = jsonInt(head?["Code"])
        let text = message(json) ?? ""
        if code == nil || code == 0 || code == 1 || code == 200 {
            return json
        }
        if !path.contains("Login"), code == 401 || text.contains("登录") || text.contains("过期") || text.lowercased().contains("token") {
            throw CloudError.sessionExpired("远大空气管家")
        }
        throw CloudError.failed(text.isEmpty ? "远大空气管家没有完成这次请求" : text)
    }

    private static func message(_ json: [String: Any]) -> String? {
        let head = json["Head"] as? [String: Any]
        let data = object(json, "Body", "Data")
        let text = jsonString(head?["Msg"]) ?? jsonString(data?["ERROR_MSG"])
        return text?.isEmpty == false ? text : nil
    }

    private static func object(_ json: [String: Any], _ first: String, _ second: String) -> [String: Any]? {
        let node = json[first] as? [String: Any]
        return node?[second] as? [String: Any]
    }

    private static func dictionaries(in value: Any) -> [[String: Any]] {
        if let text = value as? String, let data = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            return dictionaries(in: parsed)
        }
        if let list = value as? [Any] {
            return list.flatMap { dictionaries(in: $0) }
        }
        guard let dict = value as? [String: Any] else { return [] }
        if firstString(dict, keys: ["eq_guid", "eqGuid", "guid", "eq_id"]) != nil {
            return [dict]
        }
        var found: [[String: Any]] = []
        for key in ["Data", "data", "list", "List", "rows", "items", "equiment", "equipment", "Body"] {
            if let child = dict[key] {
                found.append(contentsOf: dictionaries(in: child))
            }
        }
        return found
    }

    private static func firstString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let text = jsonString(dict[key]), !text.isEmpty { return text }
        }
        return nil
    }

    private static func isOffline(_ value: Any?) -> Bool {
        let text = jsonString(value)?.lowercased() ?? ""
        if text.isEmpty { return false }
        return text.contains("离线") || text == "0" || text == "offline" || text == "false"
    }
}
