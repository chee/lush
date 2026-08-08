import CryptoKit
import Foundation
import Network
import Security
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class OpenRouterAuthentication {
    static let shared = OpenRouterAuthentication()

    private var listener: NWListener?
    private var callbackContinuation: CheckedContinuation<String, Error>?
    private var callbackResult: Result<String, Error>?
    private var expectedState: String?
    private let callbackQueue = DispatchQueue(label: "party.chee.patchwork.lush.openrouter")

    enum AuthenticationError: LocalizedError {
        case randomGeneration
        case invalidAuthorizationURL
        case callbackServer(String)
        case browserOpenFailed
        case missingCode
        case invalidResponse
        case exchangeFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .randomGeneration: "Could not create a secure sign-in request."
            case .invalidAuthorizationURL: "Could not create the OpenRouter sign-in URL."
            case .callbackServer(let message): "Could not receive the OpenRouter sign-in: \(message)"
            case .browserOpenFailed: "Could not open the OpenRouter sign-in page."
            case .missingCode: "OpenRouter did not return an authorization code."
            case .invalidResponse: "OpenRouter returned a response Lush could not read."
            case .exchangeFailed(let status, let message): "OpenRouter returned \(status): \(message)"
            }
        }
    }

    private struct ExchangeRequest: Encodable {
        let code: String
        let codeVerifier: String
        let codeChallengeMethod: String

        enum CodingKeys: String, CodingKey {
            case code
            case codeVerifier = "code_verifier"
            case codeChallengeMethod = "code_challenge_method"
        }
    }

    private struct ExchangeResponse: Decodable {
        let key: String
    }

    func signIn() async throws -> String {
        cancelCallback()
        let verifier = try randomVerifier()
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        let state = try randomVerifier()
        expectedState = state
        let port: UInt16
        do {
            port = try await startCallbackServer()
        } catch {
            cancelCallback()
            throw error
        }
        let callback = "http://127.0.0.1:\(port)/openrouter"
        var components = URLComponents(string: "https://openrouter.ai/auth")
        components?.queryItems = [
            URLQueryItem(name: "callback_url", value: callback),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authorizationURL = components?.url else {
            cancelCallback()
            throw AuthenticationError.invalidAuthorizationURL
        }
        guard await open(authorizationURL) else {
            cancelCallback()
            throw AuthenticationError.browserOpenFailed
        }

        let code = try await waitForCallback()
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ExchangeRequest(
            code: code,
            codeVerifier: verifier,
            codeChallengeMethod: "S256"
        ))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthenticationError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw AuthenticationError.exchangeFailed(http.statusCode, message)
        }
        guard let key = try? JSONDecoder().decode(ExchangeResponse.self, from: data).key,
              !key.isEmpty
        else { throw AuthenticationError.invalidResponse }
        return key
    }

    private func startCallbackServer() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.receiveCallback(from: connection)
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        listener.stateUpdateHandler = nil
                        guard let port = listener.port?.rawValue else {
                            continuation.resume(throwing: AuthenticationError.callbackServer("No port was assigned."))
                            return
                        }
                        continuation.resume(returning: port)
                    case .failed(let error):
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: AuthenticationError.callbackServer(error.localizedDescription))
                    default:
                        break
                    }
                }
                self.listener = listener
                listener.start(queue: callbackQueue)
            } catch {
                continuation.resume(throwing: AuthenticationError.callbackServer(error.localizedDescription))
            }
        }
    }

    private nonisolated func receiveCallback(from connection: NWConnection) {
        connection.start(queue: callbackQueue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request
                .split(separator: "\r\n", maxSplits: 1)
                .first?
                .split(separator: " ")
                .dropFirst()
                .first
                .flatMap { URLComponents(string: "http://127.0.0.1\($0)") }
            let isCallback = target?.path == "/openrouter"
            let code = isCallback ? target?.queryItems?.first(where: { $0.name == "code" })?.value : nil
            let state = isCallback ? target?.queryItems?.first(where: { $0.name == "state" })?.value : nil
            Task { @MainActor in
                guard isCallback, let code, state == nil || state == self.expectedState else {
                    // browser preconnect, favicon, or a split segment — keep the
                    // listener bound and wait for the real redirect
                    self.respond(connection, status: "404 Not Found", body: "Waiting for OpenRouter sign-in.")
                    return
                }
                self.respond(connection, status: "200 OK", body: "OpenRouter is connected to Lush. This window can be closed.")
                self.finishCallback(with: .success(code))
            }
        }
    }

    private nonisolated func respond(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finishCallback(with result: Result<String, Error>) {
        let continuation = callbackContinuation
        callbackContinuation = nil
        listener?.cancel()
        listener = nil
        expectedState = nil
        if let continuation {
            continuation.resume(with: result)
        } else {
            callbackResult = result
        }
    }

    private func waitForCallback() async throws -> String {
        if let result = callbackResult {
            callbackResult = nil
            return try result.get()
        }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.finishCallback(with: .failure(AuthenticationError.callbackServer("Timed out waiting for OpenRouter sign-in.")))
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                callbackContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelCallback() }
        }
    }

    private func cancelCallback() {
        listener?.cancel()
        listener = nil
        expectedState = nil
        callbackContinuation?.resume(throwing: CancellationError())
        callbackContinuation = nil
        callbackResult = nil
    }

    private func open(_ url: URL) async -> Bool {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        await UIApplication.shared.open(url)
        #endif
    }

    private func randomVerifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AuthenticationError.randomGeneration
        }
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
