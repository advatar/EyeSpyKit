#if os(macOS)
import SwiftUI
import AppKit
import EyeTrackCore
import EyeTrackUI
import EyeTrackVisionCamera
import EyeTrackMacWindowing
import EyeSpyFeed

@main struct EyeSpyApp: App {
    @StateObject private var model = EyeSpyModel()
    var body: some Scene {
        Window("EyeSpy", id: "main") {
            ZStack {
                Color(NSColor.windowBackgroundColor)
                if let samples = model.overlay { GazeOverlayView(samples: samples) }
                VStack(spacing: 16) {
                    Text("EyeSpy").font(.largeTitle)
                    Text(model.status).multilineTextAlignment(.center)
                    HStack {
                        Button("Start & calibrate") { Task { await model.start() } }.disabled(model.running)
                        Button("Recalibrate") { model.recalibrate() }.disabled(!model.running)
                        Button("Stop") { model.stop() }.disabled(!model.running)
                    }
                    Button("Request Accessibility") { MacPermissions.requestAccessibilityIfNeeded(prompt: true) }
                    Text("TCP 127.0.0.1:14444 · WebSocket 127.0.0.1:14445")
                        .font(.caption).textSelection(.enabled)
                }.padding(36)
                if let stream = model.calibrationStream, let viewport = model.viewport {
                    CalibrationView(rawStream: stream, viewport: viewport) { calibration, _ in
                        model.controller?.setCalibration(calibration)
                        model.calibrationStream = nil
                        model.status = "Tracking. Gaze samples are available on loopback."
                    }.id(model.calibrationID)
                }
                ViewportReader { model.updateViewport($0) }.allowsHitTesting(false)
            }
            .frame(minWidth: 700, minHeight: 500)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.stop() }
        }
    }
}

@MainActor private final class EyeSpyModel: ObservableObject {
    @Published var status = "Start tracking, then follow the calibration dots."
    @Published var running = false
    @Published var overlay: AsyncStream<GazeSample>?
    @Published var calibrationStream: AsyncStream<RawGazeMeasurement>?
    @Published var viewport: ViewportGeometry?
    var calibrationID = UUID()
    var controller: EyeTrackerController?
    private var provider: VisionCameraGazeProvider?
    private let server = GazeFeedServer()
    private var generation: UInt64 = 0
    private var feedTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
    func updateViewport(_ value: ViewportGeometry) {
        guard viewport != value else { return }
        viewport = value
        controller?.viewport = value
        if running { recalibrate() }
    }
    func start() async {
        guard let viewport, !running else { return }
        generation &+= 1
        let run = generation
        running = true
        do {
            let provider = VisionCameraGazeProvider()
            self.provider = provider
            let controller = EyeTrackerController(provider: provider, viewport: viewport,
                targetResolver: MacTargetResolver(), displayPixelMapper: MacDisplayPixelMapper())
            self.controller = controller
            overlay = controller.samples
            let stream = controller.samples
            feedTask = Task { [server] in for await sample in stream { server.broadcast(sample) } }
            let errors = provider.errors
            errorTask = Task { [weak self] in
                for await error in errors { self?.status = error }
            }
            _ = try await server.start()
            guard generation == run else { return }
            try await controller.start()
            guard generation == run else { controller.stop(); return }
            recalibrate()
        } catch {
            if generation == run { stop(); status = error.localizedDescription }
        }
    }
    func recalibrate() {
        controller?.setCalibration(nil)
        calibrationID = UUID()
        calibrationStream = provider?.makeRawMeasurementsStream()
        status = "Calibrating. Keep the window and head still."
    }
    func stop() {
        generation &+= 1
        controller?.stop(); server.stop(); feedTask?.cancel(); errorTask?.cancel()
        feedTask = nil; errorTask = nil; controller = nil; provider = nil
        calibrationStream = nil; overlay = nil; running = false; status = "Stopped."
    }
}

private struct ViewportReader: NSViewRepresentable {
    let changed: (ViewportGeometry) -> Void
    func makeNSView(context: Context) -> TrackingView { TrackingView(changed: changed) }
    func updateNSView(_ nsView: TrackingView, context: Context) {}
    final class TrackingView: NSView {
        private var timer: Timer?
        private let changed: (ViewportGeometry) -> Void
        init(changed: @escaping (ViewportGeometry) -> Void) {
            self.changed = changed; super.init(frame: .zero)
            timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        private func report() {
            guard let window, let screen = window.screen, bounds.width > 0, bounds.height > 0 else { return }
            let global = window.convertToScreen(convert(bounds, to: nil))
            changed(.init(screenOriginPoints: MacDisplayPixelMapper.topLeftOrigin(of: global),
                          sizePoints: bounds.size, pointsToPixelsScale: screen.backingScaleFactor))
        }
        deinit { timer?.invalidate() }
    }
}
#else
import Foundation
@main struct EyeSpyApp {
    static func main() { print("The EyeSpy example is macOS-only. Use the EyeTrack libraries in your iOS app.") }
}
#endif
