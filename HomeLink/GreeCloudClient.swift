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
        let bag = nestedBag(data)
        guard let userId = idText(bag["uid"]) ?? idText(data["uid"]),
              let token = jsonString(bag["token"]) ?? jsonString(data["token"]),
              !token.isEmpty else {
            throw CloudError.failed(jsonString(data["msg"]) ?? jsonString(bag["msg"]) ?? "格力登录没有返回会话")
        }
        dlog("gree login ok uid=\(userId) host=\(region.host)")
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
        var keys: [String: String] = session.deviceKeys
        var homes: [IoTHome] = []

        let homesData = nestedBag(try await post(
            host: session.host,
            path: "/App/GetHomes",
            payload: ["token": session.token, "uid": uidNumber(session.userId)],
            hashKeys: ["token", "uid"]
        ))
        if let error = failure(homesData, name: "格力+") { throw error }
        var homeRows = jsonArray(homesData, "home", "homes")
        dlog("gree GetHomes fields=\(homesData.keys.sorted()) rows=\(homeRows.count)")

        if homeRows.isEmpty {
            let bundled = try await fetchUserHomes(account: account, session: session)
            if bundled.homes.contains(where: { $0.rooms.contains { !$0.devices.isEmpty } }) {
                return try await finishFetch(account: account, session: session, homes: bundled.homes, keys: bundled.keys)
            }
            dlog("gree no homes from GetHomes or GetDevsOfUserHomes")
            return ([emptyHome(account: account, homeId: "gree", name: "格力+")], keys)
        }

        for row in homeRows {
            guard let home = row as? [String: Any] else { continue }
            let homeId = idText(home["id"]) ?? idText(home["homeId"]) ?? "gree"
            let homeName = (jsonString(home["name"]) ?? jsonString(home["homeName"]) ?? "格力+").trimmingCharacters(in: .whitespaces)
            var homeValue: Any = homeId
            if let raw = home["id"] ?? home["homeId"], !(raw is NSNull) {
                homeValue = raw
            }
            let devicesData = nestedBag(try await post(
                host: session.host,
                path: "/App/GetDevsInRoomsOfHomeV2",
                payload: ["token": session.token, "homeId": homeValue, "uid": uidNumber(session.userId)],
                hashKeys: ["token", "uid", "homeId"]
            ))
            if let error = failure(devicesData, name: "格力+") { throw error }
            dlog("gree GetDevsInRoomsOfHomeV2 home=\(homeId) fields=\(devicesData.keys.sorted())")
            var built = devices(account: account, homeId: homeId, homeName: homeName.isEmpty ? "格力+" : homeName, data: devicesData)
            if built.home.rooms.allSatisfy(\.devices.isEmpty) {
                let fromHome = devices(account: account, homeId: homeId, homeName: homeName.isEmpty ? "格力+" : homeName, data: home)
                if !fromHome.home.rooms.allSatisfy(\.devices.isEmpty) {
                    built = fromHome
                }
            }
            for pair in built.keys { keys[pair.key] = pair.value }
            homes.append(built.home)
        }

        if homes.allSatisfy({ $0.rooms.allSatisfy(\.devices.isEmpty) }) {
            dlog("gree rooms empty, trying GetDevsOfUserHomes")
            let bundled = try await fetchUserHomes(account: account, session: session)
            if bundled.homes.contains(where: { $0.rooms.contains { !$0.devices.isEmpty } }) {
                homes = bundled.homes
                for pair in bundled.keys { keys[pair.key] = pair.value }
            }
        }

        return try await finishFetch(account: account, session: session, homes: homes, keys: keys)
    }

    private static func fetchUserHomes(account: LinkedAccount, session: GreeSession) async throws -> (homes: [IoTHome], keys: [String: String]) {
        let data = nestedBag(try await post(
            host: session.host,
            path: "/App/GetDevsOfUserHomes",
            payload: ["token": session.token, "uid": uidNumber(session.userId)],
            hashKeys: ["token", "uid"]
        ))
        if let error = failure(data, name: "格力+") { throw error }
        dlog("gree GetDevsOfUserHomes fields=\(data.keys.sorted())")
        var keys: [String: String] = [:]
        var homes: [IoTHome] = []
        let rows = jsonArray(data, "homes", "home")
        if rows.isEmpty {
            let built = devices(account: account, homeId: "gree", homeName: "格力+", data: data)
            return ([built.home], built.keys)
        }
        for row in rows {
            guard let home = row as? [String: Any] else { continue }
            let homeId = idText(home["id"]) ?? idText(home["homeId"]) ?? "gree"
            let homeName = (jsonString(home["name"]) ?? jsonString(home["homeName"]) ?? "格力+").trimmingCharacters(in: .whitespaces)
            let built = devices(account: account, homeId: homeId, homeName: homeName.isEmpty ? "格力+" : homeName, data: home)
            for pair in built.keys { keys[pair.key] = pair.value }
            homes.append(built.home)
        }
        return (homes, keys)
    }

    private static func finishFetch(
        account: LinkedAccount,
        session: GreeSession,
        homes: [IoTHome],
        keys: [String: String]
    ) async throws -> (homes: [IoTHome], keys: [String: String]) {
        let deviceCount = homes.reduce(0) { $0 + $1.rooms.reduce(0) { $0 + $1.devices.count } }
        dlog("gree devices=\(deviceCount) keys=\(Set(keys.keys).count)")
        let flags = await queryOnlineFlags(session: session, macs: Array(Set(homes.flatMap { $0.rooms.flatMap(\.devices).map(\.did) })))
        let marked = homes.map { home -> IoTHome in
            var copy = home
            copy.rooms = home.rooms.map { room in
                var next = room
                next.devices = room.devices.map { device in
                    var item = device
                    if let online = flags[device.did] ?? flags[parentMAC(device.did)] {
                        item.online = online
                    }
                    return item
                }
                return next
            }
            return copy
        }
        if marked.allSatisfy({ $0.rooms.allSatisfy(\.devices.isEmpty) }) {
            return ([emptyHome(account: account, homeId: "gree", name: "格力+")], keys)
        }
        return (marked, keys)
    }

    /// 格力+ 里能操作的列都问一遍。设备不认的列不会出现在返回里，
    /// 所以界面只按上报出来的列显示按钮，不会给空调发它不支持的命令。
    private static let climateColumns = [
        "Pow", "Mod", "SetTem", "WdSpd", "TemSen",
        "SwUpDn", "SwingLfRig", "HdHeat", "Sleep", "SwhSl", "Health",
    ]

    static func readClimate(session: GreeSession, mac: String) async throws -> GreeClimate {
        guard let key = deviceKey(session: session, mac: mac) else {
            throw CloudError.failed("还没有这台空调的通信密钥，下拉同步后再试")
        }
        var values: [String: Int]
        do {
            values = try await exchange(
                session: session,
                mac: mac,
                key: key,
                commands: [],
                query: true,
                columns: climateColumns
            )
        } catch {
            values = try await exchange(
                session: session,
                mac: mac,
                key: key,
                commands: [],
                query: true,
                columns: ["Pow", "Mod", "SetTem", "WdSpd"]
            )
        }
        return climate(from: values)
    }

    private static func climate(from values: [String: Int]) -> GreeClimate {
        GreeClimate(
            power: (values["Pow"] ?? 0) != 0,
            mode: values["Mod"] ?? 0,
            temperature: values["SetTem"] ?? 26,
            fan: values["WdSpd"] ?? 0,
            raw: values
        )
    }

    static func writeClimate(
        session: GreeSession,
        mac: String,
        power: Bool?,
        mode: Int?,
        temperature: Int?,
        fan: Int?,
        flags: [String: Int] = [:]
    ) async throws {
        guard let key = deviceKey(session: session, mac: mac) else {
            throw CloudError.failed("还没有这台空调的通信密钥，下拉同步后再试")
        }
        var commands: [(String, Int)] = []
        if let mode { commands.append(("Mod", mode)) }
        if let temperature { commands.append(("SetTem", temperature)) }
        if let fan { commands.append(("WdSpd", fan)) }
        if let power { commands.append(("Pow", power ? 1 : 0)) }
        for (column, value) in flags { commands.append((column, value)) }
        guard !commands.isEmpty else { return }
        _ = try await exchange(session: session, mac: mac, key: key, commands: commands, query: false)
    }

    private static func exchange(
        session: GreeSession,
        mac: String,
        key: String,
        commands: [(String, Int)],
        query: Bool,
        columns: [String] = ["Pow", "Mod", "SetTem", "WdSpd"]
    ) async throws -> [String: Int] {
        let packJSON = try commandJSON(mac: mac, commands: commands, query: query, columns: columns)
        let pack = try encrypt(packJSON, key: key)
        guard let uid = Int(session.userId) else { throw CloudError.failed("格力用户编号无效") }
        let body = envelope(uid: uid, tcid: mac, pack: pack)
        dlog("gree exchange mac=\(redactMAC(mac)) query=\(query) cmds=\(commands.map(\.0))")

        if let route = await queryRoute(session: session, mac: mac) {
            do {
                let values = try await tcpExchange(route: route, json: body, mac: mac, key: key, query: query)
                if !query || values["Pow"] != nil { return values }
                dlog("gree tcp no Pow, falling back to mqtt")
            } catch {
                dlog("gree tcp failed: \(error.localizedDescription)")
            }
        }

        return try await mqttExchange(session: session, mac: mac, key: key, body: body, query: query)
    }

    private static func commandJSON(mac: String, commands: [(String, Int)], query: Bool, columns: [String]) throws -> String {
        if query {
            let list = columns.map { "\"\($0)\"" }.joined(separator: ", ")
            return "{\"t\":\"status\",\"mac\":\"\(mac)\",\"cols\":[\(list)]}"
        }
        let opts = commands.map { "\"\($0.0)\"" }.joined(separator: ", ")
        let values = commands.map { String($0.1) }.joined(separator: ", ")
        return "{\"t\":\"cmd\",\"mac\":\"\(mac)\",\"opt\":[\(opts)],\"p\":[\(values)]}"
    }

    private static func tcpExchange(
        route: (host: String, port: UInt16, tls: Bool),
        json: String,
        mac: String,
        key: String,
        query: Bool
    ) async throws -> [String: Int] {
        dlog("gree tcp \(route.host):\(route.port) tls=\(route.tls)")
        let data = try await GreeLineSocket.exchange(host: route.host, port: route.port, useTLS: route.tls, json: json)
        if !query { return decodeValues(data, mac: mac, key: key) }
        let values = decodeValues(data, mac: mac, key: key)
        guard values["Pow"] != nil else { throw CloudError.failed("空调没有回应") }
        return values
    }

    private static func mqttExchange(
        session: GreeSession,
        mac: String,
        key: String,
        body: String,
        query: Bool
    ) async throws -> [String: Int] {
        let mqtt = MiniMQTT(host: session.mqttHost, port: 1984)
        defer { mqtt.close() }
        let parent = parentMAC(mac)
        try await mqtt.connect(clientID: "app_\(CloudCrypto.randomHex(bytes: 8))", username: session.userId, password: session.token)
        try await mqtt.subscribe(topic: "response/\(parent)/#")
        try await mqtt.subscribe(topic: "status/\(parent)/#")
        if parent != mac {
            try await mqtt.subscribe(topic: "response/\(mac)/#")
            try await mqtt.subscribe(topic: "status/\(mac)/#")
        }
        let payload = Data(body.utf8)
        try await mqtt.publish(topic: "request/\(parent)", payload: payload)
        if parent != mac {
            try await mqtt.publish(topic: "request/\(mac)", payload: payload)
        }
        if !query { return [:] }
        let deadline = Date().addingTimeInterval(8)
        var values: [String: Int] = [:]
        var grace: Date?
        while true {
            guard let message = try await mqtt.readPublish(until: grace ?? deadline) else { break }
            let decoded = decodeValues(message.1, mac: mac, key: key)
            for (column, value) in decoded { values[column] = value }
            if values["Pow"] != nil, grace == nil {
                grace = Date().addingTimeInterval(1.2)
            }
        }
        guard values["Pow"] != nil else {
            throw CloudError.failed("空调没有回应，确认它在格力+里在线后再试")
        }
        return values
    }

    private static func decodeValues(_ data: Data, mac: String, key: String) -> [String: Int] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        let tcid = jsonString(object["tcid"]) ?? jsonString(object["cid"]) ?? ""
        if !tcid.isEmpty, tcid != mac, parentMAC(tcid) != parentMAC(mac) { return [:] }
        guard let pack = jsonString(object["pack"]),
              let plain = try? decrypt(pack, key: key, tag: jsonString(object["tag"])),
              let parsed = try? JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any] else { return [:] }
        var values: [String: Int] = [:]
        if let cols = parsed["cols"] as? [Any], let dat = parsed["dat"] as? [Any] {
            for (index, name) in cols.enumerated() where index < dat.count {
                if let column = jsonString(name), let value = jsonInt(dat[index]) {
                    values[column] = value
                }
            }
        }
        if let opt = parsed["opt"] as? [Any], let p = parsed["p"] as? [Any] {
            for (index, name) in opt.enumerated() where index < p.count {
                if let column = jsonString(name), let value = jsonInt(p[index]) {
                    values[column] = value
                }
            }
        }
        return values
    }

    private static func queryRoute(session: GreeSession, mac: String) async -> (host: String, port: UInt16, tls: Bool)? {
        let rows = await queryOnline(session: session, macs: [mac, parentMAC(mac)])
        for item in rows.online {
            guard let svr = jsonString(item["svr"]), let colon = svr.lastIndex(of: ":") else { continue }
            let host = String(svr[..<colon])
            guard let port = UInt16(String(svr[svr.index(after: colon)...])), !host.isEmpty, port > 0 else { continue }
            return (host, port, sslFlag(item["isSSL"]))
        }
        return nil
    }

    private static func queryOnlineFlags(session: GreeSession, macs: [String]) async -> [String: Bool] {
        guard !macs.isEmpty else { return [:] }
        let result = await queryOnline(session: session, macs: macs)
        var flags: [String: Bool] = [:]
        for item in result.online {
            if let mac = jsonString(item["mac"]) { flags[mac] = true }
        }
        for item in result.offline {
            if let mac = jsonString(item["mac"]) { flags[mac] = false }
        }
        return flags
    }

    private static func queryOnline(session: GreeSession, macs: [String]) async -> (online: [[String: Any]], offline: [[String: Any]]) {
        let unique = Array(Set(macs.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return ([], []) }
        do {
            let data = nestedBag(try await post(
                host: session.host,
                path: "/App/QueryOnline",
                payload: ["token": session.token, "uid": uidNumber(session.userId), "macs": unique],
                hashKeys: ["token", "uid"]
            ))
            if let error = failure(data, name: "格力+") {
                dlog("gree QueryOnline rejected \(error.localizedDescription)")
                return ([], [])
            }
            let online = jsonArray(data, "online").compactMap { $0 as? [String: Any] }
            let offline = jsonArray(data, "offline").compactMap { $0 as? [String: Any] }
            dlog("gree QueryOnline online=\(online.count) offline=\(offline.count) fields=\(data.keys.sorted())")
            return (online, offline)
        } catch {
            dlog("gree QueryOnline error \(error.localizedDescription)")
            return ([], [])
        }
    }

    private static func devices(
        account: LinkedAccount,
        homeId: String,
        homeName: String,
        data: [String: Any]
    ) -> (home: IoTHome, keys: [String: String]) {
        var keyed: [String: (name: String, model: String, online: Bool, room: String)] = [:]
        var keys: [String: String] = [:]
        collectDevices(data, room: "未分配房间", keyed: &keyed, keys: &keys)
        dlog("gree parsed macs=\(keyed.count) withKey=\(keys.count)")
        let kept = filterDuplicates(Array(keyed.keys), keys: keys)
        var buckets: [String: [IoTDevice]] = [:]
        var names: [String: String] = [:]
        var order: [String] = []
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
        var stored: [String: String] = [:]
        for mac in kept {
            if let key = keys[mac] ?? keys[parentMAC(mac)] {
                stored[mac] = key
                stored[parentMAC(mac)] = key
            }
        }
        return (home, stored)
    }

    private static func collectDevices(
        _ node: Any,
        room: String,
        keyed: inout [String: (name: String, model: String, online: Bool, room: String)],
        keys: inout [String: String]
    ) {
        if let items = node as? [Any] {
            for item in items {
                collectDevices(item, room: room, keyed: &keyed, keys: &keys)
            }
            return
        }
        guard let dict = node as? [String: Any] else { return }
        let roomName = (jsonString(dict["name"]) ?? jsonString(dict["roomName"]) ?? room).trimmingCharacters(in: .whitespaces)
        if let mac = deviceMAC(dict) {
            let secret = deviceSecret(dict)
            let name = (jsonString(dict["name"]) ?? jsonString(dict["devName"]) ?? "空调").trimmingCharacters(in: .whitespaces)
            let model = (jsonString(dict["model"]) ?? jsonString(dict["ver"]) ?? jsonString(dict["type"]) ?? "").trimmingCharacters(in: .whitespaces)
            let online = dict["online"] == nil ? true : onlineFlag(dict["online"])
            keyed[mac] = (name.isEmpty ? "空调" : name, model, online, roomName.isEmpty ? "未分配房间" : roomName)
            if let secret {
                keys[mac] = secret
                keys[parentMAC(mac)] = secret
            } else if keyed.count <= 8 {
                dlog("gree device fields=\(dict.keys.sorted()) mac=\(redactMAC(mac))")
            }
        }
        for key in ["rooms", "devs", "devices", "list", "devList", "home"] {
            if let nested = dict[key] {
                let nextRoom = key == "rooms" ? room : roomName
                collectDevices(nested, room: nextRoom.isEmpty ? room : nextRoom, keyed: &keyed, keys: &keys)
            }
        }
    }

    private static func deviceMAC(_ dev: [String: Any]) -> String? {
        let raw = jsonString(dev["mac"]) ?? jsonString(dev["mid"]) ?? jsonString(dev["deviceMac"]) ?? jsonString(dev["Mac"])
        let mac = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard mac.count >= 8 else { return nil }
        return mac
    }

    private static func deviceSecret(_ dev: [String: Any]) -> String? {
        let raw = jsonString(dev["key"]) ?? jsonString(dev["pkey"]) ?? jsonString(dev["secret"]) ?? jsonString(dev["aesKey"])
        let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }

    private static func deviceKey(session: GreeSession, mac: String) -> String? {
        if let key = session.deviceKeys[mac], !key.isEmpty { return key }
        let parent = parentMAC(mac)
        if let key = session.deviceKeys[parent], !key.isEmpty { return key }
        return session.deviceKeys.first { parentMAC($0.key) == parent }?.value
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
            if envelope["r"] != nil { return nestedBag(envelope) }
            throw CloudError.invalidResponse
        }
        let plain = try CloudCrypto.aesECB(.decrypt, data: Data(base64Encoded: enRes) ?? Data(), key: aesKey)
        guard let object = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            throw CloudError.invalidResponse
        }
        return nestedBag(object)
    }

    private static func nestedBag(_ data: [String: Any]) -> [String: Any] {
        var merged = data
        if let inner = data["data"] as? [String: Any] {
            for (key, value) in inner {
                merged[key] = value
            }
        } else if let list = data["data"] as? [Any] {
            if merged["home"] == nil { merged["home"] = list }
            if merged["homes"] == nil { merged["homes"] = list }
        }
        return merged
    }

    private static func jsonArray(_ data: [String: Any], _ keys: String...) -> [Any] {
        for key in keys {
            if let rows = data[key] as? [Any] { return rows }
            if let one = data[key] as? [String: Any] { return [one] }
        }
        return []
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

    private static func redactMAC(_ mac: String) -> String {
        guard mac.count > 4 else { return "****" }
        return String(repeating: "*", count: mac.count - 4) + mac.suffix(4)
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

    private static func sslFlag(_ value: Any?) -> Bool {
        if isJSONBool(value) { return (value as? NSNumber)?.boolValue ?? false }
        if let number = jsonInt(value) { return number != 0 }
        return false
    }
}
