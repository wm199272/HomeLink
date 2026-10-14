import SwiftUI

struct PlatformSelectView: View {
    enum Mode {
        case onboarding
        case add
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var mode: Mode
    @State private var pending: PlatformKind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("家联")
                        .font(.system(size: 40, weight: .semibold))
                    Text("选择要关联的平台。关联之后，可以查看并控制该账号里的设备。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 12)

                ForEach(PlatformKind.allCases) { kind in
                    if kind.isAvailable {
                        NavigationLink(value: kind) {
                            PlatformCard(kind: kind)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            pending = kind
                        } label: {
                            PlatformCard(kind: kind)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
        }
        .background(Color.paper)
        .navigationTitle(mode == .onboarding ? "" : "关联平台")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: PlatformKind.self) { kind in
            switch kind {
            case .xiaomi:
                XiaomiLinkView()
            case .gree, .qihoo, .deye, .broad, .midea, .haier, .mai:
                CloudLinkView(platform: kind)
            case .jbot:
                JbotLinkView()
            case .homekit:
                HomeKitLinkView()
            default:
                EmptyView()
            }
        }
        .toolbar {
            if mode == .add {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .alert("即将支持", isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text("\(pending?.title ?? "这个平台") 还没有稳定的公开授权。家联已经按平台留了适配层，接口可用后会和米家一样接入。")
        }
    }
}

struct PlatformCard: View {
    var kind: PlatformKind

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(0.14))
                Image(systemName: kind.symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(kind.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(kind.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: kind.isAvailable ? "chevron.right" : "clock")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .cardStyle()
    }

    private var tint: Color {
        switch kind {
        case .xiaomi: .clay
        case .gree: Color(red: 0.05, green: 0.45, blue: 0.62)
        case .qihoo: Color(red: 0.85, green: 0.45, blue: 0.12)
        case .deye: Color(red: 0.16, green: 0.36, blue: 0.72)
        case .broad: Color(red: 0.05, green: 0.55, blue: 0.48)
        case .midea: Color(red: 0.0, green: 0.45, blue: 0.78)
        case .haier: Color(red: 0.0, green: 0.48, blue: 0.72)
        case .jbot: Color(red: 0.18, green: 0.55, blue: 0.28)
        case .mai: Color(red: 0.85, green: 0.35, blue: 0.12)
        case .homekit: .moss
        default: .secondary
        }
    }
}

struct HomeKitLinkView: View {
    @Environment(AppModel.self) private var model

    private var linked: Bool {
        model.accounts.contains { $0.platform == .homekit }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("把已经加入 Apple「家庭」的灯、插座、传感器放到家联里一起看。")
                    .foregroundStyle(.secondary)
                Text(linked ? model.homeKitStatus : "点下面的按钮后，系统会询问是否允许访问家庭。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button(linked ? "重新同步家庭" : "允许并关联") {
                    model.linkHomeKit()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("免费 Apple ID 通常签不出 HomeKit 能力。真机若提示没有权限，用付费开发者账号在 Signing & Capabilities 里打开 HomeKit。米家关联不需要这个能力。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.paper)
        .navigationTitle("Apple 家庭")
        .navigationBarTitleDisplayMode(.inline)
    }
}
