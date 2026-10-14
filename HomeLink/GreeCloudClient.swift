import CryptoKit
import Foundation

enum GreeCloudClient {
    private static let appID = "4920681951525131286"
    private static let appHash = "0fa513124aa97781d1f3f40d61ca1a89"
    private static let aesKey = Data("#G$&^jgfujy6ujxt".utf8)
    private static let gcmNonce = Data([0x54, 0x40, 0x78, 0x44, 0x49, 0x67, 0x5A, 0x51, 0x6C, 0x5E, 0x63, 0x13])
    private static let gcmAAD = Data("qualcomm-test".utf8)

    static func login(region: GreeRegion, username: String, password: String) async throws -> GreeSession {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let stamp = utcStamp(now)
        let hashed = XiaomiCrypto.md5Lower(XiaomiCrypto.md5Lower(password) + password)
        let psw = XiaomiCrypto.md5Lower(hashed + stamp)
        let body: [String: Any] = [
            "psw": psw,
            "t": stamp,
            "user": user,
        ]
        let data = try await post(host: region.host, path: "/App/UserLoginV2", payload: body, hashKeys: ["user", "psw", "t"], now: now)
        if let error = failure(data, name: "格力+") { throw error }
        let bag = (data["data"] as? [String: Any]) ?? data
        guard let userId = idText(bag["uid"]) ?? idText(data["uid"]),
              let token = jsonString(bag["token"]) ?? jsonString(data["token"]),
              !token.isEmpty else {
            throw CloudError.failed(jsonString(data["msg"]) ?? "格力登录没有返回会话")
        }
        return GreeSession(
            userId: userId,
            token: token,
            host: region.host,
            mqttHost: region.mqttHost,
            username: user,
            deviceKeys: [:]
        )
    }

    static func fetchHomes(account: LinkedAccount) async throws -> (homes: [IoTHome], keys: [String: String]) {
        guard let session = account.gree else { throw CloudError.sessionExpired("格力+") }
        let homesData = try await post(
            host: session.host,
            path: "/App/GetHomes",
            payload: ["token": session.token, "uid": uidNumber(session.userId)],
            hashKeys: ["token", "uid"]
        )
        if let error = failure(homesData, name: "格力+") { throw error }
        let homeRows = (homesData["home"] as? [Any]) ?? (homesData["homes"] as? [Any]) ?? []
        var keys: [String: String] = [:]
        var homes: [IoTHome] = []
        if homeRows.isEmpty {
            homes.append(emptyHome(account: account, homeId: "gree", name: "格力+"))
            return (homes, keys)
        }
        for row in homeRows {
            guard let home = row as? [String: Any] else { continue }
            let homeId = idText(home["id"]) ?? idText(home["homeId"]) ?? "gree"
            let homeName = (jsonString(home["name"]) ?? jsonString(home["homeName"]) ?? "格力+").trimmingCharacters(in: .whitespaces)
            var homeValue: Any = homeId
            if let raw = home["id"] ?? home["homeId"], !(raw is NSNull) {
                homeValue = raw
            }
            let devicesData = try await post(
                host: session.host,
                path: "/App/GetDevsInRoomsOfHomeV2",
                payload: ["token": session.token, "homeId": homeValue, "uid": uidNumber(session.userId)],
                hashKeys: ["token", "uid", "homeId"]
            )
            if let error = failure(devicesData, name: "格力+") { throw error }
            let built = devices(account: account, homeId: homeId, homeName: homeName.isEmpty ? "格力+" : homeName, data: devicesData)
            for pair in built.keys { keys[pair.key] = pair.value }
            homes.append(built.home)
        }
        // 暂时跳过 MQTT 读取开关状态：格力云端 MQTT 通道在部分网络上会触发崩溃，
        // 先用 nil 开关状态保证关联和浏览不闪退，后续再单独排查 MQTT。
        _ = keys
        return (homes, keys)
    }

    static func readClimate(session: GreeSession, mac: String) async throws -> GreeClimate {
        guard let key = session.deviceKeys[mac] else {
            throw CloudError.failed("还没有这台空调的通信密钥，下拉同步后再试")
        }
        let values = try await exchange(session: session, mac: mac, key: key, commands: [], query: true)
        return GreeClimate(
            power: (values["Pow"] ?? 0) != 0,
            mode: values["Mod"] ?? 0,
            temperature: values["SetTem"] ?? 26,
            fan: values["WdSpd"] ?? 0
        )
    }

