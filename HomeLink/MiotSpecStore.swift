import Foundation

final class MiotSpecStore: @unchecked Sendable {
    private var cache: [String: MiotSpec] = [:]
    private let lock = NSLock()
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    func spec(for type: String) async throws -> MiotSpec {
        lock.lock()
        let cached = cache[type]
        lock.unlock()
        if let cached { return cached }

        var components = URLComponents(string: "https://miot-spec.org/miot-spec-v2/instance")
        components?.queryItems = [URLQueryItem(name: "type", value: type)]
        guard let url = components?.url else {
            throw XiaomiError.failed("设备描述地址无效")
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw XiaomiError.failed("没有找到这个设备的功能描述")
        }
        let decoded = try JSONDecoder().decode(MiotSpec.self, from: data)
        lock.lock()
        cache[type] = decoded
        lock.unlock()
        return decoded
    }
}
