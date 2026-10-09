import Foundation

public struct Point: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Quartz global points: top-left origin, positive y down. Origins can be negative.
public struct Rect: Codable, Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
    public func contains(_ point: Point) -> Bool {
        isValid && point.x.isFinite && point.y.isFinite && point.x >= x && point.y >= y && point.x < x + width && point.y < y + height
    }
    public func contains(_ other: Rect) -> Bool {
        isValid && other.isValid && other.x >= x && other.y >= y && other.x + other.width <= x + width && other.y + other.height <= y + height
    }
}

public struct TargetSnapshot: Codable, Sendable, Equatable {
    public var windowID: UInt32, pid: Int32, bundleID: String, displayID: UInt32
    public var bounds: Rect, displayBounds: Rect, scale: Double
    public var isVisible: Bool, isFrontmost: Bool
    public init(windowID: UInt32, pid: Int32, bundleID: String, displayID: UInt32, bounds: Rect, displayBounds: Rect, scale: Double, isVisible: Bool, isFrontmost: Bool) {
        self.windowID = windowID; self.pid = pid; self.bundleID = bundleID; self.displayID = displayID
        self.bounds = bounds; self.displayBounds = displayBounds; self.scale = scale
        self.isVisible = isVisible; self.isFrontmost = isFrontmost
    }
    public var isValid: Bool { windowID > 0 && pid > 0 && !bundleID.isEmpty && bounds.isValid && displayBounds.isValid && scale.isFinite && scale > 0 }
    /// Stable consent scope compares identity and layout. Visibility/focus must be
    /// checked separately at capture/dispatch; bringing the demo forward is allowed.
    public func matches(_ other: TargetSnapshot) -> Bool {
        windowID == other.windowID && pid == other.pid && bundleID == other.bundleID && displayID == other.displayID && bounds == other.bounds && displayBounds == other.displayBounds && scale == other.scale
    }
    enum CodingKeys: String, CodingKey {
        case windowID = "windowId", pid, bundleID = "bundleId", displayID = "displayId", bounds, displayBounds, scale, isVisible, isFrontmost
    }
}

public struct FrameRecord: Codable, Sendable, Equatable {
    public var frameID: String, sessionID: String
    public var target: TargetSnapshot
    /// Region relative to the selected window's top-left, in logical points.
    public var region: Rect
    public var pixelWidth: Int, pixelHeight: Int
    public var capturedAtUnixMS: Double, capturedAtMonotonic: Double, epoch: UInt64
    public init(frameID: String, sessionID: String, target: TargetSnapshot, region: Rect, pixelWidth: Int, pixelHeight: Int, capturedAtUnixMS: Double, capturedAtMonotonic: Double, epoch: UInt64) {
        self.frameID = frameID; self.sessionID = sessionID; self.target = target; self.region = region
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.capturedAtUnixMS = capturedAtUnixMS; self.capturedAtMonotonic = capturedAtMonotonic; self.epoch = epoch
    }
    public var isValid: Bool {
        !frameID.isEmpty && !sessionID.isEmpty && target.isValid && region.isValid && pixelWidth > 0 && pixelHeight > 0 && pixelWidth <= 16384 && pixelHeight <= 16384 && capturedAtUnixMS.isFinite && capturedAtMonotonic.isFinite && Rect(x: 0, y: 0, width: target.bounds.width, height: target.bounds.height).contains(region)
    }
    /// Pixel coordinates refer to the returned image, not the desktop or backing scale.
    /// Actual image dimensions account for crop and downsampling independently of Retina scale.
    public func globalPoint(pixel: Point) -> Point? {
        guard isValid, Rect(x: 0, y: 0, width: Double(pixelWidth), height: Double(pixelHeight)).contains(pixel) else { return nil }
        return Point(x: target.bounds.x + region.x + pixel.x * region.width / Double(pixelWidth), y: target.bounds.y + region.y + pixel.y * region.height / Double(pixelHeight))
    }
    public func pixelPoint(global: Point) -> Point? {
        guard isValid else { return nil }
        let crop = Rect(x: target.bounds.x + region.x, y: target.bounds.y + region.y, width: region.width, height: region.height)
        guard crop.contains(global) else { return nil }
        return Point(x: (global.x - crop.x) * Double(pixelWidth) / region.width, y: (global.y - crop.y) * Double(pixelHeight) / region.height)
    }
    enum CodingKeys: String, CodingKey {
        case frameID = "frameId", sessionID = "sessionId", target, region, pixelWidth, pixelHeight, capturedAtUnixMS = "capturedAtUnixMs", capturedAtMonotonic, epoch
    }
}
