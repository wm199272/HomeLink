import Foundation

enum QihooLoginStep: Sendable {
    case session(QihooSession)
    case captcha(Data, sc: String)
}

enum QihooCloudClient {
    private static let loginURL = URL(string: "https://passport.360.cn/request.php")!
    private static let base = "https://q.smart.360.cn"
    private static let from = "mpl_smarthome_and"
    private static let sigSecret = "i7v2m5x6q"
    private static let userAgent = "360accounts andv3.2.4.6 mpl_smarthome_and"

    static func makeIdentity() -> QihooDeviceIdentity {
        QihooDeviceIdentity(
            mid: CloudCrypto.randomHex(bytes: 16),
            androidId: CloudCrypto.randomHex(bytes: 8),
            m2: UUID().uuidString.lowercased()
        )
    }

    static func login(
        username: String,
        password: String,
        device: QihooDeviceIdentity,
        captcha: (sc: String, code: String)? = nil
    ) async throws -> QihooLoginStep {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        var params = deviceParams(device)
        let now = String(Int(Date().timeIntervalSince1970 * 1000))
        params["loginType"] = "801"
        params["vt_guid"] = now
        params["is_keep_alive"] = "1"
        params["needDeviceCheck"] = "0"
        params["trace_id"] = "src_and_1916_\(now)"
        params["method"] = "UserIntf.login"
        params["head_type"] = "q"
        params["sec_type"] = "bool"
        params["fields"] = "qid,username,nickname,loginemail,head_pic,mobile"
        params["username"] = user
        params["password"] = XiaomiCrypto.md5Lower(password)
        if let captcha {
            params["sc"] = captcha.sc
            params["uc"] = captcha.code
            params["captchaType"] = "graph"
        }
        params["sig"] = signature(params)
        let decoded = try await envelope(params, method: "UserIntf.login")
        let errno = jsonInt(decoded["errno"]) ?? -1
        if errno == 5010 {
            let image = try await captchaImage(device: device)
            return .captcha(image.data, sc: image.sc)
        }
        if errno == 5007 {
            throw CloudError.failed("没有找到这个 360 账号")
        }
        guard errno == 0, let account = decoded["user"] as? [String: Any] else {
            let message = jsonString(decoded["errmsg"])
            throw CloudError.failed(message?.isEmpty == false ? message! : "360 登录没有成功（\(errno)）")
        }
        guard let q = jsonString(account["q"]).map(uriDecode),
              let t = jsonString(account["t"]).map(uriDecode),
              let qid = idText(account["qid"]) else {
            throw CloudError.failed("360 登录没有返回会话")
        }
        let sid = try await mintSid(q: q, t: t, qid: qid, device: device)
        return .session(QihooSession(q: q, t: t, qid: qid, sid: sid, device: device))
    }

    static func fetchHomes(account: LinkedAccount) async throws -> (homes: [IoTHome], session: QihooSession) {
        guard var session = account.qihoo else { throw CloudError.sessionExpired("360 智慧生活") }
        do {
            return (try await homes(account: account, session: session), session)
        } catch let error as CloudError {
            if case .sessionExpired = error {
                session.sid = try await mintSid(q: session.q, t: session.t, qid: session.qid, device: session.device)
                return (try await homes(account: account, session: session), session)
            }
            throw error
        }
    }

    static func send(account: LinkedAccount, sn: String, command: VacuumCommand) async throws {
        guard let session = account.qihoo else { throw CloudError.sessionExpired("360 智慧生活") }
        let infoType: String
        let data: String
        switch command {
        case .start:
            infoType = "21005"
            data = "{\"mode\":\"smartClean\",\"globalCleanTimes\":1}"
        case .pause:
            infoType = "21017"
            data = "{\"cmd\":\"pause\"}"
        case .dock:
            infoType = "21012"
            data = "{\"cmd\":\"start\"}"
        }
        try await commandRequest(session: session, sn: sn, infoType: infoType, data: data)
    }

