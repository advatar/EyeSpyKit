import SwiftUI
import EyeTrackCore

public struct GazeOverlayView: View {
    private let samples: AsyncStream<GazeSample>
    @State private var point: CGPoint?
    public init(samples: AsyncStream<GazeSample>) { self.samples = samples }
    public var body: some View {
        GeometryReader { _ in
            if let point {
                Circle().fill(Color.red.opacity(0.7)).frame(width: 18, height: 18).position(point)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task { for await sample in samples { point = sample.viewportPoint.cgPoint } }
    }
}

/// Place over the exact viewport supplied to the controller. Start the provider first.
public struct CalibrationView: View {
    private let rawStream: AsyncStream<RawGazeMeasurement>
    private let viewport: ViewportGeometry
    private let completion: (CalibrationModel, CalibrationSnapshot) -> Void
    private let targets: [GazePoint] = [
        .init(x: 0.1, y: 0.1), .init(x: 0.5, y: 0.1), .init(x: 0.9, y: 0.1),
        .init(x: 0.9, y: 0.5), .init(x: 0.5, y: 0.5), .init(x: 0.1, y: 0.5),
        .init(x: 0.1, y: 0.9), .init(x: 0.5, y: 0.9), .init(x: 0.9, y: 0.9)
    ]
    @State private var index = 0
    @State private var observations: [CalibrationObservation] = []
    @State private var frames: [[Double]] = []
    @State private var targetSince = DispatchTime.now().uptimeNanoseconds
    @State private var message = "Look at the dot. Hold your head still."
    @State private var completed = false
    public init(rawStream: AsyncStream<RawGazeMeasurement>, viewport: ViewportGeometry,
                completion: @escaping (CalibrationModel, CalibrationSnapshot) -> Void) {
        self.rawStream = rawStream; self.viewport = viewport; self.completion = completion
    }
    public var body: some View {
        ZStack {
            Color.black.opacity(0.85)
            if !completed {
                Circle().fill(Color.yellow).frame(width: 24, height: 24)
                    .position(x: targets[index].x * viewport.sizePoints.width,
                              y: targets[index].y * viewport.sizePoints.height)
            }
            VStack {
                Text(message).foregroundStyle(.white).padding()
                Text("Target \(index + 1) of \(targets.count) · \(frames.count)/20 samples")
                    .foregroundStyle(.white)
                Spacer()
                Button("Restart calibration") { reset() }.padding()
            }
        }
        .task {
            targetSince = DispatchTime.now().uptimeNanoseconds
            for await measurement in rawStream {
                guard !Task.isCancelled else { break }
                collect(measurement)
            }
        }
    }
    private func reset() {
        index = 0; observations = []; frames = []; completed = false
        targetSince = DispatchTime.now().uptimeNanoseconds
        message = "Look at the dot. Hold your head still."
    }
    private func collect(_ raw: RawGazeMeasurement) {
        guard !completed, viewport.isValid, raw.isValid, raw.confidence >= 0.5,
              raw.timestampNanos > targetSince, raw.timestampNanos - targetSince > 700_000_000 else { return }
        if let first = frames.first, first.count != raw.features.count { frames = [] }
        frames.append(raw.features)
        guard frames.count >= 20 else { return }
        // A per-target median reduces blink/landmark outliers and weights targets equally.
        let features = (0..<raw.features.count).map { j in frames.map { $0[j] }.sorted()[frames.count / 2] }
        observations.append(.init(features: features, target: targets[index]))
        frames = []
        if index + 1 < targets.count { index += 1; targetSince = DispatchTime.now().uptimeNanoseconds }
        else {
            do {
                let snapshot = CalibrationSnapshot(observations: observations)
                let model = try snapshot.fittedModel()
                completed = true; completion(model, snapshot)
            } catch { message = error.localizedDescription + " Press Restart calibration."; completed = true }
        }
    }
}
