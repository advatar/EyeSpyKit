import EyeTrackCore
#if os(macOS)
import AppKit
import ApplicationServices

@MainActor public enum MacPermissions {
    @discardableResult public static func requestAccessibilityIfNeeded(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
    }
}

@MainActor public final class MacDisplayPixelMapper: DisplayPixelMapping {
    public init() {}
    public func map(screenPoint: GazePoint) -> DisplayPixel? {
        guard screenPoint.isFinite else { return nil }
        // Quartz global points already have a top-left origin, including negative
        // origins for displays to the left or above the primary display.
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            let bounds = CGDisplayBounds(id)
            if let result = Self.map(screenPoint: screenPoint, displayID: id, bounds: bounds,
                                     pixelSize: CGSize(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id))) {
                return result
            }
        }
        return nil
    }
    static func map(screenPoint: GazePoint, displayID: UInt32, bounds: CGRect, pixelSize: CGSize) -> DisplayPixel? {
        guard screenPoint.isFinite, bounds.contains(screenPoint.cgPoint), bounds.width > 0, bounds.height > 0,
              pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        return DisplayPixel(displayID: displayID, point: .init(
            x: (screenPoint.x - bounds.minX) * pixelSize.width / bounds.width,
            y: (screenPoint.y - bounds.minY) * pixelSize.height / bounds.height))
    }
    /// Convert an AppKit global origin (bottom-left) into the package's global top-left coordinates.
    public static func topLeftOrigin(of frame: CGRect) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: frame.minX, y: primaryHeight - frame.maxY)
    }
}

@MainActor public final class MacTargetResolver: GazeTargetResolving {
    public init() {}
    public func resolve(screenPoint: GazePoint) -> GazeTarget? {
        guard screenPoint.isFinite else { return nil }
        if AXIsProcessTrusted(), let target = accessibilityTarget(at: screenPoint.cgPoint) { return target }
        return windowListTarget(at: screenPoint.cgPoint)
    }
    private func accessibilityTarget(at point: CGPoint) -> GazeTarget? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid > 0 else { return nil }
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        var window: AXUIElement?
        if let value = attribute(hit, kAXWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
            window = (value as! AXUIElement)
        } else if attribute(hit, kAXRoleAttribute) as? String == kAXWindowRole { window = hit }
        var bounds: GazeRect?
        if let window, let p = attribute(window, kAXPositionAttribute), let s = attribute(window, kAXSizeAttribute),
           CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() {
            var origin = CGPoint.zero; var size = CGSize.zero
            if AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size) {
                bounds = GazeRect(CGRect(origin: origin, size: size))
            }
        }
        let app = NSRunningApplication(processIdentifier: pid)
        // Public AX has no window-number attribute. Match the best-effort CG fallback by PID/bounds.
        let fallback = windowListTarget(at: point)
        return GazeTarget(pid: pid, appName: app?.localizedName, bundleID: app?.bundleIdentifier,
                          windowID: fallback?.pid == pid ? fallback?.windowID : nil,
                          windowTitle: window.flatMap { attribute($0, kAXTitleAttribute) as? String },
                          windowBoundsTopLeftPoints: bounds)
    }
    private func windowListTarget(at point: CGPoint) -> GazeTarget? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary), bounds.contains(point),
                  let pid = window[kCGWindowOwnerPID as String] as? Int32 else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            return GazeTarget(pid: pid, appName: app?.localizedName ?? window[kCGWindowOwnerName as String] as? String,
                              bundleID: app?.bundleIdentifier, windowID: window[kCGWindowNumber as String] as? UInt32,
                              windowTitle: window[kCGWindowName as String] as? String,
                              windowBoundsTopLeftPoints: GazeRect(bounds))
        }
        return nil
    }
}
#endif
