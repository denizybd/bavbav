import SwiftUI

enum BavbavTheme {
    static let background = Color(red: 0.043, green: 0.051, blue: 0.063)
    static let surface = Color(red: 0.070, green: 0.082, blue: 0.102)
    static let raised = Color(red: 0.090, green: 0.106, blue: 0.129)
    static let border = Color(red: 0.145, green: 0.165, blue: 0.200)
    static let text = Color(red: 0.847, green: 0.875, blue: 0.914)
    static let muted = Color(red: 0.470, green: 0.510, blue: 0.565)
    static let accent = Color(red: 0.314, green: 0.886, blue: 0.722)
    static let cyan = Color(red: 0.310, green: 0.745, blue: 0.875)
    static let warning = Color(red: 0.945, green: 0.694, blue: 0.322)
    static let danger = Color(red: 0.930, green: 0.365, blue: 0.420)

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
