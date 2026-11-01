import CompanionKit
import Foundation
import Security

struct Pairing: Codable {
    let deviceId: String
    let key: Data
    let macName: String
    var port: UInt16? = nil
    var hosts: [String]? = nil

    init(deviceId: String, key: Data, macName: String, port: UInt16? = nil, hosts: [String]? = nil) {
        self.deviceId = deviceId
        self.key = key
        self.macName = macName
        self.port = port
        self.hosts = hosts
    }

    init(deviceId: String, key: Data, invite: PairingInvite) {
        self.init(deviceId: deviceId, key: key, macName: invite.macName, port: invite.port, hosts: invite.hosts)
    }
}

enum PairingStore {
    static let service = "com.noma4i.DrawMoar.pairing"

    static func deviceId() throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "deviceId"]
        var read = query
        read[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let id = String(data: data, encoding: .utf8) {
            return id
        }
        guard status == errSecItemNotFound else { throw StoreError(status: status) }
        let id = try load()?.deviceId ?? UUID().uuidString
        var insert = query
        insert[kSecValueData as String] = Data(id.utf8)
        let added = SecItemAdd(insert as CFDictionary, nil)
        if added == errSecDuplicateItem {
            return try deviceId()
        }
        guard added == errSecSuccess else { throw StoreError(status: added) }
        return id
    }

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

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError(status: status) }
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
