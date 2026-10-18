import CoreGraphics

/// Vision landmarks are face-relative, bottom-left coordinates. Normalize to
/// the eye contour, invert y, and let calibration learn camera mirroring.
enum PupilGeometry {
    static func relative(pupil: CGPoint, eye: [CGPoint]) -> CGPoint? {
        guard eye.count >= 4, pupil.x.isFinite, pupil.y.isFinite,
              eye.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let xs = eye.map(\.x), ys = eye.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
              maxX - minX > 0.001, maxY - minY > 0.001 else { return nil }
        return CGPoint(x: (pupil.x - minX) / (maxX - minX), y: 1 - (pupil.y - minY) / (maxY - minY))
    }
}
