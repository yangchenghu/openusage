import Foundation

struct CursorAccount: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var label: String = "Cursor Account"

    var authState: CursorAuthState {
        CursorAuthState(accessToken: accessToken, refreshToken: refreshToken, membershipType: nil, source: .openUsage)
    }
}

protocol CursorAccountVault: Sendable {
    func load() async throws -> CursorAccount?
    func save(_ account: CursorAccount) async throws
    func delete() async throws
}
