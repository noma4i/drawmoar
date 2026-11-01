import Foundation
import Security

struct Pairing: Codable {
    let deviceId: String
    let key: Data
    let macName: String
}

enum PairingStore {
    static let service = "com.noma4i.DrawMoar.pairing"

    static func load() throws -> Pairing? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else { throw StoreError(status: status) }
        return try JSONDecoder().decode(Pairing.self, from: data)
    }

    static func save(_ pairing: Pairing) throws {
        let data = try JSONEncoder().encode(pairing)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            let result = SecItemAdd(query as CFDictionary, nil)
            guard result == errSecSuccess else { throw StoreError(status: result) }
        } else if status != errSecSuccess {
            throw StoreError(status: status)
        }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "mac"]
    }

    struct StoreError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "Keychain error: \(status)"
        }
    }
}
