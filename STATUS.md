# EyeSpyKit implementation status

## Source recovery (2026-10-18)

- [x] Inspect GitHub history, branches, tags, releases, pull requests and forks: only README.md in initial commit 5f3fa74; no alternate source found.
- [x] Search local workspace and Spotlight for EyeSpy/EyeTrack symbols and check the archived 2026-10-15 checkout: README only; no implementation found.

## README contract implementation

- [x] Implement EyeTrackCore types, multicast provider streams, calibration snapshots/fitting, smoothing, mapping and controller lifecycle.
- [x] Implement AVFoundation/Vision camera capture and iOS ARKit with unsupported-device Vision fallback.
- [x] Implement SwiftUI calibration and cursor overlay.
- [x] Implement macOS display mapping, Accessibility hit testing and CGWindowList fallback.
- [x] Implement EyeSpy example and loopback TCP/WebSocket JSON feed.
- [x] Add regression tests, verify macOS build/tests and iOS build, document limitations and usage.
- Branch delivery: commit/push this validated milestone, merge through a PR, and remove the feature branch. The PR records the final merge state.

Camera accuracy and permission/device behavior require a host app and physical hardware; automated checks must not be described as hardware qualification.

## Verification (2026-10-18)

- Swift 6.4 / Xcode 27.1 on macOS: `swift build --build-system native` passed.
- Final `swift test` with the default build system: 13 XCTest cases passed, zero failures. Tests include real loopback TCP and WebSocket connections, not camera capture.
- Final `xcodebuild -quiet -scheme EyeTrackKit-Package -destination 'generic/platform=iOS' -derivedDataPath .build/ios-derived CODE_SIGNING_ALLOWED=NO build` passed, including ARKit and all package products.
- `./scripts/build-example.sh` built `.build/EyeSpy.app`; `codesign --verify --deep --strict` passed; Launch Services accepted the launch.
- `plutil -lint Examples/EyeSpy/Info.plist`, `bash -n scripts/build-example.sh`, and whitespace checks passed.
- UI inspection was unavailable because Computer Use access to EyeSpy was not approved. Camera accuracy, real camera/AX permission flows, physical TrueDepth and multi-display hardware behavior have not been qualified. No camera was activated by automated tests.
- No simulator tests were run and no simulator storage was changed.
