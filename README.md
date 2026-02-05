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

        // Calibration (recommended):
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
- No subscription or handshake messages are required. The server ignores incoming frames.

### Behavior notes

- The feed broadcasts **after calibration** (no samples until a calibration model is set).
- Sample rate depends on camera/Vision/ARKit throughput and can vary.
- Some fields can be `null` when unknown (e.g., `target`, `displayID`, `displayPixel`).

## Building

From the repository root:

- `swift build`
- `swift test`

For iOS apps, add the package in Xcode: **File → Add Packages…** and select the local folder.

## License

MIT (see LICENSE).