    static func writeClimate(
        session: GreeSession,
        mac: String,
        power: Bool?,
        mode: Int?,
        temperature: Int?,
        fan: Int?
    ) async throws {
        guard let key = session.deviceKeys[mac] else {
            throw CloudError.failed("还没有这台空调的通信密钥，下拉同步后再试")
        }
        var commands: [(String, Int)] = []
        if let mode { commands.append(("Mod", mode)) }
        if let temperature { commands.append(("SetTem", temperature)) }
        if let fan { commands.append(("WdSpd", fan)) }
        if let power { commands.append(("Pow", power ? 1 : 0)) }
        guard !commands.isEmpty else { return }
        _ = try await exchange(session: session, mac: mac, key: key, commands: commands, query: false)
    }

    private static func exchange(
        session: GreeSession,
        mac: String,
        key: String,
        commands: [(String, Int)],
        query: Bool
    ) async throws -> [String: Int] {
        guard let uid = Int(session.userId) else { throw CloudError.failed("格力用户编号无效") }
        let mqtt = MiniMQTT(host: session.mqttHost, port: 1984)
        defer { mqtt.close() }
        let parent = parentMAC(mac)
        try await mqtt.connect(clientID: "app_\(CloudCrypto.randomHex(bytes: 8))", username: session.userId, password: session.token)
        try await mqtt.subscribe(topic: "response/\(parent)/#")
        try await mqtt.subscribe(topic: "status/\(parent)/#")
        if query {
            try await mqtt.publish(topic: "request/\(parent)", payload: Data(envelope(uid: uid, tcid: mac, pack: try encrypt("{\"t\": \"status\", \"cols\": [\"Pow\", \"Mod\", \"SetTem\", \"WdSpd\"]}", key: key)).utf8))
        }
        for command in commands {
            let inner = "{\"t\": \"cmd\", \"opt\": [\"\(command.0)\"], \"p\": [\(command.1)]}"
            let body = envelope(uid: uid, tcid: mac, pack: try encrypt(inner, key: key))
            try await mqtt.publish(topic: "request/\(parent)", payload: Data(body.utf8))
        }
        if !query { return [:] }
        let deadline = Date().addingTimeInterval(8)
        while let message = try await mqtt.readPublish(until: deadline) {
            guard let object = try? JSONSerialization.jsonObject(with: message.1) as? [String: Any],
                  let pack = jsonString(object["pack"]) else { continue }
            let tcid = jsonString(object["tcid"]) ?? ""
            guard tcid.isEmpty || tcid == mac || parentMAC(tcid) == parent else { continue }
            guard let plain = try? decrypt(pack, key: key, tag: jsonString(object["tag"])),
                  let parsed = try? JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any],
                  let cols = parsed["cols"] as? [Any],
                  let dat = parsed["dat"] as? [Any] else { continue }
            var values: [String: Int] = [:]
            for (index, name) in cols.enumerated() where index < dat.count {
                if let key = jsonString(name), let value = jsonInt(dat[index]) {
                    values[key] = value
                }
            }
            if values["Pow"] != nil { return values }
        }
        throw CloudError.failed("空调没有回应，确认它在格力+里在线后再试")
    }

    private static func readPowers(session: GreeSession, keys: [String: String]) async -> [String: Bool] {
        guard !keys.isEmpty, let uid = Int(session.userId) else { return [:] }
        do {
            return try await readPowersBody(session: session, keys: keys, uid: uid)
        } catch {
            return [:]
        }
    }

    private static func readPowersBody(session: GreeSession, keys: [String: String], uid: Int) async throws -> [String: Bool] {
        let mqtt = MiniMQTT(host: session.mqttHost, port: 1984)
        defer { mqtt.close() }
        try await mqtt.connect(clientID: "app_\(CloudCrypto.randomHex(bytes: 8))", username: session.userId, password: session.token)
        var pending = Set(keys.keys)
        for mac in keys.keys {
            let parent = parentMAC(mac)
            guard let key = keys[mac] else { continue }
            do {
                try await mqtt.subscribe(topic: "response/\(parent)/#")
                try await mqtt.subscribe(topic: "status/\(parent)/#")
                let pack = try encrypt("{\"t\": \"status\", \"cols\": [\"Pow\"]}", key: key)
                try await mqtt.publish(topic: "request/\(parent)", payload: Data(envelope(uid: uid, tcid: mac, pack: pack).utf8))
            } catch {
                pending.remove(mac)
            }
        }
        var found: [String: Bool] = [:]
        let deadline = Date().addingTimeInterval(8)
        while !pending.isEmpty {
            let message: (String, Data)?
            do {
                message = try await mqtt.readPublish(until: deadline)
            } catch {
                break
            }
            guard let message else { break }
            guard let object = try? JSONSerialization.jsonObject(with: message.1) as? [String: Any],
                  let pack = jsonString(object["pack"]) else { continue }
            let tcid = jsonString(object["tcid"]) ?? ""
            let topicMAC = message.0.split(separator: "/").dropFirst().first.map(String.init) ?? ""
            let mac = pending.first { candidate in
                if !tcid.isEmpty {
                    return candidate == tcid || parentMAC(candidate) == parentMAC(tcid)
                }
                return candidate == topicMAC || parentMAC(candidate) == topicMAC
            }
            guard let mac, let key = keys[mac] else { continue }
            guard let plain = try? decrypt(pack, key: key, tag: jsonString(object["tag"])),
                  let parsed = try? JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any],
                  let cols = parsed["cols"] as? [Any],
                  let dat = parsed["dat"] as? [Any],
                  let index = cols.firstIndex(where: { jsonString($0) == "Pow" }),
                  index < dat.count,
                  let power = jsonInt(dat[index]) else { continue }
            found[mac] = power != 0
            pending.remove(mac)
        }
        return found
    }

    private static func devices(
        account: LinkedAccount,
        homeId: String,
        homeName: String,
        data: [String: Any]
    ) -> (home: IoTHome, keys: [String: String]) {
        let rooms = (data["rooms"] as? [Any]) ?? []
        var buckets: [String: [IoTDevice]] = [:]
        var names: [String: String] = [:]
        var order: [String] = []
        var keyed: [String: (name: String, model: String, online: Bool, room: String)] = [:]
        var keys: [String: String] = [:]
        for row in rooms {
            guard let room = row as? [String: Any] else { continue }
            let roomName = (jsonString(room["name"]) ?? jsonString(room["roomName"]) ?? "未分配房间").trimmingCharacters(in: .whitespaces)
            let devs = (room["devs"] as? [Any]) ?? []
            for item in devs {
                guard let dev = item as? [String: Any] else { continue }
                let mac = (jsonString(dev["mac"]) ?? "").trimmingCharacters(in: .whitespaces)
                let key = (jsonString(dev["key"]) ?? "").trimmingCharacters(in: .whitespaces)
                guard !mac.isEmpty else { continue }
                let name = (jsonString(dev["name"]) ?? "空调").trimmingCharacters(in: .whitespaces)
                let model = (jsonString(dev["model"]) ?? jsonString(dev["ver"]) ?? "").trimmingCharacters(in: .whitespaces)
                let online = dev["online"] == nil ? true : onlineFlag(dev["online"])
                keyed[mac] = (name.isEmpty ? "空调" : name, model, online, roomName.isEmpty ? "未分配房间" : roomName)
                if !key.isEmpty { keys[mac] = key }
            }
        }
        let kept = filterDuplicates(Array(keyed.keys), keys: keys)
        for mac in kept {
            guard let info = keyed[mac] else { continue }
            let roomId = info.room
            if names[roomId] == nil {
                names[roomId] = info.room
                order.append(roomId)
            }
            var category = DeviceCategory.resolve(model: info.model + " air-conditioner", specType: nil)
            if category == .other { category = .airConditioner }
            buckets[roomId, default: []].append(IoTDevice(
                id: "\(account.id.uuidString)|gree|\(mac)",
                did: mac,
                name: info.name,
                model: info.model,
                online: info.online,
                specType: "gree",
                localIP: nil,
                roomName: info.room,
                homeName: homeName,
                homeId: homeId,
                accountId: account.id,
                platform: .gree,
                category: category,
                power: nil
            ))
        }
        let roomList = order.map { name in
            IoTRoom(
                id: "\(account.id.uuidString)|gree|\(homeId)|\(name)",
                name: names[name] ?? name,
                devices: (buckets[name] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            )
        }
        let home = IoTHome(
            id: "\(account.id.uuidString)|gree|\(homeId)",
            homeId: homeId,
            name: homeName,
            platform: .gree,
            accountId: account.id,
            rooms: roomList.isEmpty ? [IoTRoom(id: "\(account.id.uuidString)|gree|\(homeId)|empty", name: "全部设备", devices: [])] : roomList
        )
        return (home, keys.filter { kept.contains($0.key) })
    }

    private static func filterDuplicates(_ macs: [String], keys: [String: String]) -> [String] {
        var groups: [String: [String]] = [:]
        for mac in macs {
            groups[keys[mac] ?? mac, default: []].append(mac)
        }
        var kept: [String] = []
        for group in groups.values {
            let preferred = group.filter { $0.hasSuffix("00") && $0.count > 12 }
            kept.append(contentsOf: preferred.isEmpty ? group : preferred)
        }
        return kept
    }

    private static func emptyHome(account: LinkedAccount, homeId: String, name: String) -> IoTHome {
        IoTHome(
            id: "\(account.id.uuidString)|gree|\(homeId)",
            homeId: homeId,
            name: name,
            platform: .gree,
            accountId: account.id,
            rooms: [IoTRoom(id: "\(account.id.uuidString)|gree|\(homeId)|empty", name: "全部设备", devices: [])]
        )
    }

    private static func post(host: String, path: String, payload: [String: Any], hashKeys: [String], now: Date = Date()) async throws -> [String: Any] {
        let stamp = utcStamp(now)
        let seconds = Int(now.timeIntervalSince1970)
        let vc = XiaomiCrypto.md5Lower("\(appID)_\(appHash)_\(stamp)_\(seconds)")
        let joined = hashKeys.map { stringValue(payload[$0]) }.joined(separator: "_")
        let datVc = XiaomiCrypto.md5Lower("\(appHash)_\(joined)")
        var body: [String: Any] = [
            "api": ["appId": appID, "r": seconds, "t": stamp, "vc": vc],
            "datVc": datVc,
        ]
        for (key, value) in payload { body[key] = value }
        let json = try JSONSerialization.data(withJSONObject: body)
        guard let text = String(data: json, encoding: .utf8) else { throw CloudError.invalidResponse }
        let encrypted = try CloudCrypto.aesECB(.encrypt, data: Data(text.utf8), key: aesKey)
        guard let url = URL(string: host + path) else { throw CloudError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("5ac2bdf935bcca70", forHTTPHeaderField: "Gaen1")
        request.setValue("utf-8", forHTTPHeaderField: "Charset")
        request.httpBody = Data(encrypted.base64EncodedString().utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CloudError.failed("格力服务器暂时没有响应")
        }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.invalidResponse
        }
        guard let enRes = jsonString(envelope["enRes"]) else {
            if envelope["r"] != nil { return envelope }
            throw CloudError.invalidResponse
        }
        let plain = try CloudCrypto.aesECB(.decrypt, data: Data(base64Encoded: enRes) ?? Data(), key: aesKey)
        guard let object = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            throw CloudError.invalidResponse
        }
        return object
    }

    private static func encrypt(_ json: String, key: String) throws -> String {
        let keyData = Data(key.utf8)
        let encrypted = try CloudCrypto.aesECB(.encrypt, data: Data(json.utf8), key: keyData)
        return encrypted.base64EncodedString()
    }

    private static func decrypt(_ pack: String, key: String, tag: String?) throws -> String {
        let keyData = Data(key.utf8)
        if let data = Data(base64Encoded: pack),
           let plain = try? CloudCrypto.aesECB(.decrypt, data: data, key: keyData),
           let text = String(data: plain, encoding: .utf8),
           let end = text.lastIndex(of: "}") {
            return String(text[...end])
        }
        if let tag, let tagData = Data(base64Encoded: tag), let cipher = Data(base64Encoded: pack), keyData.count == 16 {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: gcmNonce), ciphertext: cipher, tag: tagData)
            let plain = try AES.GCM.open(box, using: SymmetricKey(data: keyData), authenticating: gcmAAD)
            guard let text = String(data: plain, encoding: .utf8), let end = text.lastIndex(of: "}") else {
                throw CloudError.invalidResponse
            }
            return String(text[...end])
        }
        throw CloudError.invalidResponse
    }

    private static func envelope(uid: Int, tcid: String, pack: String) -> String {
        let cid = String(Int.random(in: 1_000_000_000...9_999_999_999))
        return "{\"cid\": \"\(cid)\", \"i\": 0, \"pack\": \"\(pack)\", \"t\": \"pack\", \"tcid\": \"\(tcid)\", \"uid\": \(uid)}"
    }

    private static func parentMAC(_ mac: String) -> String {
        if mac.hasSuffix("00"), mac.count > 12 { return String(mac.dropLast(2)) }
        return mac
    }

    private static func failure(_ data: [String: Any], name: String) -> CloudError? {
        guard let code = jsonInt(data["r"]), code != 200 else { return nil }
        let message = jsonString(data["msg"]) ?? "\(name)请求失败（\(code)）"
        if code == 401 || code == 403 || message.localizedCaseInsensitiveContains("token") || message.contains("登录") {
            return .sessionExpired(name)
        }
        return .failed(message)
    }

    private static func uidNumber(_ userId: String) -> Any {
        if let value = Int(userId) { return value }
        return userId
    }

    private static func stringValue(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func utcStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func idText(_ value: Any?) -> String? {
        guard let text = jsonString(value)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }

    private static func onlineFlag(_ value: Any?) -> Bool {
        if isJSONBool(value) { return (value as? NSNumber)?.boolValue ?? false }
        if let number = jsonInt(value) { return number != 0 }
        return true
    }
}
