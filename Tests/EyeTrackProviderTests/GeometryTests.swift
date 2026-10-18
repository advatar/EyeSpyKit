import XCTest
import CoreGraphics
import EyeTrackCore
@testable import EyeTrackVisionCamera
@testable import EyeTrackMacWindowing

final class GeometryTests: XCTestCase {
    func testPupilFeaturesAreEyeRelativeAndYPointsDown() throws {
        let eye = [CGPoint(x: 0.2, y: 0.4), CGPoint(x: 0.6, y: 0.4), CGPoint(x: 0.6, y: 0.6), CGPoint(x: 0.2, y: 0.6)]
        let point = try XCTUnwrap(PupilGeometry.relative(pupil: CGPoint(x: 0.3, y: 0.55), eye: eye))
        XCTAssertEqual(point.x, 0.25, accuracy: 1e-8)
        XCTAssertEqual(point.y, 0.25, accuracy: 1e-8)
        let translated = eye.map { CGPoint(x: $0.x + 0.1, y: $0.y + 0.2) }
        let other = try XCTUnwrap(PupilGeometry.relative(pupil: CGPoint(x: 0.4, y: 0.75), eye: translated))
        XCTAssertEqual(other.x, point.x, accuracy: 1e-8)
        XCTAssertEqual(other.y, point.y, accuracy: 1e-8)
    }
    func testPupilGeometryRejectsClosedMissingAndNonfiniteEyes() {
        XCTAssertNil(PupilGeometry.relative(pupil: .zero, eye: []))
        XCTAssertNil(PupilGeometry.relative(pupil: .zero, eye: Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 4)))
        XCTAssertNil(PupilGeometry.relative(pupil: CGPoint(x: Double.nan, y: 0), eye: Array(repeating: .zero, count: 4)))
    }
    #if os(macOS)
    @MainActor func testDisplayPixelsForDisplaysLeftAndAbovePrimary() throws {
        let bounds = CGRect(x: -1280, y: -900, width: 1280, height: 900)
        let result = try XCTUnwrap(MacDisplayPixelMapper.map(screenPoint: .init(x: -640, y: -450),
            displayID: 9, bounds: bounds, pixelSize: CGSize(width: 2560, height: 1800)))
        XCTAssertEqual(result.displayID, 9)
        XCTAssertEqual(result.point, .init(x: 1280, y: 900))
        XCTAssertNil(MacDisplayPixelMapper.map(screenPoint: .init(x: 1, y: 1), displayID: 9,
            bounds: bounds, pixelSize: CGSize(width: 2560, height: 1800)))
        XCTAssertNil(MacDisplayPixelMapper.map(screenPoint: .init(x: -640, y: -450), displayID: 9,
            bounds: bounds, pixelSize: .zero))
    }
    #endif
}
