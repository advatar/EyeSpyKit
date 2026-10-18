import XCTest
import CoreGraphics
@testable import EyeTrackCore

final class CalibrationTests: XCTestCase {
    func testFitsAffineMapAndRoundTripsSnapshot() throws {
        var observations: [CalibrationObservation] = []
        let values: [Double] = [-1, 0, 1]
        for x in values {
            for y in values {
                let targetX = 0.5 + 0.2 * x + 0.1 * y
                let targetY = 0.5 - 0.1 * x + 0.3 * y
                observations.append(.init(features: [x * 1000 + 7000, y * 0.01 - 2],
                    target: GazePoint(x: targetX, y: targetY)))
            }
        }
        let snapshot = CalibrationSnapshot(observations: observations)
        let restored = try JSONDecoder().decode(CalibrationSnapshot.self, from: JSONEncoder().encode(snapshot))
        let model = try restored.fittedModel()
        let prediction = try XCTUnwrap(model.predict([7500, -2.005]))
        XCTAssertEqual(prediction.x, 0.55, accuracy: 1e-8)
        XCTAssertEqual(prediction.y, 0.30, accuracy: 1e-8)
        let decoded = try JSONDecoder().decode(CalibrationModel.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(decoded, model)
        XCTAssertNil(model.predict([1]))
        XCTAssertNil(model.predict([.nan, 1]))
    }
    func testRejectsInsufficientDegenerateAndInvalidCalibration() throws {
        XCTAssertThrowsError(try CalibrationModel.fit([]))
        XCTAssertThrowsError(try CalibrationModel.fit([.init(features: [0, 0], target: .init(x: 0, y: 0))]))
        let collinear = (0..<9).map { i in CalibrationObservation(features: [Double(i), Double(i)*2], target: .init(x: 0.5, y: 0.5)) }
        XCTAssertThrowsError(try CalibrationModel.fit(collinear))
        let constant = (0..<9).map { _ in CalibrationObservation(features: [1, 1], target: .init(x: 0.5, y: 0.5)) }
        XCTAssertThrowsError(try CalibrationModel.fit(constant))
        var bad = collinear
        bad[0] = .init(features: [.infinity, 0], target: .init(x: 0, y: 0))
        XCTAssertThrowsError(try CalibrationModel.fit(bad))
        bad[0] = .init(features: [0], target: .init(x: 0, y: 0))
        XCTAssertThrowsError(try CalibrationModel.fit(bad))
        bad[0] = .init(features: [0, 0], target: .init(x: 2, y: 0))
        XCTAssertThrowsError(try CalibrationModel.fit(bad))
        XCTAssertThrowsError(try CalibrationModel(xCoefficients: [1, .nan], yCoefficients: [1, 2]))
        let future = Data(#"{"version":2,"observations":[]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CalibrationSnapshot.self, from: future).fittedModel())
    }
    func testSmoothingUsesTimeAndRejectsStaleSamples() throws {
        var smoother = GazeSmoother(timeConstant: 0.1)
        XCTAssertEqual(smoother.filter(.init(x: 0, y: 0), timestampNanos: 100), .init(x: 0, y: 0))
        XCTAssertNil(smoother.filter(.init(x: 1, y: 1), timestampNanos: 99))
        XCTAssertNil(smoother.filter(.init(x: .nan, y: 1), timestampNanos: 101))
        let point = try XCTUnwrap(smoother.filter(.init(x: 1, y: 1), timestampNanos: 100_000_100))
        XCTAssertEqual(point.x, 1-exp(-1), accuracy: 1e-10)
        XCTAssertEqual(smoother.filter(.init(x: 0, y: 1), timestampNanos: 2_000_000_000), .init(x: 0, y: 1))
        smoother.reset()
        XCTAssertEqual(smoother.filter(.init(x: 0.2, y: 0.4), timestampNanos: 1), .init(x: 0.2, y: 0.4))
    }
    func testMappingAndREADMEWireShape() throws {
        let viewport = ViewportGeometry(screenOriginPoints: CGPoint(x: -1000, y: -200),
            sizePoints: CGSize(width: 800, height: 600), pointsToPixelsScale: 2)
        let sample = GazeSample(timestampNanos: 123, confidence: 0.87, normalizedInViewport: .init(x: 0.25, y: 0.5), viewport: viewport)
        XCTAssertEqual(sample.viewportPoint, .init(x: 200, y: 300))
        XCTAssertEqual(sample.viewportPixel, .init(x: 400, y: 600))
        XCTAssertEqual(sample.screenPoint, .init(x: -800, y: 100))
        let data = try JSONEncoder().encode(sample)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["timestampNanos", "confidence", "normalizedInViewport", "viewportPoint", "viewportPixel", "screenPoint", "displayID", "displayPixel", "target"]))
        XCTAssertTrue(json["target"] is NSNull)
        XCTAssertTrue(json["displayID"] is NSNull)
        XCTAssertTrue(json["displayPixel"] is NSNull)
        XCTAssertEqual((json["viewportPoint"] as? [String: Double])?["x"], 200)
        XCTAssertEqual(try JSONDecoder().decode(GazeSample.self, from: data), sample)
        let target = GazeTarget(pid: 42, appName: "Safari", bundleID: "com.apple.Safari", windowID: 7,
            windowTitle: "Example", windowBoundsTopLeftPoints: GazeRect(CGRect(x: -30, y: 10, width: 100, height: 200)))
        let targetJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) as? [String: Any])
        XCTAssertEqual((targetJSON["windowBoundsTopLeftPoints"] as? [String: Double])?["width"], 100)
    }
    func testBroadcasterMulticastsAndBoundsSlowConsumers() async {
        let hub = SampleBroadcaster<Int>()
        var a = hub.stream().makeAsyncIterator()
        var b = hub.stream().makeAsyncIterator()
        hub.yield(1); hub.yield(2); hub.yield(3)
        let first = await a.next(), second = await b.next()
        XCTAssertEqual(first, 3); XCTAssertEqual(second, 3)
        hub.finish()
        let end = await a.next()
        XCTAssertNil(end)
        var restarted = hub.stream().makeAsyncIterator()
        hub.yield(4)
        let value = await restarted.next()
        XCTAssertEqual(value, 4)
    }
}

