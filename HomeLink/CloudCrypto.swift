import CommonCrypto
import Foundation
import Security

enum CloudCrypto {
    static func md5(_ text: String) -> String {
        XiaomiCrypto.md5Lower(text)
    }

    static func sha256(_ text: String) -> String {
        let data = Data(text.utf8)
        let digest: [UInt8] = data.withUnsafeBytes { buffer in
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
            return hash
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hmacSHA256(_ text: String, key: String) -> String {
        let message = Data(text.utf8)
        let keyData = Data(key.utf8)
        let digest: [UInt8] = message.withUnsafeBytes { messageBytes in
            keyData.withUnsafeBytes { keyBytes in
                var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyBytes.baseAddress,
                    keyData.count,
                    messageBytes.baseAddress,
                    message.count,
                    &hash
                )
                return hash
            }
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func aesECBDecryptText(hexCipher: String, asciiKey: String) throws -> String {
        let cleaned = hexCipher.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count.isMultiple(of: 2), !cleaned.isEmpty else {
            throw CloudError.invalidResponse
        }
        let cipher = Data(hex: cleaned)
        guard cipher.count == cleaned.count / 2 else { throw CloudError.invalidResponse }
        let plain = try aesECB(CCOperation(kCCDecrypt), data: cipher, key: Data(asciiKey.utf8))
        guard let text = String(data: plain, encoding: .utf8), !text.isEmpty else {
            throw CloudError.invalidResponse
        }
        return text
    }

    static func randomHex(bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    static func randomASCII(_ count: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<count).map { _ in alphabet.randomElement()! })
    }

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return encoded.replacingOccurrences(of: "%20", with: "+")
    }

    static func uriEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func aesECB(_ operation: CCOperation, data: Data, key: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 || key.count == kCCKeySizeAES192 || key.count == kCCKeySizeAES256 else {
            throw CloudError.failed("加密密钥长度不正确")
        }
        return try crypt(
            operation,
            algorithm: CCAlgorithm(kCCAlgorithmAES),
            options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
            key: key,
            iv: nil,
            data: data
        )
    }

    static func desCBC(_ operation: CCOperation, data: Data, key: Data) throws -> Data {
        guard key.count == kCCKeySizeDES else {
            throw CloudError.failed("登录加密失败")
        }
        return try crypt(
            operation,
            algorithm: CCAlgorithm(kCCAlgorithmDES),
            options: CCOptions(kCCOptionPKCS7Padding),
            key: key,
            iv: key,
            data: data
        )
    }

    /// 360 账号登录信封使用的 RSA 公钥（X.509），只用来加密一次性的 DES 密钥。
    static func rsaPKCS1Encrypt(_ plain: Data) throws -> Data {
        let der = Data(hex: qihooRSA)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw CloudError.failed("无法准备 360 登录加密")
        }
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, plain as CFData, &error) else {
            throw CloudError.failed("360 登录加密失败")
        }
        return encrypted as Data
    }

    private static func crypt(
        _ operation: CCOperation,
        algorithm: CCAlgorithm,
        options: CCOptions,
        key: Data,
        iv: Data?,
        data: Data
    ) throws -> Data {
        let outLength = data.count + kCCBlockSizeAES128
        var output = Data(count: outLength)
        let status: CCCryptorStatus
        let moved: Int
        (status, moved) = output.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    if let iv {
                        return iv.withUnsafeBytes { ivBytes in
                            var localMoved = 0
                            let result = CCCrypt(
                                operation,
                                algorithm,
                                options,
                                keyBytes.baseAddress,
                                key.count,
                                ivBytes.baseAddress,
                                dataBytes.baseAddress,
                                data.count,
                                outBytes.baseAddress,
                                outLength,
                                &localMoved
                            )
                            return (result, localMoved)
                        }
                    }
                    var localMoved = 0
                    let result = CCCrypt(
                        operation,
                        algorithm,
                        options,
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        dataBytes.baseAddress,
                        data.count,
                        outBytes.baseAddress,
                        outLength,
                        &localMoved
                    )
                    return (result, localMoved)
                }
            }
        }
        guard status == kCCSuccess else {
            throw CloudError.invalidResponse
        }
        return output.prefix(moved)
    }

    private static let qihooRSA = "30819f300d06092a864886f70d010101050003818d0030818902818100bda0d6470d7c86c4d35f0617e4ffe580b635444f5b0b590ada0c12c7774f36d4ec38ca9ea9fb3bc707ac9749412ddbf94b556ed0d3f4551eec67c2d83a70a61d0c89ea3339d22c82a35cf91de837dfb7c9f3f2f90e752525cd0b44dd3e1dbda6a06c7efa941181db0b8b34e5740f651c532bd1bb6a6e2ad623803366fced1aa50203010001"
}

private extension Data {
    init(hex: String) {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<next], radix: 16) {
                data.append(byte)
            }
            index = next
        }
        self = data
    }
}
