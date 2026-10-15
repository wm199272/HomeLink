import SwiftUI

extension Color {
    static let moss = Color(red: 0.12, green: 0.42, blue: 0.35)
    static let clay = Color(red: 0.72, green: 0.36, blue: 0.22)

    static let paper = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.07, green: 0.08, blue: 0.08, alpha: 1)
            : UIColor(red: 0.95, green: 0.94, blue: 0.91, alpha: 1)
    })

    static let card = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.14, green: 0.15, blue: 0.14, alpha: 1)
            : UIColor.white
    })
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}

/// 按行折行的横向布局，标签放不下就换行。
///
/// 原来平台筛选用的是 `ScrollView(.horizontal)`：关联的平台一多，排在后面的
/// 直接被切在屏幕外，用户不滑一下就以为那个平台没关联上。换成折行后一眼全见。
struct WrapLayout: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 8

    private struct Line {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func measure(subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, current.width + spacing + size.width > maxWidth {
                lines.append(current)
                current = Line()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
            current.sizes.append(size)
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // 没给出可用宽度时（比如被放在无约束的容器里）就全部排成一行。
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let lines = measure(subviews: subviews, maxWidth: maxWidth)
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(lines.count - 1, 0))
        let width = proposal.width ?? (lines.map(\.width).max() ?? 0)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = measure(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for (offset, index) in line.indices.enumerated() {
                let size = line.sizes[offset]
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}
