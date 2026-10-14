import Foundation
import Security

struct AccountStore {
    private let service = "app.homelink.devices.accounts"
    private let account = "linked-accounts"

    func loadAccounts() -> [LinkedAccount] {
        guard let data = readKeychain() else { return [] }
        return (try? JSONDecoder().decode([LinkedAccount].self, from: data)) ?? []
    }

    func saveAccounts(_ accounts: [LinkedAccount]) throws {
        let data = try JSONEncoder().encode(accounts)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw XiaomiError.failed("无法把登录状态写入钥匙串（\(status)）")
        }
    }

    func loadHomes() -> [IoTHome] {
        guard let data = try? Data(contentsOf: homesURL) else { return [] }
        return (try? JSONDecoder().decode([IoTHome].self, from: data)) ?? []
    }

    func saveHomes(_ homes: [IoTHome]) {
        do {
            let directory = homesURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(homes)
            try data.write(to: homesURL, options: .atomic)
        } catch {
            // 缓存写失败不影响本次使用。
        }
    }

    private var homesURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("HomeLink", isDirectory: true).appendingPathComponent("homes.json")
    }

    private func readKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }
}
