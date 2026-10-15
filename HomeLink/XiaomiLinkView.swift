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

    enum Mode { case qr, password }
    enum Phase { case form, captcha, twoFactor }

    func appear() {
        guard mode == .qr else { return }
        // 已经有二维码并且轮询还活着，就别动它（从 Safari 返回时会再次触发 onAppear）。
        if qrImage != nil, isPolling || client.hasActiveQR { return }
        startQR()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
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
        guard !isPolling else { return }
        // 后台期间轮询要么被掐断、要么已经判过期，回到前台就重新挂上。
        if qrImage != nil || error != nil || notice != nil {
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

    func startQR() {
        error = nil
        notice = nil
        let previous = pollTask
        previous?.cancel()
        pollTask = Task {
            _ = await previous?.value
            guard !Task.isCancelled else { return }
            await runQR()
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

    private func runQR(autoRefreshes: Int = 0) async {
        isBusy = true
        error = nil
        phase = .form
        do {
            let ticket = try await client.beginQRLogin(region: region)
            if Task.isCancelled { return }
            qrImage = UIImage(data: ticket.image)
            loginURL = ticket.loginURL
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
            if autoRefreshes < 3 {
                notice = "上一张二维码已过期，已经换成新的了，请重新扫描"
                await runQR(autoRefreshes: autoRefreshes + 1)
            } else {
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
                Text(link.isPolling ? "等待手机确认，可以切到米家扫码，这里会一直等" : "正在准备二维码")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("刷新二维码") { link.startQR() }
                .buttonStyle(.bordered)
            if let url = link.loginURL {
                VStack(alignment: .leading, spacing: 4) {
                    Link("在浏览器中打开确认页", destination: url)
                        .font(.footnote)
                    Text("浏览器的确认页要求这个浏览器已经登录小米账号，否则会直接提示二维码过期；用米家扫描上面的二维码最稳。")
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
