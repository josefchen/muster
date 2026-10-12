import Foundation
import Network

/// The server on 127.0.0.1 that the agents' hooks call. One request per
/// connection; the reply can wait as long as the caller likes, which is how a
/// prompt is held until you answer it.
final class HookServer {
    /// Tried in turn from the starting port if another app holds one.
    let ports: ClosedRange<UInt16>
    let queue: DispatchQueue
    var onReady: ((UInt16) -> Void)?
    var onRequest: ((HTTPRequest, Exchange) -> Void)?
    private var listener: NWListener?

    init(ports: ClosedRange<UInt16>, queue: DispatchQueue = .main) {
        self.ports = ports
        self.queue = queue
    }

    /// One request's connection, open until it's answered.
    struct Exchange {
        fileprivate let connection: NWConnection

        /// Answers with a JSON body (empty steps aside) and closes.
        func reply(_ body: Data) {
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            let c = connection
            c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }

        /// Runs when the connection ends, answered or not.
        func onClose(_ closed: @escaping () -> Void) {
            connection.stateUpdateHandler = { state in
                switch state {
                case .cancelled, .failed: closed()
                default: break
                }
            }
        }
    }

    func start(on port: UInt16) {
        guard listener == nil else { return }
        listen(on: port, tries: ports.count)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func listen(on number: UInt16, tries: Int) {
        guard tries > 0, let port = NWEndpoint.Port(rawValue: number) else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?(number)
            case .failed:
                l.cancel()
                self.listener = nil
                let next = number >= self.ports.upperBound ? self.ports.lowerBound : number + 1
                self.listen(on: next, tries: tries - 1)
            default:
                break
            }
        }
        l.start(queue: queue)
        listener = l
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                self.onRequest?(request, Exchange(connection: c))
            case .partial where !done && error == nil && buffer.count < 4 << 20:
                self.read(c, buffer)
            default:
                c.cancel()
            }
        }
    }
}
