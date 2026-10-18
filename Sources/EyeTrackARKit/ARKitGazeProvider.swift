import EyeTrackCore
import EyeTrackVisionCamera
#if os(iOS)
import ARKit
import ImageIO

@MainActor public final class ARKitGazeProvider: GazeProvider {
    private let worker = FaceWorker()
    private var generation: UInt64 = 0
    private var starting = false
    private var running = false
    public var errors: AsyncStream<String> { worker.errors.stream() }
    public static var isSupported: Bool { ARFaceTrackingConfiguration.isSupported }
    public init() {}
    public func makeRawMeasurementsStream() -> AsyncStream<RawGazeMeasurement> { worker.output.stream() }
    public func start() async throws {
        guard !starting else { throw EyeTrackingError.capture("Camera startup is still in progress.") }
        guard !running else { return }
        guard Self.isSupported else { throw EyeTrackingError.unsupported }
        starting = true; generation &+= 1
        let run = generation
        defer { starting = false }
        try await CameraAuthorization.request()
        guard generation == run, !Task.isCancelled else { throw CancellationError() }
        let configuration = ARFaceTrackingConfiguration()
        configuration.maximumNumberOfTrackedFaces = 1
        worker.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        running = true
    }
    public func stop() { generation &+= 1; running = false; worker.session.pause() }
}

private final class FaceWorker: NSObject, ARSessionDelegate, @unchecked Sendable {
    let session = ARSession()
    let output = SampleBroadcaster<RawGazeMeasurement>()
    let errors = SampleBroadcaster<String>()
    override init() {
        super.init(); session.delegate = self
        session.delegateQueue = DispatchQueue(label: "EyeTrackKit.arkit")
    }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard case .normal = session.currentFrame?.camera.trackingState,
              let face = anchors.compactMap({ $0 as? ARFaceAnchor }).first, face.isTracked else { return }
        let blink = max(face.blendShapes[.eyeBlinkLeft]?.doubleValue ?? 0,
                        face.blendShapes[.eyeBlinkRight]?.doubleValue ?? 0)
        guard blink < 0.5 else { return }
        // Transform the estimated fixation point into camera coordinates. This includes
        // head pose rather than treating a face-local direction as a screen direction.
        guard let frame = session.currentFrame else { return }
        let fixation = simd_inverse(frame.camera.transform) * face.transform * SIMD4<Float>(face.lookAtPoint, 1)
        let eyePosition = (face.leftEyeTransform.columns.3 + face.rightEyeTransform.columns.3) / 2
        let origin = simd_inverse(frame.camera.transform) * face.transform * SIMD4<Float>(eyePosition.x, eyePosition.y, eyePosition.z, 1)
        let direction = fixation - origin
        guard abs(direction.z) > 0.0001 else { return }
        output.yield(.init(features: [Double(direction.x / direction.z), Double(-direction.y / direction.z)], confidence: 1 - blink))
    }
    func session(_ session: ARSession, didFailWithError error: Error) { errors.yield(error.localizedDescription) }
    func sessionWasInterrupted(_ session: ARSession) { errors.yield("ARKit session interrupted. Stop and restart tracking.") }
    deinit { session.pause() }
}

/// Selects once at initialization. A runtime permission/capture error is surfaced, not hidden by fallback.
@MainActor public final class iOSBuiltInCameraGazeProvider: GazeProvider {
    private let provider: any GazeProvider
    public let usesARKit: Bool
    public init(visionOrientation: CGImagePropertyOrientation? = nil) {
        usesARKit = ARKitGazeProvider.isSupported
        provider = usesARKit ? ARKitGazeProvider() : VisionCameraGazeProvider(orientation: visionOrientation)
    }
    public var errors: AsyncStream<String> {
        if let arkit = provider as? ARKitGazeProvider { return arkit.errors }
        if let vision = provider as? VisionCameraGazeProvider { return vision.errors }
        return AsyncStream { $0.finish() }
    }
    public func makeRawMeasurementsStream() -> AsyncStream<RawGazeMeasurement> { provider.makeRawMeasurementsStream() }
    public func start() async throws { try await provider.start() }
    public func stop() { provider.stop() }
}
#endif
