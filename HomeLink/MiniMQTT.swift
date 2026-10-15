import Foundation
import Network

/// 短连接 MQTT 3.1.1。格力云代理使用自签证书，只在这里跳过系统校验。
final class MiniMQTT: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.homelink.mqtt")
    private let lock = NSLock()
    private var buffer = Data()
    private var failed: Error?
    private var ended = false
    private var reading = false
    private var packetID: UInt16 = 1

    init(host: String, port: UInt16) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, queue)
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 1984,
            using: NWParameters(tls: tls)
        )
    }

    func connect(clientID: String, username: String, password: String) async throws {
        try await ready()
        try await send(Self.connectPacket(clientID: clientID, username: username, password: password))
        guard let ack = try await nextPacket(timeout: 12), ack.first == 0x20, ack.last == 0 else {
            throw CloudError.failed("云端没有接受这次连接")
        }
    }

    func subscribe(topic: String) async throws {
        let id = nextID()
        try await send(Self.subscribePacket(id: id, topic: topic))
    }

    func publish(topic: String, payload: Data) async throws {
        try await send(Self.publishPacket(id: nextID(), topic: topic, payload: payload))
    }

    func readPublish(until deadline: Date) async throws -> (String, Data)? {
        while Date() < deadline {
            guard let packet = try await nextPacket(timeout: max(0.2, deadline.timeIntervalSinceNow)) else {
                return nil
            }
            if packet.first == 0x30 || packet.first == 0x32 || (packet.first ?? 0) >> 4 == 3 {
                if let parsed = Self.parsePublish(packet) {
                    if parsed.qos > 0 {
                        try? await send(Self.pubAck(parsed.id))
                    }
                    return (parsed.topic, parsed.payload)
                }
            }
        }
        return nil
    }

    func close() {
        lock.lock()
        ended = true
        lock.unlock()
        connection.cancel()
    }

    private func ready() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = NSLock()
            var resumed = false
            func finish(_ result: Result<Void, Error>) {
                gate.lock()
                defer { gate.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case let .failed(error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(CloudError.failed("连接已取消")))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        ensureReading()
    }

    private func ensureReading() {
        lock.lock()
        let busy = reading || ended
        if !busy { reading = true }
        lock.unlock()
        guard !busy else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.lock.lock()
            if let data { self.buffer.append(data) }
            if let error { self.failed = error }
            if isComplete { self.ended = true }
            self.reading = false
            let stop = self.ended || self.failed != nil
            self.lock.unlock()
            if !stop {
                self.ensureReading()
            }
        }
    }

    private func nextPacket(timeout: TimeInterval) async throws -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let packet = popPacket() { return packet }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 30_000_000)
            if let packet = popPacket() { return packet }
            lock.lock()
            let error = failed
            let stop = ended
            lock.unlock()
            if let error { throw error }
            if stop { throw CloudError.failed("连接已关闭") }
        }
        return popPacket()
    }

    private func popPacket() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return popPacketLocked()
    }

    /// 读取「剩余长度」字段。注意 `Data` 的 `startIndex` 不一定是 0，
    /// 每次 `removeFirst` 之后 `startIndex` 都会前移，所以必须用绝对下标 base + offset。
    private func remainingLengthLocked() -> (headerBytes: Int, bodyLength: Int)? {
        guard buffer.count >= 2 else { return nil }
        let base = buffer.startIndex
        var offset = 1
        var multiplier = 1
        var length = 0
        while offset < buffer.count && offset < 6 {
            let byte = Int(buffer[base + offset])
            length += (byte & 0x7F) * multiplier
            offset += 1
            if byte & 0x80 == 0 {
                return (offset, length)
            }
            multiplier *= 128
        }
        return nil
    }

    private func popPacketLocked() -> Data? {
        guard let (headerBytes, bodyLength) = remainingLengthLocked() else { return nil }
        let total = headerBytes + bodyLength
        guard buffer.count >= total else { return nil }
        let base = buffer.startIndex
        let packet = Data(Array(buffer[base..<(base + total)]))
        // 用 dropFirst 重建，既保证 buffer.startIndex 归零，也及时回收已消费的内存。
        buffer = Data(Array(buffer.dropFirst(total)))
        return packet
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func nextID() -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        packetID &+= 1
        if packetID == 0 { packetID = 1 }
        return packetID
    }

    private static func connectPacket(clientID: String, username: String, password: String) -> Data {
        var body = Data()
        body.append(mqttString("MQTT"))
        body.append(4)
        body.append(0xC2)
        body.append(0)
        body.append(60)
        body.append(mqttString(clientID))
        body.append(mqttString(username))
        body.append(mqttString(password))
        var packet = Data([0x10])
        packet.append(remaining(body.count))
        packet.append(body)
        return packet
    }

    private static func subscribePacket(id: UInt16, topic: String) -> Data {
        var body = Data([UInt8(id >> 8), UInt8(id & 0xFF)])
        body.append(mqttString(topic))
        body.append(0)
        var packet = Data([0x82])
        packet.append(remaining(body.count))
        packet.append(body)
        return packet
    }

    private static func publishPacket(id: UInt16, topic: String, payload: Data) -> Data {
        var body = mqttString(topic)
        body.append(contentsOf: [UInt8(id >> 8), UInt8(id & 0xFF)])
        body.append(payload)
        var packet = Data([0x32])
        packet.append(remaining(body.count))
        packet.append(body)
        return packet
    }

    private static func pubAck(_ id: UInt16) -> Data {
        Data([0x40, 0x02, UInt8(id >> 8), UInt8(id & 0xFF)])
    }

    private static func parsePublish(_ packet: Data) -> (topic: String, payload: Data, qos: Int, id: UInt16)? {
        guard packet.count > 4, packet[0] >> 4 == 3 else { return nil }
        var index = 1
        while index < packet.count && packet[index] & 0x80 != 0 { index += 1 }
        index += 1
        guard index + 2 <= packet.count else { return nil }
        let topicLength = Int(packet[index]) << 8 | Int(packet[index + 1])
        index += 2
        guard index + topicLength <= packet.count else { return nil }
        let topic = String(data: packet.subdata(in: index..<(index + topicLength)), encoding: .utf8) ?? ""
        index += topicLength
        let qos = Int((packet[0] & 0x06) >> 1)
        var id: UInt16 = 0
        if qos > 0 {
            guard index + 2 <= packet.count else { return nil }
            id = UInt16(packet[index]) << 8 | UInt16(packet[index + 1])
            index += 2
        }
        return (topic, packet.subdata(in: index..<packet.count), qos, id)
    }

    private static func mqttString(_ text: String) -> Data {
        let bytes = Data(text.utf8)
        var data = Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)])
        data.append(bytes)
        return data
    }

    private static func remaining(_ length: Int) -> Data {
        var value = length
        var data = Data()
        repeat {
            var digit = UInt8(value % 128)
            value /= 128
            if value > 0 { digit |= 0x80 }
            data.append(digit)
        } while value > 0
        return data
    }
}
