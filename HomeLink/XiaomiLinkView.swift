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
    var isBusy = false
    var onSession: ((XiaomiSession, String) -> Void)?

    private let client = XiaomiCloudClient()
    private var pollTask: Task<Void, Never>?

    enum Mode { case qr, password }
    enum Phase { case form, captcha, twoFactor }

    func appear() {
        guard mode == .qr, qrImage == nil else { return }
        startQR()
    }

    func stop() {
        pollTask?.cancel()
    }

    func select(_ mode: Mode) {
        guard self.mode != mode else { return }
        self.mode = mode
        error = nil
        phase = .form
        if mode == .qr {
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
        pollTask?.cancel()
        let previous = pollTask
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

    private func runQR() async {
        isBusy = true
        error = nil
        phase = .form
        do {
            let ticket = try await client.beginQRLogin(region: region)
            if Task.isCancelled { return }
            qrImage = UIImage(data: ticket.image)
            loginURL = ticket.loginURL
            isBusy = false
            let session = try await client.waitForQR()
            if Task.isCancelled { return }
            finish(session)
        } catch is CancellationError {
        } catch {
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
                Text(link.isBusy ? "正在准备二维码" : "等待手机确认")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("刷新二维码") { link.startQR() }
                .buttonStyle(.bordered)
            if let url = link.loginURL {
                Link("在浏览器中打开确认页", destination: url)
                    .font(.footnote)
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