    private static func homes(account: LinkedAccount, session: QihooSession) async throws -> [IoTHome] {
        var merged: [String: [String: Any]] = [:]
        let filters: [String?] = [nil, "1", "2", "3", "4", "5", "6", "7", "8"]
        try await withThrowingTaskGroup(of: [[String: Any]].self) { group in
            for filter in filters {
                group.addTask {
                    try await deviceList(session: session, devType: filter)
                }
            }
            for try await rows in group {
                for row in rows {
                    if let sn = jsonString(row["sn"]), !sn.isEmpty {
                        merged[sn] = row
                    }
                }
            }
        }
        let devices = merged.values.map { device(account: account, row: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return [IoTHome(
            id: "\(account.id.uuidString)|qihoo|home",
            homeId: "qihoo",
            name: "360 智慧生活",
            platform: .qihoo,
            accountId: account.id,
            rooms: [IoTRoom(id: "\(account.id.uuidString)|qihoo|all", name: "全部设备", devices: devices)]
        )]
    }

    private static func deviceList(session: QihooSession, devType: String?) async throws -> [[String: Any]] {
        var fields = commonFields()
        if let devType { fields["devType"] = devType }
        let data: [String: Any]
        do {
            data = try await form(
                url: URL(string: base + "/common/dev/GetList")!,
                cookie: cookie(session, includeSid: true),
                userAgent: "QihooSuperApp_NoPods/11.1.0 (iPhone; iOS 17.0; Scale/3.00)",
                fields: fields
            )
            try check(data, name: "360 智慧生活")
        } catch let error as CloudError {
            if case .sessionExpired = error { throw error }
            return []
        }
        if let list = data["data"] as? [Any] {
            return list.compactMap { $0 as? [String: Any] }
        }
        let bag = data["data"] as? [String: Any] ?? [:]
        for key in ["list", "devList", "devices", "cleanDevList"] {
            if let list = bag[key] as? [Any] {
                return list.compactMap { $0 as? [String: Any] }
            }
        }
        return []
    }

    private static func device(account: LinkedAccount, row: [String: Any]) -> IoTDevice {
        let sn = jsonString(row["sn"]) ?? UUID().uuidString
        let devType = jsonInt(row["devType"]) ?? 0
        let title = (jsonString(row["title"]) ?? jsonString(row["hardware"]) ?? "360 设备").trimmingCharacters(in: .whitespaces)
        let hardware = jsonString(row["hardware"]) ?? ""
        let vacuum = devType == 3
        var category = DeviceCategory.resolve(model: title + " " + hardware, specType: nil)
        if vacuum { category = .vacuum }
        return IoTDevice(
            id: "\(account.id.uuidString)|qihoo|\(sn)",
            did: sn,
            name: title.isEmpty ? "360 设备" : title,
            model: hardware,
            online: (jsonInt(row["online"]) ?? 0) != 0,
            specType: vacuum ? "vacuum" : "device",
            localIP: nil,
            roomName: "全部设备",
            homeName: "360 智慧生活",
            homeId: "qihoo",
            accountId: account.id,
            platform: .qihoo,
            category: category,
            power: nil
        )
    }

    private static func commandRequest(session: QihooSession, sn: String, infoType: String, data: String) async throws {
        var fields = commonFields()
        fields["data"] = data
        fields["devType"] = "3"
        fields["infoType"] = infoType
        fields["sn"] = sn
        let response = try await form(
            url: URL(string: base + "/clean/cmd/send")!,
            cookie: cookie(session, includeSid: true),
            userAgent: "QihooSuperApp_NoPods/11.1.0 (iPhone; iOS 17.0; Scale/3.00)",
            fields: fields
        )
        try check(response, name: "360 智慧生活")
    }

    private static func mintSid(q: String, t: String, qid: String, device: QihooDeviceIdentity) async throws -> String {
        let info: [String: String] = [
            "release": "appstore",
            "brand": "iPhone",
            "model": "iPhone",
            "notifyId": device.mid + device.mid,
            "lang": "zh_CN",
            "imei": XiaomiCrypto.md5Lower(device.mid),
        ]
        let infoData = try JSONSerialization.data(withJSONObject: info)
        let fields = [
            "clientInfo": String(data: infoData, encoding: .utf8) ?? "{}",
            "lang": "zh_CN",
            "phoneNum": "",
            "taskid": UUID().uuidString.lowercased(),
        ]
        let response = try await form(
            url: URL(string: base + "/common/user/login")!,
            cookie: "q=\(q);t=\(t);qid=\(qid)",
            userAgent: "qhsa-iphone-11.1.0",
            fields: fields
        )
        try check(response, name: "360 智慧生活")
        guard let sid = jsonString((response["data"] as? [String: Any])?["sid"]), !sid.isEmpty else {
            throw CloudError.failed("360 没有返回智慧生活会话")
        }
        return sid
    }

    private static func captchaImage(device: QihooDeviceIdentity) async throws -> (data: Data, sc: String) {
        var params = deviceParams(device)
        let now = String(Int(Date().timeIntervalSince1970 * 1000))
        params["vt_guid"] = now
        params["trace_id"] = "src_and_1916_\(now)"
        params["method"] = "UserIntf.getCaptcha"
        params["sig"] = signature(params)
        let env = try seal(params)
        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(outerBody(method: "UserIntf.getCaptcha", trace: params["trace_id"] ?? now, env: env).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.invalidResponse }
        let sc = http.value(forHTTPHeaderField: "sc").map(uriDecode) ?? ""
        guard !sc.isEmpty, !data.isEmpty, data.first != UInt8(ascii: "{") else {
            throw CloudError.failed("360 没有返回验证码")
        }
        return (data, sc)
    }

    private static func envelope(_ params: [String: String], method: String) async throws -> [String: Any] {
        let env = try seal(params)
        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(outerBody(method: method, trace: params["trace_id"] ?? "", env: env).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CloudError.failed("360 登录服务器暂时没有响应")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ret = jsonString(object["ret"]),
              let cipher = Data(base64Encoded: ret) else {
            throw CloudError.invalidResponse
        }
        let plain = try CloudCrypto.desCBC(CCOperation(kCCDecrypt), data: cipher, key: Data(env.desKey.utf8))
        guard let decoded = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            throw CloudError.invalidResponse
        }
        return decoded
    }

    private static func seal(_ params: [String: String]) throws -> (parad: String, desKey: String, wrapped: String) {
        let query = params.map { "\($0.key)=\(CloudCrypto.uriEncode($0.value))" }.joined(separator: "&")
        let keyString = CloudCrypto.randomASCII(106) + CloudCrypto.randomASCII(8)
        let desKey = String(keyString.suffix(8))
        let parad = try CloudCrypto.desCBC(CCOperation(kCCEncrypt), data: Data(query.utf8), key: Data(desKey.utf8)).base64EncodedString()
        let wrapped = try CloudCrypto.rsaPKCS1Encrypt(Data(keyString.utf8)).base64EncodedString()
        return (parad, desKey, wrapped)
    }

    private static func outerBody(method: String, trace: String, env: (parad: String, desKey: String, wrapped: String)) -> String {
        let fields = [
            "device_lang": "zh-CN",
            "trace_id": trace,
            "quc_lang": "en",
            "method": method,
            "from": from,
            "parad": env.parad,
            "key": env.wrapped,
        ]
        return fields.map { "\($0.key)=\(CloudCrypto.formEncode($0.value))" }.joined(separator: "&")
    }

    private static func deviceParams(_ device: QihooDeviceIdentity) -> [String: String] {
        [
            "os_sdk_version": "android_33",
            "mid": device.mid,
            "quc_sdk_version": "v3.2.4.6",
            "mname": "",
            "ua": "Dalvik/2.1.0 (Linux; U; Android 13; sdk_gphone64_arm64 Build/TE1A.240213.009)",
            "os_manufacturer": "Google",
            "mSystemVersion": "android 13",
            "os_board": "goldfish_arm64",
            "os_model": "sdk_gphone64_arm64",
            "quc_lang": "en",
            "sh": "2337.0",
            "from": from,
            "oaid": "",
            "app": "360Robot",
            "ui_ver": "4.3.4.1-alert-ui",
            "res_mode": "1",
            "sw": "1080.0",
            "format": "json",
            "qh_id": "",
            "device_os": "android",
            "device_lang": "zh-CN",
            "v": "2.24.0",
            "androidid": device.androidId,
            "sdpi": "2.625",
        ]
    }

    private static func signature(_ params: [String: String]) -> String {
        let keys = params.keys.sorted { $0.compare($1, options: .literal) == .orderedAscending }
        let base = keys.map { "\($0)=\(params[$0] ?? "")" }.joined() + sigSecret
        return XiaomiCrypto.md5Lower(base)
    }

    private static func commonFields() -> [String: String] {
        [
            "countryId": "CN",
            "from": "mpc_ios",
            "lang": "zh_CN",
            "taskid": UUID().uuidString.lowercased(),
        ]
    }

    private static func cookie(_ session: QihooSession, includeSid: Bool) -> String {
        var value = "q=\(session.q);t=\(session.t);qid=\(session.qid)"
        if includeSid { value += ";sid=\(session.sid)" }
        return value
    }

    private static func form(url: URL, cookie: String, userAgent: String, fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.httpBody = Data(fields.map { "\($0.key)=\(CloudCrypto.formEncode($0.value))" }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw CloudError.sessionExpired("360 智慧生活")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.invalidResponse
        }
        return object
    }

    private static func check(_ data: [String: Any], name: String) throws {
        let errno = jsonInt(data["errno"]) ?? -1
        if errno == 0 { return }
        if errno == 102 || errno == 103 {
            throw CloudError.sessionExpired(name)
        }
        let message = jsonString(data["errmsg"])
        throw CloudError.failed(message?.isEmpty == false ? message! : "\(name)请求失败（\(errno)）")
    }

    private static func uriDecode(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    private static func idText(_ value: Any?) -> String? {
        guard let text = jsonString(value), !text.isEmpty else { return nil }
        return text
    }
}
