import SwiftUI
import UIKit

@MainActor
@Observable
final class XiaomiLinkModel {
    var region = "cn"
    /// 小米确认页的地址。拿到它就可以在 App 内打开登录了。
    var loginURL: URL?
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
    private var rescueTask: Task<Void, Never>?
    private var backgroundedAt: Date?
    private var autoRefreshCount = 0
    private var ticker: Task<Void, Never>?
    private var completed = false

    func appear() {
        guard !completed else { return }
        dlog("--- 进入关联页（已有确认页地址=\(client.hasPendingQR)）---")
        // 已经有确认页地址并还在有效期内，就别重新申请（从确认页返回时会再次触发 onAppear）。
        if loginURL != nil {
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
        rescueTask?.cancel()
        stopTicker()
        isPolling = false
        isBusy = false
        // 页面走了就把确认页一起收掉，免得下次进来还挂着上一次的 sheet。
        showWebLogin = false
    }

    /// 切到后台/被挂起前记下时间，回前台时把这段时间从有效期里扣掉。
    func leftForeground() {
        backgroundedAt = Date()
    }

    func returnedToForeground() {
        guard !completed else { return }
        let away = backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
        backgroundedAt = nil
        client.extendQRDeadline(by: away)
        dlog("回到前台：离开 \(Int(away))s，已从期限里补回；isPolling=\(isPolling) isBusy=\(isBusy) 上次轮询响应 \(Int(Date().timeIntervalSince(client.lastPollActivity)))s 前")
        guard !isBusy else { return }
        // 回前台一律立刻重新轮询：挂起前那个在飞的请求已经被系统作废，
        // 指望它自己醒过来是等不到的（这就是「切回来没有任何反应」的原因）。
        // 用 hasPendingQR 而不是 hasActiveQR：用户可能在名义过期前一刻才确认。
        if loginURL != nil, client.hasPendingQR {
            resumeQR()
        } else if loginURL != nil || error != nil || notice != nil || pollTask == nil {
            startQR()
        }
    }

    /// 用户说「我已经确认了」，立刻再检查一次。
    func recheckNow() {
        guard !completed else { return }
        notice = "正在重新检查确认结果…"
        if loginURL != nil, client.hasPendingQR {
            // 用户已经确认过了，宽限一段时间，复用同一个 long polling 地址继续等。
            // 这里千万不能重新申请，否则会把刚确认的会话作废。
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
            dlog("网页 cookie 补齐了全部凭证，直接完成关联")
            finish(session)
            return
        }
        // 光有 serviceToken / userId 还不够，ssecurity 只能从账号接口拿。
        // 攒到 cookie 之后再用它们换一次完整会话；多次回调只跑最后一次。
        rescueTask?.cancel()
        rescueTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self else { return }
            dlog("尝试用网页 cookie 补 ssecurity 并完成会话")
            guard let session = await self.client.completeFromAccountCookies() else { return }
            guard !Task.isCancelled, !self.completed else { return }
            self.finish(session)
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

    func changeRegion(_ region: String) {
        self.region = region
        // 换地区要重新申请一张确认页，旧地址在新区是无效的。
        showWebLogin = false
        startQR()
    }

    /// 申请一张新的确认页（会作废当前 long polling 地址）。
    func startQR() {
        dlog("开始申请新的确认页（会作废现有 long polling）")
        error = nil
        notice = nil
        loginURL = nil
        autoRefreshCount = 0
        let previous = pollTask
        previous?.cancel()
        pollTask = Task {
            _ = await previous?.value
            guard !Task.isCancelled else { return }
            await runQR(reusingCode: false)
        }
    }

    /// 沿用当前确认页和 long polling 地址继续等，不重新申请。
    private func resumeQR() {
        dlog("沿用当前确认页继续轮询（不重新申请）")
        let previous = pollTask
        previous?.cancel()
        pollTask = Task {
            _ = await previous?.value
            guard !Task.isCancelled else { return }
            await runQR(reusingCode: true)
        }
    }

    /// - Parameter reusingCode: 为 true 表示沿用当前确认页和它的 long polling 地址，只接着等结果，
    ///   不要重新申请，否则会把用户刚在网页里确认的会话作废。
    private func runQR(reusingCode: Bool) async {
        dlog("runQR 开始（复用现有确认页=\(reusingCode)）")
        if !reusingCode {
            isBusy = true
            error = nil
        }
        do {
            if !reusingCode {
                let ticket = try await client.beginQRLogin(region: region)
                if Task.isCancelled { return }
                loginURL = ticket.loginURL
            }
            isBusy = false
            // 只有这一种关联方式了，地址一就绪就把确认页推出来，少一步点击。
            if !showWebLogin, !completed {
                showWebLogin = true
            }
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
            dlog("轮询任务结束（被取消）")
        } catch XiaomiError.qrExpired {
            isPolling = false
            stopTicker()
            dlog("确认页过期，自动换新（第 \(autoRefreshCount + 1) 次）")
            guard !Task.isCancelled else { return }
            // 过期不是失败：直接换一张新的，别让用户面对一个死掉的页面。
            if autoRefreshCount < 3 {
                autoRefreshCount += 1
                notice = "上一张确认页已过期，已经换成新的了，请重新登录确认"
                await runQR(reusingCode: false)
            } else {
                autoRefreshCount = 0
                isBusy = false
                error = "确认页一直过期，请检查网络后重试"
            }
        } catch {
            isPolling = false
            stopTicker()
            if !Task.isCancelled {
                dlog("登录失败：\(humanize(error))")
                self.error = humanize(error)
                isBusy = false
            }
        }
    }

    private func finish(_ session: XiaomiSession) {
        guard !completed else { return }
        autoRefreshCount = 0
        completed = true
        showWebLogin = false
        stopTicker()
        dlog("关联完成 userId=\(session.userId)")
        onSession?(session, "小米用户 \(session.userId.suffix(4))")
    }
}

struct XiaomiLinkView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var link = XiaomiLinkModel()
    @State private var showDiagnostics = false
    @State private var diagnosticsTick = 0
    @State private var copiedNotice = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("在 App 内打开小米的确认页，登录你自己的小米账号。")
                        .font(.subheadline)
                    Text("全程留在家联里，确认完会自动完成关联；换来的会话只保存在本机钥匙串，不会上传到其他服务器。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("地区", selection: Binding(
                    get: { link.region },
                    set: { link.changeRegion($0) }
                )) {
                    ForEach(XiaomiRegion.allCases) { region in
                        Text(region.title).tag(region.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Button {
                    link.showWebLogin = true
                } label: {
                    if link.loginURL == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("打开小米确认页并登录", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(link.loginURL == nil)

                if link.isPolling {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("等待确认中（已等 \(link.waitedSeconds) 秒），确认后会立刻完成关联")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

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

                if link.isPolling {
                    Button("我已经确认了，立即检查") { link.recheckNow() }
                        .buttonStyle(.bordered)
                        .font(.footnote)
                }

                diagnosticsPanel
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

    /// 诊断面板：登录卡住时把这里的内容复制出来，就能定位卡在哪一步。
    private var diagnosticsPanel: some View {
        DisclosureGroup(isExpanded: $showDiagnostics) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    Text(diagnosticsText)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                HStack(spacing: 10) {
                    Button("复制全部") {
                        UIPasteboard.general.string = diagnosticsText
                        copiedNotice = true
                    }
                    .buttonStyle(.bordered)
                    Button("清空") {
                        Diagnostics.shared.clear()
                        diagnosticsTick += 1
                    }
                    .buttonStyle(.bordered)
                }
                .font(.footnote)
                if copiedNotice {
                    Text("已复制，粘贴发给我即可")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("诊断信息（登录卡住时点开，复制给我）")
                .font(.footnote)
        }
        .task(id: showDiagnostics) {
            guard showDiagnostics else { return }
            // 面板打开时每秒刷新一次，好看到进度实时滚动。
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                diagnosticsTick += 1
            }
        }
    }

    private var diagnosticsText: String {
        _ = diagnosticsTick
        let lines = Diagnostics.shared.snapshot()
        return lines.isEmpty ? "（暂无记录）" : lines.joined(separator: "\n")
    }
}
