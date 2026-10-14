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
