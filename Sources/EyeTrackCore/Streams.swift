import Foundation

/// Independent bounded subscriptions: a slow consumer drops old frames, never blocks capture.
public final class SampleBroadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    public init() {}
    public func stream() -> AsyncStream<Element> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            lock.lock(); continuations[id] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
        }
    }
    private func remove(_ id: UUID) {
        lock.lock(); continuations.removeValue(forKey: id); lock.unlock()
    }
    public func yield(_ value: Element) {
        lock.lock(); let current = Array(continuations.values); lock.unlock()
        current.forEach { $0.yield(value) }
    }
    public func finish() {
        lock.lock(); let current = Array(continuations.values); continuations.removeAll(); lock.unlock()
        current.forEach { $0.finish() }
    }
    deinit { finish() }
}

@MainActor public protocol GazeProvider: AnyObject {
    func makeRawMeasurementsStream() -> AsyncStream<RawGazeMeasurement>
    func start() async throws
    func stop()
}
@MainActor public protocol GazeTargetResolving {
    func resolve(screenPoint: GazePoint) -> GazeTarget?
}
@MainActor public protocol DisplayPixelMapping {
    func map(screenPoint: GazePoint) -> DisplayPixel?
}
