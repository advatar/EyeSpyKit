# EyeTrackKit

EyeTrackKit is a Swift Package that provides **built-in camera** eye tracking for **iOS** and **macOS**, mapping gaze to:

- **normalized (0…1)** coordinates in a viewport (top-left origin)
- **viewport points**
- **viewport pixels**
- (macOS) **global screen point** (top-left origin)
- (macOS) **display-local pixel coordinates** (best effort, per-display)
- (macOS) **target window + app** (best effort)

> Important: this package provides a practical pipeline (capture → raw features → calibration → smoothing → pixel mapping).  
> Accuracy depends heavily on calibration quality, camera placement, and lighting.

## Implementation status

The original repository contained only this README at `5f3fa74`. No source was
recovered from GitHub refs/history or the archived local checkout. The SwiftPM
implementation was reconstructed against these contracts under [issue #1](https://github.com/advatar/EyeSpyKit/issues/1).

Requires Swift 5.9+, macOS 13+ or iOS 16+. All five modules below are implemented.
`EyeSpyFeed` provides the example's loopback transports; the `EyeSpy` executable
provides a macOS calibration/debug app. Camera accuracy, physical TrueDepth
behavior and real permission flows require device qualification; passing synthetic
and loopback tests does not establish tracking accuracy.

## Modules

- `EyeTrackCore`  
  Core types, calibration, smoothing, controller pipeline.

- `EyeTrackUI`  
  SwiftUI calibration view + overlay cursor debug view.

- `EyeTrackVisionCamera`  
  AVFoundation + Vision webcam/front-camera provider for **macOS and iOS** (built-in camera selection).

- `EyeTrackARKit`  
  ARKit face tracking provider for **iOS** (TrueDepth devices). Includes an “auto” provider that falls back to Vision when ARKit face tracking isn’t supported.

- `EyeTrackMacWindowing`  
  macOS window/app resolution at a screen point via:
  - Accessibility hit-testing (best, requires Accessibility permission)
  - CGWindowList fallback (no AX required, lower fidelity)

## Coordinate conventions

All gaze coordinates in EyeTrackKit use:

- origin: **top-left**
- x: right
- y: down

### Viewport mapping
The main output (`GazeSample`) includes:
- `normalizedInViewport` — (0..1) in viewport
- `viewportPoint` — points in viewport
- `viewportPixel` — pixels in viewport (points * scale)

### macOS display pixel mapping
On macOS, `displayPixel` is **display-local backing pixels**, and `displayID` tells you which display.

## Permissions / entitlements

### iOS
Add to your app’s Info.plist:
- `NSCameraUsageDescription`

If using ARKit face tracking, you need a TrueDepth-capable device (e.g., iPhone X+). Otherwise, use Vision provider fallback.

### macOS
Add to your app’s Info.plist:
- `NSCameraUsageDescription`

For “which window/app under gaze”:
- Enable Accessibility permission for your app in System Settings
  - System Settings → Privacy & Security → Accessibility

You can programmatically prompt the user to open the appropriate settings pane via `AXIsProcessTrustedWithOptions`.

## Quick start (SwiftUI)

### iOS: ARKit if available, otherwise Vision

```swift
import SwiftUI
import EyeTrackCore
import EyeTrackUI
import EyeTrackARKit

struct ContentView: View {
    @State private var controller: EyeTrackerController?

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            if let controller {
                GazeOverlayView(samples: controller.samples)
            }

            Button("Start") {
                Task { await start() }
            }
            .padding()
        }
    }

    @MainActor
    func start() async {
        // Choose ARKit if possible; fallback to Vision.
        let provider = iOSBuiltInCameraGazeProvider()

        let screen = UIScreen.main
        let viewport = ViewportGeometry(
            screenOriginPoints: .zero,
            sizePoints: screen.bounds.size,
            pointsToPixelsScale: Double(screen.nativeScale) // native pixels
        )

        let c = EyeTrackerController(provider: provider, viewport: viewport)
        self.controller = c

        // Calibration (required before samples are emitted):
        // let calStream = provider.makeRawMeasurementsStream()
        // present `CalibrationView(rawStream: calStream, viewport: viewport) { model, _ in controller.setCalibration(model) }`
        try? await c.start()
    }
}
```

### macOS: Vision camera + window/app resolution

```swift
import SwiftUI
import EyeTrackCore
import EyeTrackUI
import EyeTrackVisionCamera
import EyeTrackMacWindowing

struct ContentView: View {
    @State private var controller: EyeTrackerController?

    var body: some View {
        ZStack {
            Color.gray.opacity(0.1).ignoresSafeArea()

            if let controller {
                GazeOverlayView(samples: controller.samples)
            }

            VStack {
                Button("Start") { Task { await start() } }
                Button("Request Accessibility") {
                    _ = MacPermissions.requestAccessibilityIfNeeded(prompt: true)
                }
            }
            .padding()
        }
    }

    @MainActor
    func start() async {
        let provider = VisionCameraGazeProvider()

        let targetResolver = MacTargetResolver()
        let pixelMapper = MacDisplayPixelMapper()

        let screen = NSScreen.main!
        let viewport = ViewportGeometry(
            screenOriginPoints: .zero,
            sizePoints: screen.frame.size,
            pointsToPixelsScale: Double(screen.backingScaleFactor)
        )

        let c = EyeTrackerController(
            provider: provider,
            viewport: viewport,
            targetResolver: targetResolver,
            displayPixelMapper: pixelMapper
        )

        self.controller = c
        try? await c.start()
    }
}
```

## Calibration

Eye tracking without calibration is rarely useful.

Use `EyeTrackUI.CalibrationView`:
- create a calibration stream: `let s = provider.makeRawMeasurementsStream()`
- when it finishes, it returns a fitted model + snapshot
- call `controller.setCalibration(model)` and optionally persist `snapshot` (Codable)

### Collection and lifecycle

1. Keep the provider and controller alive. Subscribe to raw measurements before
   starting capture, then `try await controller.start()` from the main actor.
2. Present `CalibrationView(rawStream: provider.makeRawMeasurementsStream(),
   viewport: viewport) { model, snapshot in controller.setCalibration(model) }`
   over **the exact viewport** being mapped. The provider must already be running.
   Calibration waits 0.7 seconds at each of nine targets, then collects 20 valid
   frames per target and fits an affine model from per-target medians.
3. Store a gaze subscription once (`let stream = controller.samples`) for each
   consumer. Each access makes an independent bounded stream. Slow consumers drop
   old samples rather than delaying capture. Raw calibration subscriptions work
   the same way. Stream subscriptions remain usable across stop/start.
4. Call `controller.stop()` when capture is no longer needed. Stop cancels the
   controller's raw subscription and stops the provider. `setCalibration(nil)`
   gates output again; starting without a model produces no gaze samples.

`CalibrationSnapshot` is Codable; restore with `try snapshot.fittedModel()`.
Store it with your camera/provider, device orientation and viewport configuration.
Recalibrate after those change, or after changing posture/camera position.
Degenerate, nonfinite and insufficient observations produce an error rather than
an arbitrary fitted model. Coefficients are an affine approximation, not a
physiological gaze model or an accuracy guarantee.

Vision uses pupil position relative to eye contours. It emits no measurement when
pupils/eyes are missing or more than one face is present. The default image
orientation is `.upMirrored` on macOS and `.leftMirrored` for iOS portrait;
`VisionCameraGazeProvider(orientation:)` and the auto provider's
`iOSBuiltInCameraGazeProvider(visionOrientation:)` let a host supply another fixed
camera orientation. Recreate/recalibrate when orientation changes. ARKit uses its estimated
fixation direction transformed into camera coordinates and rejects untracked or
blinking faces. The auto provider selects based on ARKit support, and does not
hide a runtime camera/permission error by silently switching feature models.
Both concrete providers expose an independent `errors` stream of diagnostic strings.
Stop/restart after interruptions or runtime errors; there is no automatic session
recovery or saved calibration loading in the example.

Smoothing uses monotonic sample intervals. Duplicate/out-of-order samples and
nonfinite features are discarded, normalized output is clamped to 0…1, and a
one-second capture gap resets smoothing. Confidence is a best-effort detector/blink
score, not a calibrated probability of accurate gaze. Camera timestamps are
monotonic uptime when processing begins, not wall time or a hardware exposure
clock; synchronize clocks explicitly before correlating with another data source.

On macOS, `screenOriginPoints` must be the **global top-left of the viewport**,
not an AppKit bottom-left origin. `MacDisplayPixelMapper.topLeftOrigin(of:)`
converts an AppKit global rectangle. Pass a window's content/view rectangle,
not its title bar frame. The example watches its content rectangle and requires
recalibration when it moves/resizes or changes display. Display mapping supports
negative origins and uses each display's own bounds and pixel dimensions.
CGWindowList may omit titles without Screen Recording permission; window identity
and display pixels are best effort. AX hit testing is attempted only when already
trusted. Request Accessibility explicitly through `MacPermissions` if desired.

## Running the macOS example

Build an app bundle so macOS can read the camera usage description:

```sh
./scripts/build-example.sh
open .build/EyeSpy.app
```

Choose **Start & calibrate**, grant camera access, then look at each dot while
keeping the window/head still. After successful calibration the cursor and both
feeds start receiving samples. **Stop** releases capture and closes the listeners.
Do not run the bare SwiftPM executable for camera access; use the app bundle.
The script uses ad-hoc signing for local development. A distributed app needs its
own signing/provisioning. A sandboxed macOS host also needs the
`com.apple.security.device.camera` entitlement and, if hosting the feed,
`com.apple.security.network.server`.

The example keeps calibration only in memory and opens sockets only after an
explicit Start. The listener binds IPv4 loopback, limits clients to 32, caps
incoming WebSocket messages at 64 KiB and drops samples for clients with an
in-flight send. Other local processes can read the feed, including window metadata.

## Gaze feed (EyeSpy example)

The **EyeSpy** example app exposes a local network feed of gaze samples for other apps.

### Endpoints

- **TCP (newline-delimited JSON)**: `127.0.0.1:14444`
- **WebSocket (text frames)**: `ws://127.0.0.1:14445`

Both endpoints broadcast the **same JSON payload** for every gaze sample.  
No authentication, no TLS, and **local loopback only**. The feed is **macOS-only** (the server is stubbed on iOS).

### Message format

Each message is a JSON object describing a `GazeSample`:

```json
{
  "timestampNanos": 1234567890,
  "confidence": 0.87,
  "normalizedInViewport": { "x": 0.52, "y": 0.41 },
  "viewportPoint": { "x": 540.0, "y": 420.0 },
  "viewportPixel": { "x": 1080.0, "y": 840.0 },
  "screenPoint": { "x": 980.0, "y": 640.0 },
  "displayID": 69733248,
  "displayPixel": { "x": 1960.0, "y": 1280.0 },
  "target": {
    "pid": 1234,
    "appName": "Safari",
    "bundleID": "com.apple.Safari",
    "windowID": 4321,
    "windowTitle": "Example Page",
    "windowBoundsTopLeftPoints": { "x": 0.0, "y": 0.0, "width": 1440.0, "height": 900.0 }
  }
}
```

### Field definitions

- `timestampNanos` — **monotonic uptime** timestamp (nanoseconds). Not wall‑clock time.
- `confidence` — 0…1 confidence score (best effort).
- `normalizedInViewport` — normalized (0…1) coordinates within the active viewport.
- `viewportPoint` — points in the active viewport.
- `viewportPixel` — pixels in the active viewport (points × scale).
- `screenPoint` — global screen point in **screen points**.
- `displayID` — macOS display identifier (if available).
- `displayPixel` — display‑local **backing pixel** coordinate (if available).
- `target` — best‑effort window/app under gaze (macOS only):
  - `pid`, `appName`, `bundleID`
  - `windowID`, `windowTitle`
  - `windowBoundsTopLeftPoints` — window bounds in **global screen points** (top‑left origin).

All coordinates use **top‑left origin**, **x→right**, **y→down**.

### Transport details

- **TCP**: each JSON payload is terminated by `\n` (newline).
- **WebSocket**: each JSON payload is sent as a single **text frame**.
- No application subscription messages are required. WebSocket clients perform the standard HTTP Upgrade handshake; the server ignores application messages and replies to pings.

### Behavior notes

- The feed broadcasts **after calibration** (no samples until a calibration model is set).
- Sample rate depends on camera/Vision/ARKit throughput and can vary.
- Some fields can be `null` when unknown (e.g., `target`, `displayID`, `displayPixel`).

## Building

From the repository root:

- `swift build`
- `swift test`

Tests cover affine calibration/snapshot persistence, degenerate input, smoothing,
coordinate and JSON contracts, controller lifecycle, multicast/backpressure,
landmark/display geometry, and real TCP/WebSocket loopback broadcasts. They never
activate the camera or request Accessibility. For an unsigned generic iOS compile:

```sh
xcodebuild -scheme EyeTrackKit-Package -destination 'generic/platform=iOS' \
  -derivedDataPath .build/ios-derived CODE_SIGNING_ALLOWED=NO build
```

For iOS apps, add the package in Xcode: **File → Add Packages…** and select the local folder.

## License

MIT (see LICENSE).
