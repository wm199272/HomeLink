import SwiftUI

struct PlatformManageView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false
    @State private var pendingUnlink: LinkedAccount?

    var body: some View {
        List {
            Section("已关联") {
                if model.accounts.isEmpty {
                    Text("还没有平台")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.accounts) { account in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.displayName)
                                .font(.headline)
                            Text("\(account.platform.title) · \(account.detail)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("\(model.deviceCount(for: account.id)) 个设备")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .swipeActions {
                            Button("解除", role: .destructive) {
                                pendingUnlink = account
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    showAdd = true
                } label: {
                    Label("关联平台", systemImage: "plus")
                }
            } footer: {
                Text("会话保存在本机钥匙串。解除关联只清掉家联里的登录状态，不会影响原来 App 里的设备。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.paper)
        .navigationTitle("平台")
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                PlatformSelectView(mode: .add)
            }
        }
        .onChange(of: model.linkGeneration) { _, _ in
            showAdd = false
        }
        .confirmationDialog(
            "解除\(pendingUnlink?.displayName ?? "这个账号")？",
            isPresented: Binding(
                get: { pendingUnlink != nil },
                set: { if !$0 { pendingUnlink = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("解除关联", role: .destructive) {
                if let pendingUnlink {
                    model.unlink(pendingUnlink.id)
                }
                pendingUnlink = nil
            }
            Button("取消", role: .cancel) {
                pendingUnlink = nil
            }
        }
    }
}
