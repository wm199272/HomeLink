import SwiftUI
import WebKit

/// 在 App 内打开小米的确认页。
///
/// 为什么不用 Safari：`Link` 会把我们的 App 切到后台，系统随即挂起进程，
/// 正在飞的长轮询请求会被作废，回到前台时拿不到「已确认」的结果，
/// 表现就是「浏览器里登录成功，切回来没有任何反应」。
/// 用内嵌 WebView 全程留在前台，长轮询就能持续收到结果。
///
/// 另有一件必须做的事：`WKWebView` 有自己独立的 cookie 库，
/// 登录拿到的 serviceToken / userId / cUserId 只会落在那边，
/// 所以每加载完一页都把 cookie 交给外面，让 URLSession 也能带上这些凭证。
struct XiaomiWebLoginView: View {
    let url: URL
    let onCookies: ([HTTPCookie]) -> Void
    let onConfirmed: () -> Void
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isFinished = false

    var body: some View {
        NavigationStack {
            ZStack {
                XiaomiWebView(url: url, onCookies: onCookies) {
                    isFinished = true
                    onConfirmed()
                }
                .ignoresSafeArea(edges: .bottom)
                if isFinished {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("网页里已经确认，正在等小米把会话交过来…")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(24)
                }
            }
            .navigationTitle("在小米账号里确认")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        onClose()
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct XiaomiWebView: UIViewRepresentable {
    let url: URL
    let onCookies: ([HTTPCookie]) -> Void
    let onConfirmed: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCookies: onCookies, onConfirmed: onConfirmed)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onCookies: ([HTTPCookie]) -> Void
        private let onConfirmed: () -> Void
        private var notified = false

        init(onCookies: @escaping ([HTTPCookie]) -> Void, onConfirmed: @escaping () -> Void) {
            self.onCookies = onCookies
            self.onConfirmed = onConfirmed
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            harvest(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            harvest(webView)
        }

        /// 每加载完一页就把 cookie 搬一次，确认页会在登录过程中跳好几次，
        /// 这样等长轮询拿到结果时，我们这边已经握有 serviceToken 了。
        private func harvest(_ webView: WKWebView) {
            let current = webView.url?.absoluteString ?? ""
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.onCookies(cookies)
                    guard !self.notified else { return }
                    let hasToken = cookies.contains { $0.name == "serviceToken" && !$0.value.isEmpty }
                    dlog("网页加载完成 url=\(current) cookie=[\(cookieNameList(cookies))] serviceToken=\(hasToken)")
                    // 走到 sts 说明网页侧已经在换米家的服务凭证了，长轮询那边马上就有结果。
                    if hasToken || current.contains("/sts") {
                        self.notified = true
                        dlog("网页侧已确认，通知外部重新检查")
                        self.onConfirmed()
                    }
                }
            }
        }
    }
}
