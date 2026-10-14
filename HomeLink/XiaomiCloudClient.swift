import Foundation
import os

private let xiaomiLog = Logger(subsystem: "app.homelink.devices", category: "xiaomi")

struct QRTicket: Sendable {
    var image: Data
    var loginURL: URL?
    var deadline: Date
}

enum LoginChallenge: Sendable {
    case session(XiaomiSession)
    case captcha(Data)
    case twoFactor(hint: String)
}

struct PropReading: Sendable {
    var did: String
    var siid: Int
    var piid: Int
    var code: Int
    var value: JSONScalar?
}

/// 小米账号登录和米家云端设备接口。
/// 登录过程直接访问 account.xiaomi.com / api.io.mi.com，密码只留在内存里用来换会话。
final class XiaomiCloudClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let cookies: HTTPCookieStorage
    private var session: URLSession!
    private let lock = NSLock()
    private var followRedirects = true
    private var pragma: String?

    private var agent = ""
    private var deviceId = ""
    private var region = "cn"
    private var sign: String?
    private var username = ""
    private var password = ""
    private var ssecurity: String?
    private var userId: String?
    private var cUserId: String?
    private var serviceToken: String?
    private var longPollURL: URL?
    private var qrDeadline = Date.distantPast
    private var twoFactorContext: String?
    private var twoFactorFlag = 8

    override init() {
        cookies = HTTPCookieStorage()
        cookies.cookieAcceptPolicy = .always
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = cookies
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let value = response.value(forHTTPHeaderField: "extension-pragma") {
            lock.lock()
            pragma = value
            lock.unlock()
        }
        lock.lock()
        let follow = followRedirects
        lock.unlock()
        completionHandler(follow ? request : nil)
    }

    // MARK: Login

    func beginQRLogin(region: String) async throws -> QRTicket {
        resetSession()
        self.region = region
        primeCookies(username: nil)
        let fields: [(String, String)] = [
            ("_qrsize", "480"),
            // qs 先按小米网页的样子写成百分号编码，formEncode 会再编码一次，和现有开源登录实现一致。
            ("qs", "%3Fsid%3Dxiaomiio%26_json%3Dtrue"),
            ("callback", "https://sts.api.io.mi.com/sts"),
            ("_hasLogo", "false"),
            ("sid", "xiaomiio"),
            ("serviceParam", ""),
            ("_locale", "zh_CN"),
            ("_dc", String(Int(Date().timeIntervalSince1970 * 1000))),
        ]
        var components = URLComponents(string: "https://account.xiaomi.com/longPolling/loginUrl")
        components?.percentEncodedQuery = XiaomiCrypto.formEncode(fields)
        guard let url = components?.url else { throw XiaomiError.failed("无法开始扫码登录") }
        let (data, _) = try await getRaw(url.absoluteString, follow: true)
        let json = try parse(data)
        guard let qr = json["qr"] as? String, let lp = json["lp"] as? String, let lpURL = URL(string: lp) else {
            throw XiaomiError.failed("没有拿到登录二维码")
        }
        longPollURL = lpURL
        let timeout = jsonDouble(json["timeout"]) ?? 180
        let seconds = timeout > 1_000 ? timeout / 1_000 : timeout
        qrDeadline = Date().addingTimeInterval(min(max(seconds, 30), 300))
        let image = try await download(absoluteAccountURL(qr))
        let loginURL = (json["loginUrl"] as? String).flatMap(URL.init(string:))
        return QRTicket(image: image, loginURL: loginURL, deadline: qrDeadline)
    }

    func waitForQR() async throws -> XiaomiSession {
        guard let url = longPollURL else {
            throw XiaomiError.failed("二维码还没有准备好")
        }
        while Date() < qrDeadline {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
            do {
                let (data, http) = try await send(request, followRedirects: true)
                guard http.statusCode == 200, let json = try? parse(data) else { continue }
                guard jsonString(json["ssecurity"]) != nil else { continue }
                absorb(json)
                if let location = jsonString(json["location"]) {
                    try await exchange(location: location)
                }
                guard let session = currentSession() else {
                    throw XiaomiError.failed("扫码成功，但没有拿到米家会话")
                }
                return session
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .timedOut {
                continue
            }
        }
        throw XiaomiError.failed("二维码已过期，请刷新后再试")
    }

    func beginPasswordLogin(region: String, username: String, password: String) async throws -> LoginChallenge {
        resetSession()
        self.region = region
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
        primeCookies(username: self.username)
        if let early = try await loginStep1() {
            return early
        }
        let json = try await postAuth(captcha: nil)
        return try await interpret(json)
    }

    func submitCaptcha(_ code: String) async throws -> LoginChallenge {
        let json = try await postAuth(captcha: code.trimmingCharacters(in: .whitespacesAndNewlines))
        return try await interpret(json)
    }

    func submitTwoFactor(_ code: String) async throws -> LoginChallenge {
        guard let context = twoFactorContext else {
            throw XiaomiError.failed("验证流程已中断，请重新登录")
        }
        let endpoint = twoFactorFlag == 4
            ? "https://account.xiaomi.com/identity/auth/verifyPhone"
            : "https://account.xiaomi.com/identity/auth/verifyEmail"
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "_flag", value: String(twoFactorFlag)),
            URLQueryItem(name: "_json", value: "true"),
            URLQueryItem(name: "sid", value: "xiaomiio"),
            URLQueryItem(name: "context", value: context),
            URLQueryItem(name: "mask", value: "0"),
            URLQueryItem(name: "_locale", value: "zh_CN"),
        ]
        guard let url = components?.url else { throw XiaomiError.failed("无法提交验证码") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(XiaomiCrypto.formEncode([
            ("_flag", String(twoFactorFlag)),
            ("ticket", code.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("trust", "false"),
            ("_json", "true"),
            ("ick", cookie("ick") ?? ""),
        ]).utf8)
        let (data, http) = try await send(request, followRedirects: false)
        let json = try? parse(data)
        if let code = json.flatMap({ jsonInt($0["code"]) }), code != 0 {
            let desc = (json?["desc"] as? String) ?? (json?["description"] as? String) ?? "验证码不正确"
            throw XiaomiError.failed(desc)
        }
        let location = json.flatMap { jsonString($0["location"]) }
            ?? http.value(forHTTPHeaderField: "Location")
            ?? locationInHTML(data)
            ?? fallbackCheckURL(context: context)
        let session = try await finishTwoFactor(startLocation: location)
        password = ""
        return .session(session)
    }

    // MARK: Devices

    func fetchHomes(account: LinkedAccount) async throws -> [IoTHome] {
        guard let session = account.xiaomi else {
            throw XiaomiError.failed("这个小米账号还没有会话")
        }
        do {
            let structured = try await fetchStructured(account: account, session: session)
            let count = structured.reduce(0) { $0 + $1.devices.count }
            if count == 0, let legacy = try? await fetchLegacy(account: account, session: session), !legacy.devices.isEmpty {
                return [legacy]
            }
            return structured
        } catch XiaomiError.sessionExpired {
            throw XiaomiError.sessionExpired
        } catch {
            if let legacy = try? await fetchLegacy(account: account, session: session), !legacy.devices.isEmpty {
                return [legacy]
            }
            throw error
        }
    }

    func getProperties(
        session: XiaomiSession,
        refs: [(did: String, siid: Int, piid: Int)]
    ) async throws -> [PropReading] {
        var output: [PropReading] = []
        var index = 0
        while index < refs.count {
            let end = min(index + 16, refs.count)
            let slice = refs[index..<end]
            let params = slice.map { ref in
                ["did": ref.did, "siid": ref.siid, "piid": ref.piid] as [String: Any]
            }
            let json = try await call(session, path: "/miotspec/prop/get", payload: ["params": params])
            output.append(contentsOf: parseReadings(json))
            index = end
        }
        return output
    }

    func setProperty(
        session: XiaomiSession,
        did: String,
        siid: Int,
        piid: Int,
        value: JSONScalar
    ) async throws {
        let json = try await call(session, path: "/miotspec/prop/set", payload: [
            "params": [[
                "did": did,
                "siid": siid,
                "piid": piid,
                "value": value.jsonObject,
            ] as [String: Any]],
        ])
        try ensureControlSucceeded(json)
    }

    func runAction(session: XiaomiSession, did: String, siid: Int, aiid: Int) async throws {
        let json = try await call(session, path: "/miotspec/action", payload: [
            "params": [
                "did": did,
                "siid": siid,
                "aiid": aiid,
                "in": [Any](),
            ] as [String: Any],
        ])
        try ensureControlSucceeded(json)
    }

    // MARK: Private login

    private func loginStep1() async throws -> LoginChallenge? {
        var components = URLComponents(string: "https://account.xiaomi.com/pass/serviceLogin")
        components?.queryItems = [
            URLQueryItem(name: "sid", value: "xiaomiio"),
            URLQueryItem(name: "_json", value: "true"),
        ]
        guard let url = components?.url else { throw XiaomiError.failed("无法连接小米账号") }
        let (data, _) = try await getRaw(url.absoluteString, follow: true)
        let json = try parse(data)
        if let sign = json["_sign"] as? String, !sign.isEmpty {
            self.sign = sign
            return nil
        }
        return try await interpret(json)
    }

    private func postAuth(captcha: String?) async throws -> [String: Any] {
        var fields: [(String, String)] = [
            ("sid", "xiaomiio"),
            ("hash", XiaomiCrypto.md5Upper(password)),
            ("callback", "https://sts.api.io.mi.com/sts"),
            ("qs", "%3Fsid%3Dxiaomiio%26_json%3Dtrue"),
            ("user", username),
        ]
        if let sign, !sign.isEmpty {
            fields.append(("_sign", sign))
        }
        fields.append(("_json", "true"))
        if let captcha, !captcha.isEmpty {
            fields.append(("captCode", captcha))
        }
        var components = URLComponents(string: "https://account.xiaomi.com/pass/serviceLoginAuth2")
        components?.percentEncodedQuery = XiaomiCrypto.formEncode(fields)
        guard let url = components?.url else { throw XiaomiError.failed("无法提交登录") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await send(request, followRedirects: false)
        return try parse(data)
    }

    private func interpret(_ json: [String: Any]) async throws -> LoginChallenge {
        if let captchaURL = jsonString(json["captchaUrl"]), !captchaURL.isEmpty {
            let image = try await download(absoluteAccountURL(captchaURL))
            return .captcha(image)
        }
        if let notificationURL = jsonString(json["notificationUrl"]), !notificationURL.isEmpty {
            return try await beginTwoFactor(notificationURL: notificationURL)
        }
        absorb(json)
        if let location = jsonString(json["location"]), ssecurity != nil {
            try await exchange(location: location)
            if let session = currentSession() {
                password = ""
                return .session(session)
            }
        }
        let code = jsonInt(json["code"])
        let desc = (json["desc"] as? String) ?? (json["tips"] as? String) ?? (json["description"] as? String)
        if code == 70016 || code == 70002 {
            throw XiaomiError.failed(desc ?? "账号或密码不正确")
        }
        if code == 87001 {
            throw XiaomiError.failed("验证码不正确")
        }
        if code == 20003 {
            throw XiaomiError.failed(desc ?? "找不到这个小米账号")
        }
        if let desc, let code, code != 0 {
            throw XiaomiError.failed(desc)
        }
        throw XiaomiError.failed(desc ?? "登录没有完成。可以改用扫码，或稍后再试")
    }

    private func beginTwoFactor(notificationURL: String) async throws -> LoginChallenge {
        let absolute = absoluteAccountURL(notificationURL)
        _ = try? await getRaw(absolute, follow: true)
        guard let context = URLComponents(string: absolute)?.queryItems?.first(where: { $0.name == "context" })?.value,
              !context.isEmpty else {
            throw XiaomiError.failed("小米要求二次验证。请改用米家扫码登录")
        }
        twoFactorContext = context
        var list = URLComponents(string: "https://account.xiaomi.com/identity/list")
        list?.queryItems = [
            URLQueryItem(name: "sid", value: "xiaomiio"),
            URLQueryItem(name: "context", value: context),
            URLQueryItem(name: "_locale", value: "zh_CN"),
        ]
        let flag: Int
        if let listURL = list?.url {
            let (data, _) = try await getRaw(listURL.absoluteString, follow: true)
            flag = detectFlag(data)
        } else {
            flag = 8
        }
        twoFactorFlag = flag
        try await sendTicket(flag: flag, context: context)
        let hint = flag == 4 ? "验证码已发到手机，填写短信里的数字" : "验证码已发到邮箱，填写邮件里的数字"
        return .twoFactor(hint: hint)
    }

    private func sendTicket(flag: Int, context: String) async throws {
        let endpoint = flag == 4
            ? "https://account.xiaomi.com/identity/auth/sendPhoneTicket"
            : "https://account.xiaomi.com/identity/auth/sendEmailTicket"
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "_dc", value: String(Int(Date().timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "sid", value: "xiaomiio"),
            URLQueryItem(name: "context", value: context),
            URLQueryItem(name: "mask", value: "0"),
            URLQueryItem(name: "_locale", value: "zh_CN"),
        ]
        guard let url = components?.url else { throw XiaomiError.failed("无法发送验证码") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(XiaomiCrypto.formEncode([
            ("retry", "0"),
            ("icode", ""),
            ("_json", "true"),
            ("ick", cookie("ick") ?? ""),
        ]).utf8)
        let (data, http) = try await send(request, followRedirects: true)
        if let json = try? parse(data), let code = jsonInt(json["code"]), code != 0 {
            let desc = (json["desc"] as? String) ?? (json["description"] as? String) ?? "验证码发送失败"
            throw XiaomiError.failed(desc)
        }
        guard http.statusCode == 200 else {
            throw XiaomiError.failed("验证码发送失败（\(http.statusCode)）")
        }
    }

    private func finishTwoFactor(startLocation: String) async throws -> XiaomiSession {
        var location = absoluteAccountURL(startLocation)
        var endURL = location
        if location.contains("identity/result/check") {
            let (data, http) = try await getRaw(location, follow: false)
            if let hop = http.value(forHTTPHeaderField: "Location"), !hop.isEmpty {
                endURL = absoluteAccountURL(hop)
            } else if let found = locationInHTML(data) {
                endURL = absoluteAccountURL(found)
            }
        }
        var (data, http) = try await getRaw(endURL, follow: false)
        if http.statusCode == 200, let text = String(data: data, encoding: .utf8), text.contains("Xiaomi Account - Tips") {
            (data, http) = try await getRaw(endURL, follow: false)
        }
        if let header = http.value(forHTTPHeaderField: "extension-pragma") ?? currentPragma(),
           let object = try? JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: Any],
           let secret = object["ssecurity"] as? String, secret.count > 4 {
            ssecurity = secret
        }
        guard ssecurity != nil else {
            throw XiaomiError.failed("二次验证已提交，但没有拿到登录凭证。请改用扫码登录")
        }
        var sts = http.value(forHTTPHeaderField: "Location")
        if sts == nil, let text = String(data: data, encoding: .utf8),
           let range = text.range(of: "https://sts.api.io.mi.com/sts") {
            let tail = text[range.lowerBound...]
            let end = tail.firstIndex(where: { "\"'< ".contains($0) }) ?? tail.endIndex
            sts = String(tail[..<end])
        }
        guard let sts else {
            throw XiaomiError.failed("二次验证后没有回到米家。请改用扫码登录")
        }
        try await exchange(location: sts)
        guard let session = currentSession() else {
            throw XiaomiError.failed("登录信息不完整。请改用扫码登录")
        }
        return session
    }

    private func exchange(location: String) async throws {
        _ = try await getRaw(absoluteAccountURL(location), follow: true)
        guard let token = cookie("serviceToken"), !token.isEmpty else {
            throw XiaomiError.failed("没有拿到米家服务凭证。请改用扫码登录")
        }
        serviceToken = token
        if userId == nil {
            userId = cookie("userId")
        }
    }

    private func absorb(_ json: [String: Any]) {
        if let secret = jsonString(json["ssecurity"]), secret.count > 4 {
            ssecurity = secret
        }
        if let uid = jsonString(json["userId"]), !uid.isEmpty {
            userId = uid
        }
        if let cUser = json["cUserId"] as? String, !cUser.isEmpty {
            cUserId = cUser
        }
    }

    private func currentSession() -> XiaomiSession? {
        guard let ssecurity, let userId, let serviceToken,
              ssecurity.count > 4, !serviceToken.isEmpty, !userId.isEmpty else { return nil }
        return XiaomiSession(
            userId: userId,
            ssecurity: ssecurity,
            serviceToken: serviceToken,
            cUserId: cUserId,
            server: region,
            deviceId: deviceId,
            userAgent: agent
        )
    }

    private func resetSession() {
        cookies.cookies?.forEach { cookies.deleteCookie($0) }
        agent = XiaomiCrypto.randomAgent()
        deviceId = XiaomiCrypto.randomDeviceID()
        sign = nil
        username = ""
        password = ""
        ssecurity = nil
        userId = nil
        cUserId = nil
        serviceToken = nil
        longPollURL = nil
        twoFactorContext = nil
        twoFactorFlag = 8
    }

    private func primeCookies(username: String?) {
        setCookie("sdkVersion", "accountsdk-18.8.15", domain: ".mi.com")
        setCookie("sdkVersion", "accountsdk-18.8.15", domain: ".xiaomi.com")
        setCookie("deviceId", deviceId, domain: ".mi.com")
        setCookie("deviceId", deviceId, domain: ".xiaomi.com")
        guard let username, !username.isEmpty else { return }
        setCookie("userId", username, domain: ".xiaomi.com")
        setCookie("userId", username, domain: ".account.xiaomi.com")
    }

    // MARK: Homes

    private struct HomeRef {
        var id: String
        var name: String
        var owner: String
        var rooms: [RoomRef]
    }

    private struct RoomRef {
        var id: String
        var name: String
        var dids: [String]
    }

    private struct ParsedDevice {
        var did: String
        var name: String
        var model: String
        var online: Bool
        var specType: String?
        var localIP: String?
        var roomId: String?
    }

    private func fetchStructured(account: LinkedAccount, session: XiaomiSession) async throws -> [IoTHome] {
        let json = try await call(session, path: "/v2/homeroom/gethome", payload: [
            "fg": true,
            "fetch_share": true,
            "fetch_share_dev": true,
            "limit": 300,
            "app_ver": 7,
        ])
        let result = json["result"] as? [String: Any] ?? [:]
        var refs = parseHomeList(result["homelist"], session: session)
        let known = Set(refs.map(\.id))
        refs.append(contentsOf: await sharedHomes(session: session, existing: known))
        var homes: [IoTHome] = []
        for ref in refs {
            do {
                let listed = try await deviceList(session: session, home: ref)
                homes.append(makeHome(account: account, ref: listed.home, devices: listed.devices))
            } catch XiaomiError.sessionExpired {
                throw XiaomiError.sessionExpired
            } catch {
                homes.append(makeHome(account: account, ref: ref, devices: []))
            }
        }
        return homes
    }

    private func fetchLegacy(account: LinkedAccount, session: XiaomiSession) async throws -> IoTHome {
        let json = try await call(session, path: "/home/device_list", payload: [
            "getVirtualModel": true,
            "getHuamiDevices": 1,
            "get_split_device": false,
            "support_smart_home": true,
        ])
        let result = json["result"] as? [String: Any] ?? [:]
        let raw = (result["list"] as? [Any]) ?? []
        let devices = raw.compactMap { item -> ParsedDevice? in
            guard let row = item as? [String: Any] else { return nil }
            return parseDevice(row)
        }
        let ref = HomeRef(id: "all", name: "米家", owner: session.userId, rooms: [])
        return makeHome(account: account, ref: ref, devices: devices)
    }

    private func deviceList(session: XiaomiSession, home: HomeRef) async throws -> (home: HomeRef, devices: [ParsedDevice]) {
        let json = try await call(session, path: "/v2/home/home_device_list", payload: [
            "home_owner": numberOrString(home.owner),
            "home_id": numberOrString(home.id),
            "limit": 200,
            "get_split_device": true,
            "support_smart_home": true,
        ])
        var updated = home
        let result = json["result"] as? [String: Any] ?? [:]
        if let info = result["home_info"] as? [String: Any] {
            let rooms = parseRooms(info["roomlist"])
            if !rooms.isEmpty {
                updated.rooms = rooms
            }
            if let name = info["name"] as? String, !name.isEmpty {
                updated.name = name
            }
        }
        let raw = (result["device_info"] as? [Any]) ?? (result["list"] as? [Any]) ?? []
        let devices = raw.compactMap { item -> ParsedDevice? in
            guard let row = item as? [String: Any] else { return nil }
            return parseDevice(row)
        }
        return (updated, devices)
    }

    private func sharedHomes(session: XiaomiSession, existing: Set<String>) async -> [HomeRef] {
        guard let json = try? await call(session, path: "/v2/user/get_device_cnt", payload: [
            "fetch_own": true,
            "fetch_share": true,
        ]) else { return [] }
        guard let result = json["result"] as? [String: Any],
              let share = result["share"] as? [String: Any],
              let families = share["share_family"] as? [Any] else { return [] }
        var refs: [HomeRef] = []
        for item in families {
            guard let row = item as? [String: Any] else { continue }
            let id = jsonString(row["home_id"]) ?? ""
            if id.isEmpty || existing.contains(id) { continue }
            let owner = jsonString(row["home_owner"]) ?? session.userId
            let name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "共享家庭"
            refs.append(HomeRef(id: id, name: name, owner: owner, rooms: []))
        }
        return refs
    }

    private func parseHomeList(_ raw: Any?, session: XiaomiSession) -> [HomeRef] {
        guard let list = raw as? [Any] else { return [] }
        return list.compactMap { item in
            guard let row = item as? [String: Any] else { return nil }
            let id = jsonString(row["id"]) ?? ""
            if id.isEmpty { return nil }
            let name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "我的家"
            let uid = jsonString(row["uid"]) ?? session.userId
            let shareFlag = jsonInt(row["shareflag"]) ?? 0
            let owner = shareFlag == 0 ? session.userId : uid
            return HomeRef(id: id, name: name, owner: owner, rooms: parseRooms(row["roomlist"]))
        }
    }

    private func parseRooms(_ raw: Any?) -> [RoomRef] {
        guard let list = raw as? [Any] else { return [] }
        return list.compactMap { item in
            guard let row = item as? [String: Any] else { return nil }
            let id = jsonString(row["id"]) ?? jsonString(row["room_id"]) ?? jsonString(row["roomid"]) ?? ""
            if id.isEmpty { return nil }
            let name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "房间"
            let dids = (row["dids"] as? [Any])?.compactMap { jsonString($0) } ?? []
            return RoomRef(id: id, name: name, dids: dids)
        }
    }

    private func parseDevice(_ item: [String: Any]) -> ParsedDevice? {
        guard let did = jsonString(item["did"]), !did.isEmpty else { return nil }
        let model = (item["model"] as? String) ?? ""
        let rawName = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = rawName.isEmpty ? (model.isEmpty ? "未命名设备" : model) : rawName
        let spec = (item["spec_type"] as? String) ?? (item["specType"] as? String)
        return ParsedDevice(
            did: did,
            name: name,
            model: model,
            online: onlineFlag(item),
            specType: (spec?.isEmpty == false) ? spec : nil,
            localIP: item["localip"] as? String,
            roomId: jsonString(item["room_id"]) ?? jsonString(item["roomid"]) ?? jsonString(item["rid"])
        )
    }

    private func makeHome(account: LinkedAccount, ref: HomeRef, devices: [ParsedDevice]) -> IoTHome {
        var names: [String: String] = [:]
        var order: [String] = []
        var didRoom: [String: String] = [:]
        for room in ref.rooms {
            names[room.id] = room.name
            order.append(room.id)
            for did in room.dids where didRoom[did] == nil {
                didRoom[did] = room.id
            }
        }
        var buckets: [String: [IoTDevice]] = [:]
        for device in devices {
            let roomId: String
            if let rid = device.roomId, names[rid] != nil {
                roomId = rid
            } else if let mapped = didRoom[device.did] {
                roomId = mapped
            } else {
                roomId = "unassigned"
            }
            if names[roomId] == nil {
                names[roomId] = "未分配房间"
                order.append(roomId)
            }
            let iot = IoTDevice(
                id: "\(account.id.uuidString)|xiaomi|\(device.did)",
                did: device.did,
                name: device.name,
                model: device.model,
                online: device.online,
                specType: device.specType,
                localIP: device.localIP,
                roomName: names[roomId] ?? "未分配房间",
                homeName: ref.name,
                homeId: ref.id,
                accountId: account.id,
                platform: .xiaomi,
                category: DeviceCategory.resolve(model: device.model, specType: device.specType),
                power: nil
            )
            buckets[roomId, default: []].append(iot)
        }
        let rooms = order.compactMap { id -> IoTRoom? in
            let list = (buckets[id] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            guard !list.isEmpty else { return nil }
            return IoTRoom(id: "\(account.id.uuidString)|\(ref.id)|\(id)", name: names[id] ?? "房间", devices: list)
        }
        let finalRooms = rooms.isEmpty
            ? [IoTRoom(id: "\(account.id.uuidString)|\(ref.id)|empty", name: "全部设备", devices: [])]
            : rooms
        return IoTHome(
            id: "\(account.id.uuidString)|xiaomi|\(ref.id)",
            homeId: ref.id,
            name: ref.name,
            platform: .xiaomi,
            accountId: account.id,
            rooms: finalRooms
        )
    }

    private func onlineFlag(_ item: [String: Any]) -> Bool {
        if item["isOnline"] == nil && item["online"] == nil { return true }
        for key in ["isOnline", "online"] {
            guard let value = item[key] else { continue }
            if isJSONBool(value) { return (value as! NSNumber).boolValue }
            if let number = value as? NSNumber { return number.intValue != 0 }
            if let text = value as? String {
                return text == "1" || text.lowercased() == "true"
            }
        }
        return false
    }

    // MARK: API

    private func call(_ session: XiaomiSession, path: String, payload: [String: Any]) async throws -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: body, encoding: .utf8) else {
            throw XiaomiError.failed("请求参数无法编码")
        }
        let url = XiaomiCrypto.apiBase(server: session.server) + path
        let nonce = XiaomiCrypto.nonce()
        let signed = try XiaomiCrypto.signedNonce(ssecurity: session.ssecurity, nonce: nonce)
        let fields = try XiaomiCrypto.encryptedFields(
            url: url,
            method: "POST",
            signedNonce: signed,
            nonce: nonce,
            dataJSON: json,
            ssecurity: session.ssecurity
        )
        guard let endpoint = URL(string: url) else { throw XiaomiError.failed("米家接口地址无效") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(XiaomiCrypto.formEncode(fields).utf8)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(session.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("PROTOCAL-HTTP2", forHTTPHeaderField: "x-xiaomi-protocal-flag-cli")
        request.setValue("ENCRYPT-RC4", forHTTPHeaderField: "MIOT-ENCRYPT-ALGORITHM")
        request.setValue(cookieHeader(session), forHTTPHeaderField: "Cookie")
        let (data, http) = try await send(request, followRedirects: true)
        guard http.statusCode == 200 else {
            xiaomiLog.error("mi home http \(http.statusCode, privacy: .public) \(path, privacy: .public)")
            throw XiaomiError.failed("米家接口暂时不可用（\(http.statusCode)）")
        }
        let object: [String: Any]
        do {
            object = try decodeAPI(data, signedNonce: signed)
        } catch {
            xiaomiLog.error("mi home decrypt failed \(path, privacy: .public)")
            throw XiaomiError.invalidResponse
        }
        try validate(object)
        return object
    }

    private func decodeAPI(_ data: Data, signedNonce: String) throws -> [String: Any] {
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.hasPrefix("{") || text.hasPrefix("&&&START&&&") {
            return try parse(data)
        }
        let plain = try XiaomiCrypto.decryptRC4(passwordBase64: signedNonce, payloadBase64: text)
        guard let body = plain.data(using: .utf8) else { throw XiaomiError.invalidResponse }
        return try parse(body)
    }

    private func validate(_ object: [String: Any]) throws {
        let message = (object["message"] as? String) ?? ""
        let lowered = message.lowercased()
        if lowered.contains("servicetoken") || message.uppercased().contains("EXPIRED") {
            throw XiaomiError.sessionExpired
        }
        if lowered.contains("invalid signature") || lowered.contains("auth err") {
            throw XiaomiError.failed(message.isEmpty ? "米家拒绝了这次请求" : message)
        }
        if let code = jsonInt(object["code"]), code != 0 {
            throw XiaomiError.failed(message.isEmpty ? "米家接口返回 \(code)" : message)
        }
    }

    private func ensureControlSucceeded(_ object: [String: Any]) throws {
        if let result = object["result"] as? [String: Any], let code = jsonInt(result["code"]), code != 0, code != 1 {
            throw XiaomiError.failed(controlMessage(code))
        }
        if let result = object["result"] as? [Any] {
            for item in result {
                guard let row = item as? [String: Any], let code = jsonInt(row["code"]) else { continue }
                if code != 0 && code != 1 {
                    throw XiaomiError.failed(controlMessage(code))
                }
            }
        }
    }

    private func controlMessage(_ code: Int) -> String {
        switch code {
        case -704010000, -704042011:
            "设备离线，或不在这个账号下"
        case -704002000, -704030013:
            "设备暂时没有响应"
        default:
            "控制没有成功（\(code)）"
        }
    }

    private func parseReadings(_ object: [String: Any]) -> [PropReading] {
        guard let result = object["result"] as? [Any] else { return [] }
        return result.compactMap { item in
            guard let row = item as? [String: Any], let did = jsonString(row["did"]) else { return nil }
            return PropReading(
                did: did,
                siid: jsonInt(row["siid"]) ?? 0,
                piid: jsonInt(row["piid"]) ?? 0,
                code: jsonInt(row["code"]) ?? -1,
                value: JSONScalar.from(row["value"])
            )
        }
    }

    // MARK: HTTP

    private func send(_ request: URLRequest, followRedirects follow: Bool) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        followRedirects = follow
        pragma = nil
        lock.unlock()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw XiaomiError.invalidResponse }
        return (data, http)
    }

    private func getRaw(_ urlString: String, follow: Bool) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: urlString) else { throw XiaomiError.failed("地址无效") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        return try await send(request, followRedirects: follow)
    }

    private func download(_ urlString: String) async throws -> Data {
        let (data, http) = try await getRaw(urlString, follow: true)
        guard http.statusCode == 200, !data.isEmpty else {
            throw XiaomiError.failed("图片加载失败")
        }
        return data
    }

    private func parse(_ data: Data) throws -> [String: Any] {
        guard var text = String(data: data, encoding: .utf8) else { throw XiaomiError.invalidResponse }
        if let range = text.range(of: "&&&START&&&") {
            text = String(text[range.upperBound...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let body = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw XiaomiError.invalidResponse
        }
        return object
    }

    private func cookie(_ name: String) -> String? {
        cookies.cookies?.last(where: { $0.name == name })?.value
    }

    private func setCookie(_ name: String, _ value: String, domain: String) {
        let properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain,
            .path: "/",
            .name: name,
            .value: value,
            .secure: true,
        ]
        guard let cookie = HTTPCookie(properties: properties) else { return }
        cookies.setCookie(cookie)
    }

    private func cookieHeader(_ session: XiaomiSession) -> String {
        let seconds = TimeZone.current.secondsFromGMT()
        let hours = seconds / 3600
        let minutes = abs(seconds / 60) % 60
        let zone = String(format: "GMT%+03d:%02d", hours, minutes)
        return [
            "userId=\(session.userId)",
            "serviceToken=\(session.serviceToken)",
            "yetAnotherServiceToken=\(session.serviceToken)",
            "locale=zh_CN",
            "timezone=\(zone)",
            "is_daylight=0",
            "dst_offset=0",
            "channel=MI_APP_STORE",
        ].joined(separator: "; ")
    }

    private func currentPragma() -> String? {
        lock.lock()
        let value = pragma
        lock.unlock()
        return value
    }

    private func absoluteAccountURL(_ raw: String) -> String {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return raw }
        if raw.hasPrefix("//") { return "https:" + raw }
        if raw.hasPrefix("/") { return "https://account.xiaomi.com" + raw }
        return "https://account.xiaomi.com/" + raw
    }

    private func detectFlag(_ data: Data) -> Int {
        guard let json = try? parse(data) else { return 8 }
        let nested = json["data"] as? [String: Any]
        let options = (json["options"] as? [Any]) ?? (nested?["options"] as? [Any]) ?? []
        let numbers = options.compactMap { jsonInt($0) ?? Int(jsonString($0) ?? "") }
        if let flag = jsonInt(json["flag"]) ?? nested.flatMap({ jsonInt($0["flag"]) }), flag == 4 || flag == 8 {
            return flag
        }
        if numbers.contains(4), !numbers.contains(8) { return 4 }
        return 8
    }

    private func locationInHTML(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let needles = ["https://account.xiaomi.com/identity/result/check", "https://sts.api.io.mi.com/sts"]
        for needle in needles {
            guard let range = text.range(of: needle) else { continue }
            let tail = text[range.lowerBound...]
            let end = tail.firstIndex(where: { "\"'< ".contains($0) }) ?? tail.endIndex
            return String(tail[..<end])
        }
        return nil
    }

    private func fallbackCheckURL(context: String) -> String {
        var components = URLComponents(string: "https://account.xiaomi.com/identity/result/check")
        components?.queryItems = [
            URLQueryItem(name: "sid", value: "xiaomiio"),
            URLQueryItem(name: "context", value: context),
            URLQueryItem(name: "_locale", value: "zh_CN"),
        ]
        return components?.url?.absoluteString ?? "https://account.xiaomi.com/identity/result/check"
    }

    private func numberOrString(_ raw: String) -> Any {
        if let value = Int64(raw) { return NSNumber(value: value) }
        return raw
    }

    private func jsonDouble(_ any: Any?) -> Double? {
        if let value = any as? Double { return value }
        if let value = any as? Int { return Double(value) }
        if let number = any as? NSNumber, !isJSONBool(number) { return number.doubleValue }
        if let text = any as? String { return Double(text) }
        return nil
    }
}
