import SwiftUI
import UIKit

@MainActor
@Observable
final class XiaomiLinkModel {
    var region = "cn"
    var username = ""
    var password = ""
    var mode: Mode = .qr
    var phase: Phase = .form
    var qrImage: UIImage?
    var loginURL: URL?
    var captchaImage: UIImage?
    var captchaCode = ""
    var twoFactorCode = ""
    var twoFactorHint = ""
    var error: String?
    var notice: String?
    var isBusy = false
    var isPolling = false
    var onSession: ((XiaomiSession, String) -> Void)?

    private let client = XiaomiCloudClient()
    private var pollTask: Task<Void, Never>?
    private var backgroundedAt: Date?
    private var autoRefreshCount = 0

    enum Mode { case qr, password }
    enum Phase { case form, captcha, twoFactor }

    func appear() {
        guard mode == .qr else { return }
        // 已经有二维码并还在有效期内，就别重新生成（从 Safari 返回时会再次触发 onAppear）。
        if qrImage != nil {
            if isPolling || isBusy { return }
            if client.hasActiveQR {
                resumeQR()
            } else {
                startQR()
            }
            return
        }
        startQR()
    }

    func stop() {
        pollTask?.cancel()
        isPolling = false
        isBusy = false
    }

    /// 切到后台/被挂起前记下时间，回前台时把这段时间从二维码有效期里扣掉。
    func leftForeground() {
        backgroundedAt = Date()
    }

    func returnedToForeground() {
        guard mode == .qr else { return }
        let away = backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
        backgroundedAt = nil
        client.extendQRDeadline(by: away)
        // 轮询任务看着还活着，但可能卡在挂起前已经作废的那个请求上，太久没动静就重挂一次。
        if isPolling {
            if Date().timeIntervalSince(client.lastPollActivity) > 30 {
                resumeQR()
            }
            return
        }
        guard !isBusy else { return }
        // 关键：去浏览器确认过的那张二维码不能重新生成，否则会把已经确认的会话作废。
        // 只要还在有效期内，就复用同一个 long polling 地址继续等结果。
        if qrImage != nil, client.hasActiveQR {
            resumeQR()
        } else if qrImage != nil || error != nil || notice != nil || pollTask == nil {
            startQR()
        }
    }

    func select(_ mode: Mode) {
        guard self.mode != mode else { return }
        self.mode = mode
        error = nil
        notice = nil
        phase = .form
        if mode == .qr {
            qrImage = nil
            startQR()
        } else {
            stop()
        }
    }

    func changeRegion(_ region: String) {
        self.region = region
        guard mode == .qr else { return }
        startQR()
    }

    /// 换一张全新的二维码（会作废当前 long polling 地址）。
    func startQR() {
        error = nil
        notice = nil
        autoRefreshCount = 0
        let previous = pollTask
        previous?.cancel()
        pollTask = Task {
            _ = await previous?.value
            guard !Task.isCancelled else { return }
            await runQR(reusingCode: false)
        }
    }

    /// 沿用当前二维码和 long polling 地址继续等，不重新生成。
    private func resumeQR() {
        let previous = pollTask
        previous?.cancel()
        pollTask = Task {
            _ = await previous?.value
            guard !Task.isCancelled else { return }
            await runQR(reusingCode: true)
        }
    }

    func submitPassword() async {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else {
            error = "请填写小米账号和密码"
            return
        }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let challenge = try await client.beginPasswordLogin(region: region, username: username, password: password)
            apply(challenge)
        } catch {
            self.error = humanize(error)
        }
    }

    func submitCaptcha() async {
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let challenge = try await client.submitCaptcha(captchaCode)
            apply(challenge)
        } catch {
            self.error = humanize(error)
        }
    }

    func submitTwoFactor() async {
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let challenge = try await client.submitTwoFactor(twoFactorCode)
            apply(challenge)
        } catch {
            self.error = humanize(error)
        }
    }

    /// - Parameter reusingCode: 为 true 表示沿用当前二维码和它的 long polling 地址，只接着等结果，
    ///   不要重新向小米申请二维码，否则会把用户刚在浏览器里确认的会话作废。
    private func runQR(reusingCode: Bool) async {
        if !reusingCode {
            isBusy = true
            error = nil
            phase = .form
        }
        do {
            if !reusingCode {
                let ticket = try await client.beginQRLogin(region: region)
                if Task.isCancelled { return }
                qrImage = UIImage(data: ticket.image)
                loginURL = ticket.loginURL
            }
            isBusy = false
            isPolling = true
            let session: XiaomiSession
            do {
                session = try await client.waitForQR()
            } catch {
                isPolling = false
                throw error
            }
            isPolling = false
            if Task.isCancelled { return }
            finish(session)
        } catch is CancellationError {
            isPolling = false
            isBusy = false
        } catch XiaomiError.qrExpired {
            isPolling = false
            guard !Task.isCancelled else { return }
            // 过期不是失败：直接换一张新二维码，别让用户面对一个死掉的页面。
            if autoRefreshCount < 3 {
                autoRefreshCount += 1
                notice = "上一张二维码已过期，已经换成新的了，请重新扫描"
                await runQR(reusingCode: false)
            } else {
                autoRefreshCount = 0
                isBusy = false
                error = "二维码一直过期，请检查网络后点「刷新二维码」重试"
            }
        } catch {
            isPolling = false
            if !Task.isCancelled {
                self.error = humanize(error)
                isBusy = false
            }
        }
    }

    private func apply(_ challenge: LoginChallenge) {
        switch challenge {
        case let .session(session):
            finish(session)
        case let .captcha(data):
            captchaImage = UIImage(data: data)
            captchaCode = ""
            phase = .captcha
        case let .twoFactor(hint):
            twoFactorHint = hint
            twoFactorCode = ""
            phase = .twoFactor
        }
    }

    private func finish(_ session: XiaomiSession) {
        autoRefreshCount = 0
        let label = username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "小米用户 \(session.userId.suffix(4))"
            : maskedAccount(username)
        password = ""
        onSession?(session, label)
    }
}

