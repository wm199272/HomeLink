import CommonCrypto
import CryptoKit
import Foundation

enum XiaomiCrypto {
    static func md5Upper(_ text: String) -> String {
        let data = Data(text.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_MD5(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    static func md5Lower(_ text: String) -> String {
        md5Upper(text).lowercased()
    }

    static func nonce(now: Date = Date()) -> String {
        var bytes = Data((0..<8).map { _ in UInt8.random(in: .min ... .max) })
        let millis = Int64((now.timeIntervalSince1970 * 1000).rounded())
        var minutes = UInt32(millis / 60_000).bigEndian
        withUnsafeBytes(of: &minutes) { bytes.append(contentsOf: $0) }
        return bytes.base64EncodedString()
    }

    static func signedNonce(ssecurity: String, nonce: String) throws -> String {
        guard let secret = decodeBase64(ssecurity), let nonceData = decodeBase64(nonce) else {
            throw XiaomiError.failed("登录凭证格式不正确")
        }
        var material = secret
        material.append(nonceData)
        return Data(SHA256.hash(data: material)).base64EncodedString()
    }

    static func encryptedFields(
        url: String,
        method: String,
        signedNonce: String,
        nonce: String,
        dataJSON: String,
        ssecurity: String
    ) throws -> [(String, String)] {
        var params: [(String, String)] = [("data", dataJSON)]
        let rc4Hash = encryptedSignature(method: method, url: url, signedNonce: signedNonce, params: params)
        params.append(("rc4_hash__", rc4Hash))
        let encrypted = try params.map { key, value in
            (key, try encryptRC4(passwordBase64: signedNonce, payload: value))
        }
        let signature = encryptedSignature(method: method, url: url, signedNonce: signedNonce, params: encrypted)
        var fields = encrypted
        fields.append(("signature", signature))
        fields.append(("ssecurity", ssecurity))
        fields.append(("_nonce", nonce))
        return fields
    }

    static func encryptRC4(passwordBase64: String, payload: String) throws -> String {
        guard let key = decodeBase64(passwordBase64) else {
            throw XiaomiError.failed("无法加密请求")
        }
        let encrypted = rc4(key: key, data: Data(payload.utf8), drop: 1024)
        return encrypted.base64EncodedString()
    }

    static func decryptRC4(passwordBase64: String, payloadBase64: String) throws -> String {
        guard let key = decodeBase64(passwordBase64), let data = decodeBase64(payloadBase64) else {
            throw XiaomiError.invalidResponse
        }
        let plain = rc4(key: key, data: data, drop: 1024)
        guard let text = String(data: plain, encoding: .utf8) else {
            throw XiaomiError.invalidResponse
        }
        return text
    }

    /// RC4，并丢弃前 1024 字节密钥流。米家云接口与 PyCryptodome 的用法一致。
    static func rc4(key: Data, data: Data, drop: Int) -> Data {
        var box = Array(0...255)
        var j = 0
        let keyBytes = [UInt8](key)
        guard !keyBytes.isEmpty else { return data }
        for i in 0..<256 {
            j = (j + box[i] + Int(keyBytes[i % keyBytes.count])) % 256
            box.swapAt(i, j)
        }
        var i = 0
        j = 0
        func nextByte() -> UInt8 {
            i = (i + 1) % 256
            j = (j + box[i]) % 256
            box.swapAt(i, j)
            return UInt8(box[(box[i] + box[j]) % 256])
        }
        for _ in 0..<drop {
            _ = nextByte()
        }
        var output = Data(count: data.count)
        for index in data.indices {
            output[index] = data[index] ^ nextByte()
        }
        return output
    }

    static func encryptedSignature(
        method: String,
        url: String,
        signedNonce: String,
        params: [(String, String)]
    ) -> String {
        var parts = [method.uppercased(), apiPath(from: url)]
        parts.append(contentsOf: params.map { "\($0.0)=\($0.1)" })
        parts.append(signedNonce)
        let digest = Insecure.SHA1.hash(data: Data(parts.joined(separator: "&").utf8))
        return Data(digest).base64EncodedString()
    }

    static func apiPath(from url: String) -> String {
        guard let range = url.range(of: "com") else { return url }
        return url[range.upperBound...].replacingOccurrences(of: "/app/", with: "/")
    }

    static func formEncode(_ fields: [(String, String)]) -> String {
        fields.map { "\(percent($0.0))=\(percent($0.1))" }.joined(separator: "&")
    }

    static func percent(_ value: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return encoded.replacingOccurrences(of: "%20", with: "+")
    }

    static func decodeBase64(_ string: String) -> Data? {
        var text = string.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        let remainder = text.count % 4
        if remainder > 0 {
            text += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: text)
    }

    static func randomAgent() -> String {
        let head = String((0..<18).map { _ in Character(UnicodeScalar(Int.random(in: 97...122))!) })
        let tail = String((0..<13).map { _ in Character(UnicodeScalar(Int.random(in: 65...69))!) })
        return "\(head)-\(tail) APP/com.xiaomi.mihome APPV/10.5.201"
    }

    static func randomDeviceID() -> String {
        String((0..<6).map { _ in Character(UnicodeScalar(Int.random(in: 97...122))!) })
    }

    static func apiBase(server: String) -> String {
        if server.isEmpty || server == "cn" {
            return "https://api.io.mi.com/app"
        }
        return "https://\(server).api.io.mi.com/app"
    }
}
