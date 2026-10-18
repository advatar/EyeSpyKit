import Foundation
import EyeTrackCore
public struct GazeFeedPorts: Sendable {
    public let tcp: UInt16
    public let webSocket: UInt16
}

#if os(macOS)
import Network

/// Loopback only. At most one in-flight send per client; slow clients drop samples.
public final class GazeFeedServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "EyeSpy.feed")
    private var listeners: [NWListener] = []
    private var clients: [UUID: Client] = [:]
    private var starting = false
    private var generation: UInt64 = 0
    private var pendingStarts: [UUID: CheckedContinuation<UInt16, Error>] = [:]
    private struct Client {
        let connection: NWConnection
        let webSocket: Bool
        var sending = false
    }
    public init() {}
    public func start(tcpPort: UInt16 = 14444, webSocketPort: UInt16 = 14445) async throws -> GazeFeedPorts {
        let run: UInt64 = try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard listeners.isEmpty, !starting else {
                    continuation.resume(throwing: EyeTrackingError.capture("Gaze feed is already running.")); return
                }
                starting = true; generation &+= 1; continuation.resume(returning: generation)
            }
        }
        do {
            let tcp = try await listen(port: tcpPort, webSocket: false, run: run)
            let ws = try await listen(port: webSocketPort, webSocket: true, run: run)
            return GazeFeedPorts(tcp: tcp, webSocket: ws)
        } catch {
            await withCheckedContinuation { continuation in
                queue.async { [self] in if generation == run { stopOnQueue() }; continuation.resume() }
            }
            throw error
        }
    }
    private func listen(port: UInt16, webSocket: Bool, run: UInt64) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard generation == run else { continuation.resume(throwing: CancellationError()); return }
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
                    if webSocket {
                        let options = NWProtocolWebSocket.Options()
                        options.autoReplyPing = true
                        options.maximumMessageSize = 65536
                        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
                    }
                    let listener = try NWListener(using: parameters)
                    let id = UUID()
                    pendingStarts[id] = continuation
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = listener?.port else { return }
                            self.pendingStarts.removeValue(forKey: id)?.resume(returning: port.rawValue)
                        case .failed(let error):
                            self.pendingStarts.removeValue(forKey: id)?.resume(throwing: error)
                            listener?.cancel()
                        case .cancelled:
                            self.pendingStarts.removeValue(forKey: id)?.resume(throwing: CancellationError())
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, webSocket: webSocket) }
                    listeners.append(listener); listener.start(queue: queue)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func accept(_ connection: NWConnection, webSocket: Bool) {
        guard starting, !listeners.isEmpty, clients.count < 32 else { connection.cancel(); return }
        let id = UUID()
        clients[id] = Client(connection: connection, webSocket: webSocket)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.receive(id)
            case .failed, .cancelled: self.clients.removeValue(forKey: id)
            default: break
            }
        }
        connection.start(queue: queue)
    }
    private func receive(_ id: UUID) {
        guard let client = clients[id] else { return }
        if client.webSocket {
            client.connection.receiveMessage { [weak self] _, context, _, error in
                guard let self else { return }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if error != nil || metadata?.opcode == .close { self.remove(id) }
                else { self.receive(id) }
            }
        } else {
            client.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, complete, error in
                guard let self else { return }
                if complete || error != nil { self.remove(id) } else { self.receive(id) }
            }
        }
    }
    private func remove(_ id: UUID) { clients.removeValue(forKey: id)?.connection.cancel() }
    public func broadcast(_ sample: GazeSample) {
        guard let data = try? JSONEncoder().encode(sample) else { return }
        queue.async { [self] in
            for (id, client) in clients where !client.sending {
                guard case .ready = client.connection.state else { continue }
                clients[id]?.sending = true
                let payload: Data
                let context: NWConnection.ContentContext
                if client.webSocket {
                    payload = data
                    context = .init(identifier: "gaze", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
                } else { payload = data + Data([10]); context = .defaultMessage }
                client.connection.send(content: payload, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error != nil { self.remove(id) } else { self.clients[id]?.sending = false }
                })
            }
        }
    }
    public func stop() { queue.async { [self] in stopOnQueue() } }
    private func stopOnQueue() {
        generation &+= 1; starting = false
        let waiting = pendingStarts.values; pendingStarts.removeAll()
        waiting.forEach { $0.resume(throwing: CancellationError()) }
        listeners.forEach { $0.cancel() }; listeners.removeAll()
        clients.values.forEach { $0.connection.cancel() }; clients.removeAll()
    }
    deinit {
        listeners.forEach { $0.cancel() }
        clients.values.forEach { $0.connection.cancel() }
        pendingStarts.values.forEach { $0.resume(throwing: CancellationError()) }
    }
}
#else
/// The README feed is macOS-only. iOS deliberately does not open listening sockets.
public final class GazeFeedServer {
    public init() {}
    public func start(tcpPort: UInt16 = 14444, webSocketPort: UInt16 = 14445) async throws -> GazeFeedPorts { throw EyeTrackingError.unsupported }
    public func broadcast(_ sample: GazeSample) {}
    public func stop() {}
}
#endif
