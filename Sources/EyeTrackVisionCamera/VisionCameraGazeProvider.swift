import AVFoundation
import Vision
import ImageIO
import EyeTrackCore

@MainActor public enum CameraAuthorization {
    public static func request() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw EyeTrackingError.permissionDenied }
        default: throw EyeTrackingError.permissionDenied
        }
    }
}

/// Vision pupil position relative to each eye's contour; calibration supplies screen mapping.
@MainActor public final class VisionCameraGazeProvider: GazeProvider {
    private let worker: CameraWorker
    private var generation: UInt64 = 0
    private var starting = false
    private var running = false
    public var errors: AsyncStream<String> { worker.errors.stream() }
    public init(orientation: CGImagePropertyOrientation? = nil) {
        #if os(iOS)
        worker = CameraWorker(orientation: orientation ?? .leftMirrored)
        #else
        worker = CameraWorker(orientation: orientation ?? .upMirrored)
        #endif
    }
    public func makeRawMeasurementsStream() -> AsyncStream<RawGazeMeasurement> { worker.output.stream() }
    public func start() async throws {
        guard !starting else { throw EyeTrackingError.capture("Camera startup is still in progress.") }
        guard !running else { return }
        starting = true; generation &+= 1
        let run = generation
        defer { starting = false }
        try await CameraAuthorization.request()
        guard generation == run, !Task.isCancelled else { throw CancellationError() }
        try await worker.start()
        guard generation == run, !Task.isCancelled else { worker.stop(); throw CancellationError() }
        running = true
    }
    public func stop() { generation &+= 1; running = false; worker.stop() }
}

private final class CameraWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let output = SampleBroadcaster<RawGazeMeasurement>()
    let errors = SampleBroadcaster<String>()
    private let queue = DispatchQueue(label: "EyeTrackKit.camera")
    private let session = AVCaptureSession()
    private let orientation: CGImagePropertyOrientation
    private var configured = false
    private var errorObserver: NSObjectProtocol?
    init(orientation: CGImagePropertyOrientation) { self.orientation = orientation; super.init() }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    if !configured { try configure() }
                    if !session.isRunning { session.startRunning() }
                    guard session.isRunning else { throw EyeTrackingError.capture("Camera capture failed to start.") }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func stop() { queue.async { [self] in if session.isRunning { session.stopRunning() } } }
    private func configure() throws {
        #if os(iOS)
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        #else
        let device = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices.first
        #endif
        guard let device else { throw EyeTrackingError.cameraUnavailable }
        let input = try AVCaptureDeviceInput(device: device)
        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        video.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        guard session.canAddInput(input) else { throw EyeTrackingError.capture("Cannot add camera input.") }
        session.addInput(input)
        guard session.canAddOutput(video) else {
            session.removeInput(input); throw EyeTrackingError.capture("Cannot add camera output.")
        }
        session.addOutput(video)
        if let connection = video.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
        }
        errorObserver = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.errors.yield(error?.localizedDescription ?? "Camera runtime error.")
        }
        configured = true
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = DispatchTime.now().uptimeNanoseconds
        let request = VNDetectFaceLandmarksRequest()
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation).perform([request])
            // Multiple faces are ambiguous: never silently select somebody else's gaze.
            guard let faces = request.results, faces.count == 1, let face = faces.first,
                  let landmarks = face.landmarks,
                  let left = Self.relativePupil(landmarks.leftPupil, eye: landmarks.leftEye),
                  let right = Self.relativePupil(landmarks.rightPupil, eye: landmarks.rightEye) else { return }
            self.output.yield(.init(timestampNanos: timestamp,
                                    features: [(left.x + right.x) / 2, (left.y + right.y) / 2],
                                    confidence: Double(face.confidence)))
        } catch { errors.yield(error.localizedDescription) }
    }
    private static func relativePupil(_ pupil: VNFaceLandmarkRegion2D?, eye: VNFaceLandmarkRegion2D?) -> CGPoint? {
        guard let pupil, let eye, pupil.pointCount > 0, eye.pointCount >= 4 else { return nil }
        return PupilGeometry.relative(pupil: pupil.normalizedPoints[0], eye: eye.normalizedPoints)
    }

    deinit {
        if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) }
        if session.isRunning { session.stopRunning() }
    }
}
