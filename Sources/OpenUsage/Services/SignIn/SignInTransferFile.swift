import CommonCrypto
import CryptoKit
import Foundation

/// What an exported sign-in file carries: OpenUsage's own sign-ins, never a tool's local login.
struct SignInTransferPayload: Codable, Equatable, Sendable {
    /// Sign-ins by provider family (`claude`, `codex`, `grok`).
    var accounts: [String: SignedInAccount]
    var cursor: CursorAccount?
    var exportedAt: Date

    var isEmpty: Bool { accounts.isEmpty && cursor == nil }
}

/// The password-protected file format for moving sign-ins to another Mac: the payload is sealed with
/// AES-GCM under a key derived from the password (PBKDF2-SHA256), so the tokens never sit in plain text.
enum SignInTransferFile {
    static let format = "openusage-signins"
    static let version = 1
    static let minimumPasswordLength = 8
    static let defaultRounds = 310_000

    static func seal(_ payload: SignInTransferPayload, password: String, rounds: Int = defaultRounds) throws -> Data {
        guard password.count >= minimumPasswordLength else { throw SignInTransferError.passwordTooShort }
        let salt = Data(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })
        let key = try deriveKey(password: password, salt: salt, rounds: rounds)
        let plain = try JSONEncoder().encode(payload)
        guard let sealed = try AES.GCM.seal(plain, using: key).combined else { throw SignInTransferError.encryptionFailed }
        let envelope = Envelope(format: format, version: version, rounds: rounds, salt: salt, sealed: sealed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    static func open(_ data: Data, password: String) throws -> SignInTransferPayload {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.format == format else {
            throw SignInTransferError.unrecognizedFile
        }
        guard envelope.version <= version else { throw SignInTransferError.newerVersion }
        guard envelope.rounds > 0 else { throw SignInTransferError.unrecognizedFile }
        let key = try deriveKey(password: password, salt: envelope.salt, rounds: envelope.rounds)
        let plain: Data
        do {
            plain = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key)
        } catch {
            throw SignInTransferError.wrongPassword
        }
        guard let payload = try? JSONDecoder().decode(SignInTransferPayload.self, from: plain) else {
            throw SignInTransferError.unrecognizedFile
        }
        return payload
    }

    private static func deriveKey(password: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        let passwordBytes = Array(password.utf8).map { CChar(bitPattern: $0) }
        let saltBytes = [UInt8](salt)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBytes, passwordBytes.count,
            saltBytes, saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            UInt32(clamping: rounds),
            &derived, derived.count
        )
        guard status == Int32(kCCSuccess) else {
            AppLog.error(.config, "sign-in transfer key derivation failed (\(status))")
            throw SignInTransferError.encryptionFailed
        }
        return SymmetricKey(data: derived)
    }

    private struct Envelope: Codable {
        let format: String
        let version: Int
        let rounds: Int
        let salt: Data
        let sealed: Data
    }
}

enum SignInTransferError: LocalizedError, Equatable {
    case passwordTooShort
    case nothingToExport
    case nothingToImport
    case wrongPassword
    case unrecognizedFile
    case newerVersion
    case encryptionFailed

    var errorDescription: String? {
        switch self {
        case .passwordTooShort:
            "Use a password of at least \(SignInTransferFile.minimumPasswordLength) characters."
        case .nothingToExport:
            "No OpenUsage sign-ins to export. Sign in to a provider with OpenUsage Sign-In first."
        case .nothingToImport:
            "This file has no sign-ins for the providers on this Mac."
        case .wrongPassword:
            "Wrong password, or the file is damaged."
        case .unrecognizedFile:
            "This isn't an OpenUsage sign-in export."
        case .newerVersion:
            "This file was exported by a newer OpenUsage. Update OpenUsage and try again."
        case .encryptionFailed:
            "Couldn't encrypt the sign-ins. Try again."
        }
    }
}
