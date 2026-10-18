import Foundation
import CoreGraphics

public struct GazePoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public init(_ point: CGPoint) { self.init(x: point.x, y: point.y) }
    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    public var isFinite: Bool { x.isFinite && y.isFinite }
}

public struct GazeRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(_ rect: CGRect) {
        x = rect.origin.x; y = rect.origin.y; width = rect.width; height = rect.height
    }
}

public struct GazeTarget: Codable, Sendable, Equatable {
    public var pid: Int32
    public var appName: String?
    public var bundleID: String?
    public var windowID: UInt32?
    public var windowTitle: String?
    public var windowBoundsTopLeftPoints: GazeRect?
    public init(pid: Int32, appName: String? = nil, bundleID: String? = nil,
                windowID: UInt32? = nil, windowTitle: String? = nil, windowBoundsTopLeftPoints: GazeRect? = nil) {
        self.pid = pid; self.appName = appName; self.bundleID = bundleID
        self.windowID = windowID; self.windowTitle = windowTitle
        self.windowBoundsTopLeftPoints = windowBoundsTopLeftPoints
    }
}

public struct RawGazeMeasurement: Codable, Sendable, Equatable {
    public let timestampNanos: UInt64
    public let features: [Double]
    public let confidence: Double
    public init(timestampNanos: UInt64 = DispatchTime.now().uptimeNanoseconds,
                features: [Double], confidence: Double) {
        self.timestampNanos = timestampNanos; self.features = features; self.confidence = confidence
    }
    public var isValid: Bool {
        !features.isEmpty && features.allSatisfy(\.isFinite) && confidence.isFinite && confidence > 0 && confidence <= 1
    }
}

public struct ViewportGeometry: Sendable, Equatable {
    public var screenOriginPoints: CGPoint
    public var sizePoints: CGSize
    public var pointsToPixelsScale: Double
    public init(screenOriginPoints: CGPoint, sizePoints: CGSize, pointsToPixelsScale: Double) {
        self.screenOriginPoints = screenOriginPoints; self.sizePoints = sizePoints
        self.pointsToPixelsScale = pointsToPixelsScale
    }
    public var isValid: Bool {
        screenOriginPoints.x.isFinite && screenOriginPoints.y.isFinite &&
        sizePoints.width.isFinite && sizePoints.height.isFinite && sizePoints.width > 0 && sizePoints.height > 0 &&
        pointsToPixelsScale.isFinite && pointsToPixelsScale > 0
    }
}

public struct DisplayPixel: Sendable, Equatable {
    public let displayID: UInt32
    public let point: GazePoint
    public init(displayID: UInt32, point: GazePoint) { self.displayID = displayID; self.point = point }
}

public struct GazeSample: Codable, Sendable, Equatable {
    public let timestampNanos: UInt64
    public let confidence: Double
    public let normalizedInViewport: GazePoint
    public let viewportPoint: GazePoint
    public let viewportPixel: GazePoint
    public let screenPoint: GazePoint
    public var displayID: UInt32?
    public var displayPixel: GazePoint?
    public var target: GazeTarget?

    public init(timestampNanos: UInt64, confidence: Double, normalizedInViewport: GazePoint,
                viewport: ViewportGeometry, display: DisplayPixel? = nil, target: GazeTarget? = nil) {
        self.timestampNanos = timestampNanos; self.confidence = confidence
        self.normalizedInViewport = normalizedInViewport
        viewportPoint = .init(x: normalizedInViewport.x * viewport.sizePoints.width,
                              y: normalizedInViewport.y * viewport.sizePoints.height)
        viewportPixel = .init(x: viewportPoint.x * viewport.pointsToPixelsScale,
                              y: viewportPoint.y * viewport.pointsToPixelsScale)
        screenPoint = .init(x: viewport.screenOriginPoints.x + viewportPoint.x,
                            y: viewport.screenOriginPoints.y + viewportPoint.y)
        displayID = display?.displayID; displayPixel = display?.point; self.target = target
    }

    enum CodingKeys: String, CodingKey {
        case timestampNanos, confidence, normalizedInViewport, viewportPoint, viewportPixel, screenPoint, displayID, displayPixel, target
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(timestampNanos, forKey: .timestampNanos)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(normalizedInViewport, forKey: .normalizedInViewport)
        try c.encode(viewportPoint, forKey: .viewportPoint)
        try c.encode(viewportPixel, forKey: .viewportPixel)
        try c.encode(screenPoint, forKey: .screenPoint)
        try c.encode(displayID, forKey: .displayID)
        try c.encode(displayPixel, forKey: .displayPixel)
        try c.encode(target, forKey: .target)
    }
}

public enum EyeTrackingError: Error, LocalizedError {
    case permissionDenied, cameraUnavailable, unsupported, invalidViewport, invalidCalibration, insufficientCalibration, capture(String)
    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Camera permission denied. Enable camera access in Settings."
        case .cameraUnavailable: return "No built-in camera is available."
        case .unsupported: return "Eye tracking is unavailable on this device."
        case .invalidViewport: return "Viewport dimensions and scale must be finite and positive."
        case .invalidCalibration: return "Calibration data is invalid or degenerate. Recalibrate with varied eye positions."
        case .insufficientCalibration: return "Not enough calibration samples."
        case .capture(let message): return message
        }
    }
}
