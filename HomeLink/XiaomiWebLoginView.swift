import SwiftUI
import WebKit

/// 在 App 内打开小米的确认页。
///
/// 为什么不用 Safari：`Link` 会把我们的 App 切到后台，系统随即挂起进程，
/// 正在飞的长轮询请求会被作废，回到前台时拿不到「已确认」的结果，
/// 表现就是「浏览器里登录成功，切回来没有任何反应」。
/// 用内嵌 WebView 全程留在前台，长轮询就能持续收到结果。
struct XiaomiWebLoginView: View {
    let url: URL
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isFinished = false

    var body: some View {
        NavigationStack {
            ZStack {
                XiaomiWebView(url: url) {
                    isFinished = true
                }
                .ignoresSafeArea(edges: .bottom)
                if isFinished {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("网页里已经确认，正在等小米把会话回传过来…")
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
    let onReachedCallback: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onReachedCallback: onReachedCallback)
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
        private let onReachedCallback: () -> Void
        private var notified = false

        init(onReachedCallback: @escaping () -> Void) {
            self.onReachedCallback = onReachedCallback
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !notified, let url = webView.url else { return }
            // 登录成功后小米会跳到 sts.api.io.mi.com 去换米家的服务凭证，
            // 走到这一步说明网页侧确认已经完成，长轮询那边马上就能拿到结果。
            let text = url.absoluteString
            if text.contains("sts.api.io.mi.com") || text.contains("/sts") {
                notified = true
                onReachedCallback()
            }
        }
    }
}
