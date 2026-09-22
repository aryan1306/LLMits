import Foundation
import Network
import LLMitsCore

final class LoopbackOAuthServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.llmits.oauth-loopback")
    private let state: String
    private var callbackContinuation: CheckedContinuation<OAuthCallback, Error>?
    private var pendingCallback: Result<OAuthCallback, Error>?
    private var startContinuation: CheckedContinuation<String, Error>?
    private var isClosed = false

    init(state: String) throws {
        self.state = state
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] listenerState in
                guard let self else { return }
                switch listenerState {
                case .ready:
                    guard let port = self.listener.port else {
                        self.startContinuation?.resume(throwing: AuthorizationError.invalidAuthorizationURL)
                        self.startContinuation = nil
                        return
                    }
                    self.startContinuation?.resume(returning: "http://127.0.0.1:\(port.rawValue)/oauth2callback")
                    self.startContinuation = nil
                case let .failed(error):
                    self.startContinuation?.resume(throwing: error)
                    self.startContinuation = nil
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] in self?.handle($0) }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 300) { [weak self] in
                guard let self, !self.isClosed else { return }
                self.isClosed = true
                self.startContinuation?.resume(throwing: AuthorizationError.expiredBrowserSignIn)
                self.startContinuation = nil
                self.callbackContinuation?.resume(throwing: AuthorizationError.expiredBrowserSignIn)
                self.callbackContinuation = nil
                self.listener.cancel()
            }
        }
    }

    func callback() async throws -> OAuthCallback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.pendingCallback {
                        self.pendingCallback = nil
                        continuation.resume(with: result)
                    }
                    else if self.isClosed || Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { self.callbackContinuation = continuation }
                }
            }
        } onCancel: { [weak self] in self?.cancel() }
    }

    func cancel() {
        queue.async {
            guard !self.isClosed else { return }
            self.isClosed = true
            self.startContinuation?.resume(throwing: CancellationError())
            self.startContinuation = nil
            self.callbackContinuation?.resume(throwing: CancellationError())
            self.callbackContinuation = nil
            self.listener.cancel()
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let firstLine = request.split(separator: "\r\n").first,
                  let target = firstLine.split(separator: " ").dropFirst().first,
                  let components = URLComponents(string: "http://localhost\(target)") else {
                connection.cancel(); return
            }
            guard components.path == "/oauth2callback" else { connection.cancel(); return }
            let values = (components.queryItems ?? []).reduce(into: [String: String]()) { $0[$1.name] = $1.value ?? "" }
            let callback = values["code"].flatMap { code in values["state"].map { OAuthCallback(code: code, state: $0) } }
            let ok = callback?.state == self.state
            let message = ok ? "Sign-in complete. You can close this tab and return to LLMits." : "Sign-in could not be verified. Return to LLMits and try again."
            let response = "HTTP/1.1 \(ok ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(message.utf8.count)\r\nConnection: close\r\n\r\n\(message)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            let result: Result<OAuthCallback, Error> = if let callback, ok {
                .success(callback)
            } else {
                .failure(AuthorizationError.stateMismatch)
            }
            if let continuation = self.callbackContinuation { continuation.resume(with: result) }
            else { self.pendingCallback = result }
            self.callbackContinuation = nil
            self.isClosed = true
            self.listener.cancel()
        }
    }
}
