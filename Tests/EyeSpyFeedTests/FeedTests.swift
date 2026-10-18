#if os(macOS)
import XCTest
import Network
import Foundation
import EyeTrackCore
@testable import EyeSpyFeed

private final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let opened: XCTestExpectation
    init(opened: XCTestExpectation) { self.opened = opened }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) { opened.fulfill() }
}

final class FeedTests: XCTestCase {
    func testActualTCPAndWebSocketBroadcastIdenticalREADMEJSON() async throws {
        let server = GazeFeedServer()
        let ports = try await server.start(tcpPort: 0, webSocketPort: 0)
        defer { server.stop() }
        let queue = DispatchQueue(label: "EyeSpy.tests")
        let tcp = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: ports.tcp)!, using: .tcp)
        defer { tcp.cancel() }
        let ready = expectation(description: "TCP ready")
        tcp.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        tcp.start(queue: queue)
        let opened = expectation(description: "WebSocket handshake complete")
        let delegate = WebSocketDelegate(opened: opened)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let ws = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(ports.webSocket)")!)
        ws.resume()
        await fulfillment(of: [ready, opened], timeout: 3)
        let sample = GazeSample(timestampNanos: 1234567890, confidence: 0.87,
            normalizedInViewport: .init(x: 0.52, y: 0.41),
            viewport: .init(screenOriginPoints: .zero, sizePoints: CGSize(width: 1000, height: 800), pointsToPixelsScale: 2))
        // Keep broadcasting until both clients receive, as a real camera does.
        let pump = Task {
            while !Task.isCancelled {
                server.broadcast(sample)
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        defer { pump.cancel() }
        let tcpReceived = expectation(description: "TCP newline JSON")
        tcp.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            XCTAssertNil(error)
            if let data {
                let line = data.split(separator: 10).first.map(Data.init)
                XCTAssertEqual(data.last, 10)
                XCTAssertEqual(try? JSONDecoder().decode(GazeSample.self, from: line ?? Data()), sample)
            } else { XCTFail("No TCP data") }
            tcpReceived.fulfill()
        }
        let wsReceived = expectation(description: "WebSocket text JSON")
        let reader = Task {
            do {
                let frame = try await ws.receive()
                guard case .string(let text) = frame else { XCTFail("Expected text frame"); wsReceived.fulfill(); return }
                XCTAssertEqual(try JSONDecoder().decode(GazeSample.self, from: Data(text.utf8)), sample)
            } catch { XCTFail("WebSocket error: \(error)") }
            wsReceived.fulfill()
        }
        defer { reader.cancel() }
        await fulfillment(of: [tcpReceived, wsReceived], timeout: 3)
        // A standard WebSocket handshake above was sufficient; no app subscription required.
    }
    func testPortConflictRollsBackAndServerCanRestart() async throws {
        let first = GazeFeedServer(), second = GazeFeedServer()
        let ports = try await first.start(tcpPort: 0, webSocketPort: 0)
        defer { first.stop(); second.stop() }
        do { _ = try await first.start(); XCTFail("Double start must fail") } catch {}
        do { _ = try await second.start(tcpPort: 0, webSocketPort: ports.webSocket); XCTFail("Occupied port must fail") } catch {}
        _ = try await second.start(tcpPort: 0, webSocketPort: 0)
        second.stop()
        let restarted = try await second.start(tcpPort: 0, webSocketPort: 0)
        XCTAssertGreaterThan(restarted.tcp, 0)
        XCTAssertGreaterThan(restarted.webSocket, 0)
    }
}
#endif
