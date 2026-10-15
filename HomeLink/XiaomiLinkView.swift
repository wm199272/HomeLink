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
    /// 在 App 内打开小米确认页，避免切到 Safari 后 App 被挂起、长轮询被打断。
    var showWebLogin = false
    /// 已经等了多久（秒），用来给用户可见的等待反馈。
    var waitedSeconds = 0
    var onSession: ((XiaomiSession, String) -> Void)?

    private let client = XiaomiCloudClient()
    private var pollTask: Task<Void, Never>?
    private var backgroundedAt: Date?
    private var autoRefreshCount = 0
    private var ticker: Task<Void, Never>?
    private var completed = false

    enum Mode { case qr, password }
    enum Phase { case form, captcha, twoFactor }

    func appear() {
        guard mode == .qr, !completed else { return }
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
        stopTicker()
        isPolling = false
        isBusy = false
    }

    /// 切到后台/被挂起前记下时间，回前台时把这段时间从二维码有效期里扣掉。
    func leftForeground() {
        backgroundedAt = Date()
    }

    func returnedToForeground() {
        guard mode == .qr, !completed else { return }
        let away = backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
        backgroundedAt = nil
        client.extendQRDeadline(by: away)
        guard !isBusy else { return }
        // 回前台一律立刻重新轮询：挂起前那个在飞的请求已经被系统作废，
        // 指望它自己醒过来是等不到的（这就是「切回来没有任何反应」的原因）。
        // 用 hasPendingQR 而不是 hasActiveQR：用户可能在名义过期前一刻才确认。
        if qrImage != nil, client.hasPendingQR {
            resumeQR()
        } else if qrImage != nil || error != nil || notice != nil || pollTask == nil {
            startQR()
        }
    }

    /// 用户说「我已经在浏览器里确认了」，立刻再检查一次。
    func recheckNow() {
        guard mode == .qr, !completed else { return }
        notice = "正在重新检查确认结果…"
        if qrImage != nil, client.hasPendingQR {
            // 用户已经确认过了，宽限一段时间，复用同一个 long polling 地址继续等。
            // 这里千万不能重新生成二维码，否则会把刚确认的会话作废。
            client.extendQRDeadline(by: 180)
            resumeQR()
        } else {
            startQR()
        }
    }

    /// 网页登录那边每加载完一页会把 cookie 递过来，交给会话保存。
    func absorbWebCookies(_ list: [HTTPCookie]) {
        client.absorbCookies(list)
        // 万一凭证已经齐了（比如长轮询结果早就到了），不用再等，直接完成关联。
        if !completed, let session = client.readySession {
            finish(session)
        }
    }

    private func startTicker() {
        stopTicker()
        waitedSeconds = 0
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                guard let self else { break }
                self.waitedSeconds += 1
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
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
            startTicker()
            let session: XiaomiSession
            do {
                session = try await client.waitForQR()
            } catch {
                isPolling = false
                stopTicker()
                throw error
            }
            isPolling = false
            stopTicker()
            if Task.isCancelled { return }
            finish(session)
        } catch is CancellationError {
            isPolling = false
            stopTicker()
            isBusy = false
        } catch XiaomiError.qrExpired {
            isPolling = false
            stopTicker()
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
            stopTicker()
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
        guard !completed else { return }
        autoRefreshCount = 0
        completed = true
        showWebLogin = false
        stopTicker()
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
        .sheet(isPresented: Binding(
            get: { link.showWebLogin },
            set: { link.showWebLogin = $0 }
        )) {
            if let url = link.loginURL {
                XiaomiWebLoginView(
                    url: url,
                    onCookies: { link.absorbWebCookies($0) },
                    onConfirmed: { link.recheckNow() },
                    onClose: {}
                )
            }
        }
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

    /// 二维码区域下方那行状态文字，让用户知道 App 一直在等，而不是「没反应」。
    private var statusLine: String {
        if link.isPolling {
            return "等待确认中（已等 \(link.waitedSeconds) 秒），确认后会立刻完成关联"
        }
        if link.isBusy {
            return "正在准备二维码…"
        }
        return "二维码已就绪"
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
            Text("用米家 App 扫这个二维码，或者在下方直接打开确认页登录。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if link.qrImage != nil && link.error == nil {
                HStack(spacing: 6) {
                    if link.isPolling {
                        ProgressView().controlSize(.mini)
                    }
                    Text(statusLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Button("刷新二维码") { link.startQR() }
                .buttonStyle(.bordered)
            if link.loginURL != nil {
                Button {
                    link.showWebLogin = true
                } label: {
                    Label("在 App 内打开确认页并登录", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(link.isBusy)
                Text("在 App 内登录最稳：全程留在前台，确认完会自动完成关联。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if link.isPolling {
                Button("我已经确认了，立即检查") { link.recheckNow() }
                    .buttonStyle(.bordered)
                    .font(.footnote)
            }
            if let url = link.loginURL {
                VStack(alignment: .leading, spacing: 4) {
                    Link("改用系统浏览器打开确认页", destination: url)
                        .font(.caption)
                    Text("外部浏览器里登录不会把凭证传回来，可能仍提示拿不到凭证；优先用上面的「在 App 内打开确认页并登录」。")
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
