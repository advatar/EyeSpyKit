import Foundation

@MainActor public final class EyeTrackerController {
    public let provider: any GazeProvider
    public var viewport: ViewportGeometry { didSet { smoother.reset() } }
    public private(set) var isRunning = false
    public private(set) var calibration: CalibrationModel?
    public var samples: AsyncStream<GazeSample> { output.stream() }
    private let output = SampleBroadcaster<GazeSample>()
    private let targetResolver: (any GazeTargetResolving)?
    private let displayPixelMapper: (any DisplayPixelMapping)?
    private var smoother: GazeSmoother
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var isStarting = false
    public init(provider: any GazeProvider, viewport: ViewportGeometry,
                targetResolver: (any GazeTargetResolving)? = nil,
                displayPixelMapper: (any DisplayPixelMapping)? = nil, smoothingTimeConstant: Double = 0.08) {
        self.provider = provider; self.viewport = viewport
        self.targetResolver = targetResolver; self.displayPixelMapper = displayPixelMapper
        smoother = .init(timeConstant: smoothingTimeConstant)
    }
    public func setCalibration(_ model: CalibrationModel?) { calibration = model; smoother.reset() }
    public func start() async throws {
        guard !isStarting else { throw EyeTrackingError.capture("Camera startup is still in progress.") }
        guard !isRunning else { return }
        isStarting = true
        defer { isStarting = false }
        guard viewport.isValid else { throw EyeTrackingError.invalidViewport }
        generation &+= 1
        let run = generation
        isRunning = true
        let stream = provider.makeRawMeasurementsStream()
        task = Task { [weak self] in
            for await raw in stream {
                guard !Task.isCancelled, let self, self.generation == run else { break }
                self.consume(raw)
            }
        }
        do { try await provider.start() }
        catch { if generation == run { stop() }; throw error }
        // A stop during an asynchronous permission request must not leave capture running.
        if generation != run { provider.stop() }
    }
    public func stop() {
        generation &+= 1; isRunning = false
        task?.cancel(); task = nil; provider.stop(); smoother.reset()
    }
    private func consume(_ raw: RawGazeMeasurement) {
        guard isRunning, viewport.isValid, raw.isValid,
              let predicted = calibration?.predict(raw.features),
              let filtered = smoother.filter(predicted, timestampNanos: raw.timestampNanos) else { return }
        let point = GazePoint(x: min(1, max(0, filtered.x)), y: min(1, max(0, filtered.y)))
        var sample = GazeSample(timestampNanos: raw.timestampNanos, confidence: raw.confidence,
                                normalizedInViewport: point, viewport: viewport)
        if let display = displayPixelMapper?.map(screenPoint: sample.screenPoint) {
            sample.displayID = display.displayID; sample.displayPixel = display.point
        }
        sample.target = targetResolver?.resolve(screenPoint: sample.screenPoint)
        output.yield(sample)
    }
    deinit { task?.cancel() }
}
