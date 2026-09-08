import Foundation

extension Bundle {
    static let bavbavMathResources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("SwiftMath_SwiftMath.bundle"),
           let bundled = Bundle(url: url) {
            return bundled
        }
        return .module
    }()
}

/// Allows the packaged-app smoke check to verify it is not accidentally using
/// a development-directory resource fallback.
public enum SwiftMathResourceLocation {
    public static var bundleURL: URL { Bundle.bavbavMathResources.bundleURL }
}
