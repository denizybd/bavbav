import AppKit

extension Notification.Name {
    /// User-invoked browsing only. A URL object opens a page; nil opens the address field.
    static let bavbavOpenBrowser = Notification.Name("Bavbav.OpenBrowser")
    static let bavbavBrowserDirection = Notification.Name("Bavbav.BrowserDirection")
}
