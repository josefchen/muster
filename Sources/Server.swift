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
    /// A client gets this long to send its whole request, so a stalled one
    /// can't keep a connection forever. A request held for an answer isn't timed.
    var deadline: TimeInterval = 10
    /// Connections still sending at once. Hooks finish in milliseconds, so past
    /// this new ones are closed straight away.
    var maxIncoming = 16
    private var listener: NWListener?
    /// Connections still sending, each with its deadline.
    private var incoming: [ObjectIdentifier: DispatchWorkItem] = [:]

    init(ports: ClosedRange<UInt16>, queue: DispatchQueue = .main) {
        self.ports = ports
        self.queue = queue
    }

    /// One request's connection, open until it's answered.
    struct Exchange {
        fileprivate let connection: NWConnection

        /// Answers with a JSON body (empty steps aside) and closes.
        func reply(_ body: Data) {
            deliver(body) { _ in }
        }

        /// Steps aside because you went to the agent to answer there. The agents read only the
        /// empty body; a hook Muster shares with another receiver reads the header and lets
        /// that one go too, so the agent's own prompt can appear.
        func release() {
            deliver(Data(), release: true) { _ in }
        }

        func deliver(_ body: Data, release: Bool = false, completion: @escaping (Bool) -> Void) {
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n"
                + (release ? "X-Muster: release\r\n" : "") + "Connection: close\r\n\r\n"
            let c = connection
            c.send(content: Data(head.utf8) + body, completion: .contentProcessed { error in
                completion(error == nil)
                c.cancel()
            })
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
        guard incoming.count < maxIncoming else { c.cancel(); return }
        let id = ObjectIdentifier(c)
        let late = DispatchWorkItem { [weak self] in
            self?.incoming[id] = nil
            c.cancel()
        }
        incoming[id] = late
        queue.asyncAfter(deadline: .now() + deadline, execute: late)
        c.start(queue: queue)
        read(c, Data())
    }

    /// Done sending: a whole request, or nothing more to wait for.
    private func arrived(_ c: NWConnection) {
        incoming.removeValue(forKey: ObjectIdentifier(c))?.cancel()
    }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                self.arrived(c)
                self.onRequest?(request, Exchange(connection: c))
                if done || error != nil { c.cancel() } else { self.watch(c) }
            case .partial where !done && error == nil:
                self.read(c, buffer)
            default:
                self.arrived(c)
                c.cancel()
            }
        }
    }

    /// Keeps a read open on a request that's waiting for its answer: it's the
    /// only way to hear the client hang up, which Claude does once you answer in
    /// its own dialog. Closing the connection then fires `onClose`. Bytes sent
    /// after the request are dropped unread; a client that keeps sending more
    /// than a request could hold isn't a hook, and is closed.
    private func watch(_ c: NWConnection, extra: Int = 0) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, done, error in
            let extra = extra + (data?.count ?? 0)
            guard let self, !done, error == nil, extra <= HTTPRequest.maxHead + HTTPRequest.maxBody else { c.cancel(); return }
            self.watch(c, extra: extra)
        }
    }
}
