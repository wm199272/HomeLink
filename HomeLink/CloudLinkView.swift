import SwiftUI
import UIKit

struct CloudLinkView: View {
    @Environment(AppModel.self) private var model
    var platform: PlatformKind
    @State private var link = CloudLinkModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(intro)
                    .foregroundStyle(.secondary)
                if link.phase == .captcha {
                    captchaForm
                } else {
                    accountForm
                }
                if let message = link.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.paper)
        .navigationTitle(platform.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var accountPrompt: String {
        switch platform {
        case .mai: "邮箱或手机号"
        case .midea, .haier, .broad: "手机号"
        default: "手机号、邮箱或用户名"
        }
    }

    private var intro: String {
        switch platform {
        case .gree:
            "使用格力+的账号登录。地区要和 App 里一致，大陆账号选中国大陆。密码只用来换会话，不会保存。"
        case .qihoo:
            "使用 360 智慧生活的手机号、邮箱或用户名。登录后可以同步该账号下的设备；扫地机器人可以开始清扫、暂停和回充。"
        case .deye:
            "使用德业智能的手机号和密码。新协议的除湿机可以开关、调节模式、湿度和风速。"
        case .broad:
            "使用远大空气管家的账号和密码。密码只用来换会话。登录后同步这个账号下的设备。"
        case .midea:
            "使用美的美居的手机号和密码。登录后按家庭同步设备；读到开关状态的设备可以开关。"
        case .haier:
            "使用海尔智家 App 的账号和密码。登录后同步设备名称和在线状态。"
        case .mai:
            "使用 70 迈账号。公开的云端接口在 eu-api.70mai.com。登录后列出这个账号下的记录仪。"
        default:
            "登录后同步这个平台里的设备。"
        }
    }

    private var accountForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            if platform == .gree {
                Picker("地区", selection: Binding(get: { link.region }, set: { link.region = $0 })) {
                    ForEach(GreeRegion.allCases) { region in
                        Text(region.title).tag(region)
                    }
                }
                .pickerStyle(.menu)
            }
            TextField(accountPrompt, text: Binding(get: { link.username }, set: { link.username = $0 }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            SecureField("密码", text: Binding(get: { link.password }, set: { link.password = $0 }))
                .textFieldStyle(.roundedBorder)
            Button(link.isBusy ? "正在登录" : "登录并关联") {
                Task { await submit() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(link.isBusy || link.username.trimmingCharacters(in: .whitespaces).isEmpty || link.password.isEmpty)
        }
    }

    private var captchaForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("360 要求先填写图中的验证码。")
                .foregroundStyle(.secondary)
            if let image = link.captchaImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 88)
            }
            TextField("验证码", text: Binding(get: { link.captchaCode }, set: { link.captchaCode = $0 }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Button(link.isBusy ? "正在验证" : "继续") {
                Task { await submit() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(link.isBusy || link.captchaCode.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func submit() async {
        guard !link.isBusy else { return }
        link.isBusy = true
        link.message = nil
        defer { link.isBusy = false }
        do {
            switch platform {
            case .gree:
                let session = try await GreeCloudClient.login(region: link.region, username: link.username, password: link.password)
                link.password = ""
                model.link(LinkedAccount(
                    id: UUID(),
                    platform: .gree,
                    displayName: maskedAccount(link.username, empty: "格力用户"),
                    region: link.region.rawValue,
                    linkedAt: Date(),
                    needsRelogin: false,
                    gree: session
                ))
            case .qihoo:
                if link.identity == nil { link.identity = QihooCloudClient.makeIdentity() }
                guard let identity = link.identity else { return }
                let captcha = link.captchaSC.map { (sc: $0, code: link.captchaCode.trimmingCharacters(in: .whitespaces)) }
                switch try await QihooCloudClient.login(username: link.username, password: link.password, device: identity, captcha: captcha) {
                case let .session(session):
                    link.password = ""
                    link.captchaCode = ""
                    model.link(LinkedAccount(
                        id: UUID(),
                        platform: .qihoo,
                        displayName: maskedAccount(link.username, empty: "360 用户"),
                        region: nil,
                        linkedAt: Date(),
                        needsRelogin: false,
                        qihoo: session
                    ))
                case let .captcha(data, sc):
                    link.captchaSC = sc
                    link.captchaImage = UIImage(data: data)
                    link.captchaCode = ""
                    link.phase = .captcha
                    link.message = "请填写验证码"
                }
            case .deye:
                let session = try await DeyeCloudClient.login(username: link.username, password: link.password)
                link.password = ""
                model.link(LinkedAccount(
                    id: UUID(),
                    platform: .deye,
                    displayName: maskedAccount(link.username, empty: "德业用户"),
                    region: nil,
                    linkedAt: Date(),
                    needsRelogin: false,
                    deye: session
                ))
            case .broad:
                let logged = try await BroadCloudClient.login(username: link.username, password: link.password)
                link.password = ""
                model.link(LinkedAccount(
                    id: UUID(),
                    platform: .broad,
                    displayName: logged.displayName,
                    region: nil,
                    linkedAt: Date(),
                    needsRelogin: false,
                    broad: logged.session
                ))
            case .midea:
                let logged = try await MideaCloudClient.login(username: link.username, password: link.password)
                link.password = ""
                model.link(LinkedAccount(
                    id: UUID(),
                    platform: .midea,
                    displayName: logged.displayName,
                    region: nil,
                    linkedAt: Date(),
                    needsRelogin: false,
                    midea: logged.session
                ))
            case .haier:
                let logged = try await HaierCloudClient.login(username: link.username, password: link.password)
                link.password = ""
                model.link(LinkedAccount(
                    id: UUID(),
                    platform: .haier,
                    displayName: logged.displayName,
                    region: nil,
                    linkedAt: Date(),
                    needsRelogin: false,
                    haier: logged.session
                ))
            case .mai:
                let logged = try await MaiCloudClient.login(username: link.username, password: link.password)
                link.password = ""
                model.link(LinkedAccount(
                    id: UUID(),
                    platform: .mai,
                    displayName: logged.displayName,
                    region: nil,
                    linkedAt: Date(),
                    needsRelogin: false,
                    mai: logged.session
                ))
            default:
                break
            }
        } catch {
            link.message = humanize(error)
        }
    }
}

@MainActor
@Observable
final class CloudLinkModel {
    enum Phase { case form, captcha }

    var username = ""
    var password = ""
    var region: GreeRegion = .cn
    var phase: Phase = .form
    var captchaImage: UIImage?
    var captchaCode = ""
    var captchaSC: String?
    var identity: QihooDeviceIdentity?
    var isBusy = false
    var message: String?
}
