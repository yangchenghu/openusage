import CryptoKit
import Foundation

/// Cursor's browser/CLI authorization protocol, ported from main's CursorLogin.
struct CursorLogin: Sendable {
    static let authorizeURL = URL(string: "https://cursor.com/loginDeepControl")!
    static let pollURL = URL(string: "https://api2.cursor.sh/auth/poll")!
    var http: any HTTPClient = URLSessionHTTPClient()
    var now: @Sendable () -> Date = Date.init
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }

    struct Request: Sendable {
        let id: String
        let verifier: String

        init(id: String = UUID().uuidString, verifier: String? = nil) {
            self.id = id
            self.verifier = verifier ?? Self.base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
        }

        var authorizeURL: URL {
            var url = URLComponents(url: CursorLogin.authorizeURL, resolvingAgainstBaseURL: false)!
            url.queryItems = [
                URLQueryItem(name: "challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
                URLQueryItem(name: "uuid", value: id),
                URLQueryItem(name: "mode", value: "login"),
                URLQueryItem(name: "redirectTarget", value: "cli")
            ]
            return url.url!
        }

        var pollURL: URL {
            var url = URLComponents(url: CursorLogin.pollURL, resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "uuid", value: id), URLQueryItem(name: "verifier", value: verifier)]
            return url.url!
        }

        private static func base64URL(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
    }

    func authorize(
        request: Request = Request(),
        openBrowser: @Sendable (URL) async throws -> Void
    ) async throws -> CursorAccount {
        try Task.checkCancellation()
        try await openBrowser(request.authorizeURL)
        let deadline = now().addingTimeInterval(300)
        while now() < deadline {
            try Task.checkCancellation()
            let response: HTTPResponse
            do {
                response = try await http.send(HTTPRequest(method: "GET", url: request.pollURL, timeout: 15))
            } catch is URLError {
                try Task.checkCancellation()
                AppLog.warn(LogTag.auth("cursor"), "sign-in poll could not connect; retrying")
                try await sleep(2)
                continue
            }
            if [202, 404].contains(response.statusCode) {
                try await sleep(2)
                continue
            }
            guard (200..<300).contains(response.statusCode) else { throw CursorLoginError.requestFailed(response.statusCode) }
            struct Tokens: Decodable { let accessToken: String; let refreshToken: String }
            guard let token = try? JSONDecoder().decode(Tokens.self, from: response.body),
                  !token.accessToken.isEmpty, !token.refreshToken.isEmpty,
                  CursorUsageClient.session(from: token.accessToken) != nil else { throw CursorLoginError.invalidResponse }
            try Task.checkCancellation()
            return CursorAccount(accessToken: token.accessToken, refreshToken: token.refreshToken)
        }
        throw CursorLoginError.timedOut
    }
}

enum CursorLoginError: Error, LocalizedError, Sendable {
    case invalidResponse
    case requestFailed(Int)
    case timedOut
    case browserUnavailable
    case keychain

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Cursor returned an unreadable sign-in response. Try signing in again."
        case .requestFailed(let status): "Cursor sign-in failed (HTTP \(status)). Try again."
        case .timedOut: "Cursor sign-in timed out. Try again and finish authorization in your browser."
        case .browserUnavailable: "Couldn't open your browser. Try signing in again."
        case .keychain: "Couldn't access the saved Cursor sign-in in Keychain. Try again or unlock your Keychain."
        }
    }
}

extension CursorLoginError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .invalidResponse: .decoding
        case .requestFailed(let status): .http(status)
        case .timedOut: .network
        case .browserUnavailable: .other
        case .keychain: .credentialAccess
        }
    }
}
