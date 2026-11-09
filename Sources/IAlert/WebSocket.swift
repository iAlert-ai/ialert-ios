import Foundation

/// Events from a WebSocket to the Gateway connection.
public protocol WebSocketClientDelegate: AnyObject {
    func webSocketDidOpen(_ socket: WebSocketClient)
    func webSocket(_ socket: WebSocketClient, didReceive text: String)
    func webSocketDidClose(_ socket: WebSocketClient)
}

/// Minimal WebSocket the SDK needs; `URLSessionWebSocketClient` is the default. Inject a fake in tests.
public protocol WebSocketClient: AnyObject {
    var delegate: WebSocketClientDelegate? { get set }
    var isOpen: Bool { get }
    func connect()
    func send(_ text: String)
    func close()
}

public typealias WebSocketFactory = @Sendable (URL) -> WebSocketClient

/// `URLSessionWebSocketTask` wrapper.
public final class URLSessionWebSocketClient: NSObject, WebSocketClient, URLSessionWebSocketDelegate, @unchecked Sendable {
    public weak var delegate: WebSocketClientDelegate?
    private let url: URL
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var open = false
    private var closed = false

    public init(url: URL) {
        self.url = url
    }

    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    public func connect() {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        lock.lock()
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
        receive(on: task)
    }

    public func send(_ text: String) {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.send(.string(text)) { _ in }
    }

    public func close() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel(with: .normalClosure, reason: nil)
        finish()
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case let .success(.string(text)):
                self.delegate?.webSocket(self, didReceive: text)
                self.receive(on: task)
            case let .success(.data(data)):
                self.delegate?.webSocket(self, didReceive: String(decoding: data, as: UTF8.self))
                self.receive(on: task)
            case .success:
                self.receive(on: task)
            case .failure:
                self.finish()
            }
        }
    }

    private func finish() {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        open = false
        let session = self.session
        self.session = nil
        lock.unlock()

        guard !alreadyClosed else { return }
        session?.invalidateAndCancel()
        delegate?.webSocketDidClose(self)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        lock.lock()
        open = true
        lock.unlock()
        delegate?.webSocketDidOpen(self)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }
}