struct XiaomiLinkView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var link = XiaomiLinkModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("登录后可以管理这个小米账号在米家中的设备。密码只用来向小米换取会话，不会上传到其他服务器，也不会写进手机。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("地区", selection: Binding(
                    get: { link.region },
                    set: { link.changeRegion($0) }
                )) {
                    ForEach(XiaomiRegion.allCases) { region in
                        Text(region.title).tag(region.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Picker("方式", selection: Binding(
                    get: { link.mode },
                    set: { link.select($0) }
                )) {
                    Text("扫码").tag(XiaomiLinkModel.Mode.qr)
                    Text("账号密码").tag(XiaomiLinkModel.Mode.password)
                }
                .pickerStyle(.segmented)

                if let error = link.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if let notice = link.notice, link.error == nil {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                switch link.phase {
                case .captcha:
                    captchaForm
                case .twoFactor:
                    twoFactorForm
                case .form:
                    if link.mode == .qr {
                        qrForm
                    } else {
                        passwordForm
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.paper)
        .navigationTitle("关联米家")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            link.onSession = { session, name in
                model.link(LinkedAccount(
                    id: UUID(),
                    platform: .xiaomi,
                    displayName: name,
                    region: link.region,
                    linkedAt: Date(),
                    needsRelogin: false,
                    xiaomi: session
                ))
            }
            link.appear()
        }
        .onDisappear {
            link.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                link.returnedToForeground()
            case .background:
                link.leftForeground()
            default:
                break
            }
        }
    }

    private var qrForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.card)
                    .frame(width: 240, height: 240)
                if let image = link.qrImage {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 210, height: 210)
                } else if link.isBusy {
                    ProgressView("正在获取二维码")
                } else {
                    Image(systemName: "qrcode")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            Text("打开米家或小米账号的扫一扫，扫描这个二维码并确认登录。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if link.qrImage != nil && link.error == nil {
                Text(link.isPolling ? "等待确认中，可以切到米家或浏览器操作，这里会一直等" : "正在准备二维码")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("刷新二维码") { link.startQR() }
                .buttonStyle(.bordered)
            if let url = link.loginURL {
                VStack(alignment: .leading, spacing: 4) {
                    Link("在浏览器中打开确认页", destination: url)
                        .font(.footnote)
                    Text("浏览器里登录/确认成功后，请回到本 App，这里会自动完成关联（确认结果是通过后台长连接回传的，浏览器不会自己跳回来）。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var passwordForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("手机号、邮箱或小米 ID", text: Binding(
                get: { link.username },
                set: { link.username = $0 }
            ))
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            SecureField("密码", text: Binding(
                get: { link.password },
                set: { link.password = $0 }
            ))
                .textContentType(.password)
                .padding(14)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button {
                Task { await link.submitPassword() }
            } label: {
                if link.isBusy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("登录")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(link.isBusy)
        }
    }

    private var captchaForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("小米要求填写验证码")
                .font(.headline)
            if let image = link.captchaImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 80)
            }
            TextField("验证码", text: Binding(
                get: { link.captchaCode },
                set: { link.captchaCode = $0 }
            ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button {
                Task { await link.submitCaptcha() }
            } label: {
                Text("提交验证码").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(link.isBusy || link.captchaCode.isEmpty)
        }
    }

    private var twoFactorForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("需要二次验证")
                .font(.headline)
            Text(link.twoFactorHint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("验证码", text: Binding(
                get: { link.twoFactorCode },
                set: { link.twoFactorCode = $0 }
            ))
                .keyboardType(.numberPad)
                .padding(14)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button {
                Task { await link.submitTwoFactor() }
            } label: {
                Text("完成验证").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(link.isBusy || link.twoFactorCode.isEmpty)
        }
    }
}