@MainActor private final class MockProvider: GazeProvider {
    let hub = SampleBroadcaster<RawGazeMeasurement>()
    var starts = 0
    var stops = 0
    var fail = false
    var suspendStart = false
    var pending: CheckedContinuation<Void, Never>?
    func makeRawMeasurementsStream() -> AsyncStream<RawGazeMeasurement> { hub.stream() }
    func start() async throws {
        starts += 1
        if fail { throw EyeTrackingError.cameraUnavailable }
        if suspendStart { await withCheckedContinuation { pending = $0 } }
    }
    func stop() { stops += 1 }
    func emit(_ features: [Double], time: UInt64 = DispatchTime.now().uptimeNanoseconds, confidence: Double = 1) {
        hub.yield(.init(timestampNanos: time, features: features, confidence: confidence))
    }
}
@MainActor private struct Resolver: GazeTargetResolving {
    func resolve(screenPoint: GazePoint) -> GazeTarget? { .init(pid: 42) }
}
@MainActor private struct PixelMapper: DisplayPixelMapping {
    func map(screenPoint: GazePoint) -> DisplayPixel? { .init(displayID: 7, point: .init(x: 10, y: 20)) }
}

final class ControllerTests: XCTestCase {
    @MainActor func testCalibrationGatingClampingMulticastAndRestart() async throws {
        let provider = MockProvider()
        let viewport = ViewportGeometry(screenOriginPoints: .zero, sizePoints: CGSize(width: 100, height: 200), pointsToPixelsScale: 2)
        let controller = EyeTrackerController(provider: provider, viewport: viewport, targetResolver: Resolver(), displayPixelMapper: PixelMapper(), smoothingTimeConstant: 0)
        var received: [GazeSample] = []
        let stream = controller.samples
        let reader = Task { for await sample in stream { received.append(sample) } }
        defer { reader.cancel(); controller.stop() }
        try await controller.start(); try await controller.start()
        XCTAssertEqual(provider.starts, 1)
        provider.emit([0.5, 0.5])
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(received.isEmpty)
        controller.setCalibration(try .init(xCoefficients: [0, 1, 0], yCoefficients: [0, 0, 1]))
        provider.emit([.nan, 0]); try await Task.sleep(nanoseconds: 5_000_000)
        provider.emit([0.5, 0.5], confidence: 0); try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertTrue(received.isEmpty)
        provider.emit([2, -1], time: 100)
        for _ in 0..<100 where received.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        let sample = try XCTUnwrap(received.first)
        XCTAssertEqual(sample.normalizedInViewport, .init(x: 1, y: 0))
        XCTAssertEqual(sample.viewportPixel, .init(x: 200, y: 0))
        XCTAssertEqual(sample.target?.pid, 42); XCTAssertEqual(sample.displayID, 7)
        provider.emit([0.5, 0.5], time: 99)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(received.count, 1)
        controller.stop()
        provider.emit([0.5, 0.5], time: 101)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(received.count, 1)
        try await controller.start()
        provider.emit([0.25, 0.75], time: 102)
        for _ in 0..<100 where received.count < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(provider.starts, 2)
        controller.setCalibration(nil)
        provider.emit([0.5, 0.5], time: 103)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(received.count, 2)
    }
    @MainActor func testInvalidGeometryAndFailedStartAreRecoverable() async throws {
        let provider = MockProvider()
        let controller = EyeTrackerController(provider: provider, viewport: .init(screenOriginPoints: .zero, sizePoints: .zero, pointsToPixelsScale: 2))
        do { try await controller.start(); XCTFail("Expected invalid viewport") } catch {}
        XCTAssertEqual(provider.starts, 0)
        controller.viewport.sizePoints = CGSize(width: 100, height: 100)
        provider.fail = true
        do { try await controller.start(); XCTFail("Expected camera error") } catch {}
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(provider.stops, 1)
        provider.fail = false
        try await controller.start()
        XCTAssertTrue(controller.isRunning)
        controller.stop()
    }
    @MainActor func testStopDuringPermissionWaitCannotLeaveCaptureRunning() async throws {
        let provider = MockProvider(); provider.suspendStart = true
        let controller = EyeTrackerController(provider: provider, viewport: .init(screenOriginPoints: .zero, sizePoints: CGSize(width: 100, height: 100), pointsToPixelsScale: 1))
        let start = Task { try await controller.start() }
        while provider.pending == nil { await Task.yield() }
        controller.stop()
        do { try await controller.start(); XCTFail("Overlapping startup should be rejected") } catch {}
        provider.pending?.resume(); provider.pending = nil
        try await start.value
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(provider.stops, 2)
        provider.suspendStart = false
        try await controller.start()
        XCTAssertTrue(controller.isRunning)
        controller.stop()
    }
}
