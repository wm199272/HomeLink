import CoreBluetooth
import SwiftUI

struct JbotLinkView: View {
    @Environment(AppModel.self) private var model
    @StateObject private var scanner = JbotScanner()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Jbotsports Pro 不用云账号。打开发球机后站在旁边，选中它即可关联。开始和停止通过蓝牙直接发给这台机器。")
                    .foregroundStyle(.secondary)
                if let message = scanner.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if scanner.machines.isEmpty {
                    Text(scanner.isScanning ? "正在寻找身边的发球机" : "还没有发现发球机")
                        .foregroundStyle(.secondary)
                }
                ForEach(scanner.machines) { machine in
                    Button(machine.name) {
                        model.link(LinkedAccount(
                            id: UUID(),
                            platform: .jbot,
                            displayName: machine.name,
                            region: nil,
                            linkedAt: Date(),
                            needsRelogin: false,
                            jbot: JbotSession(peripheralID: machine.id.uuidString, name: machine.name)
                        ))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.paper)
        .navigationTitle("Jbotsports Pro")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
    }
}

struct JbotControlSection: View {
    var peripheralID: String
    @StateObject private var controller: JbotController

    init(peripheralID: String) {
        self.peripheralID = peripheralID
        _controller = StateObject(wrappedValue: JbotController(peripheralID: peripheralID))
    }

    var body: some View {
        Section("发球机") {
            Text(controller.status)
                .foregroundStyle(.secondary)
            Button(controller.isBusy ? "正在发送" : "开始发球") {
                controller.startMachine()
            }
            .disabled(controller.isBusy)
            Button("停止") {
                controller.stopMachine()
            }
            .disabled(controller.isBusy)
        }
    }
}

struct JbotMachine: Identifiable {
    var id: UUID
    var name: String
}

final class JbotScanner: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published var machines: [JbotMachine] = []
    @Published var message: String?
    @Published var isScanning = false

    private var central: CBCentralManager?
    private let service = CBUUID(string: "FF10")

    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            scanIfReady()
        }
    }

    func stop() {
        central?.stopScan()
        isScanning = false
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        self.central = central
        switch central.state {
        case .poweredOn:
            message = nil
            isScanning = true
            central.scanForPeripherals(withServices: [service], options: nil)
        case .poweredOff:
            message = "请先打开手机蓝牙"
            isScanning = false
        case .unauthorized:
            message = "请在系统设置里允许家联使用蓝牙"
            isScanning = false
        case .unsupported:
            message = "这台设备没有蓝牙，请换一台 iPhone"
            isScanning = false
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "发球机"
        guard !machines.contains(where: { $0.id == peripheral.identifier }) else { return }
        machines.append(JbotMachine(id: peripheral.identifier, name: name))
    }

    private func scanIfReady() {
        guard central?.state == .poweredOn else { return }
        isScanning = true
        central?.scanForPeripherals(withServices: [service], options: nil)
    }
}

final class JbotController: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "还没有连接"
    @Published var isBusy = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var pending: Data?
    private let target: UUID
    private let service = CBUUID(string: "FF10")
    private let writeUUID = CBUUID(string: "FF11")

    init(peripheralID: String) {
        target = UUID(uuidString: peripheralID) ?? UUID()
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startMachine() {
        send(JbotPacket.start())
    }

    func stopMachine() {
        send(JbotPacket.stop())
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        self.central = central
        guard central.state == .poweredOn else {
            status = central.state == .unauthorized ? "请允许家联使用蓝牙" : "请打开蓝牙并靠近发球机"
            return
        }
        if pending != nil { connect() }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = "已连接，正在准备"
        peripheral.discoverServices([service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isBusy = false
        status = "没有连上发球机，请靠近后再试"
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == self.service }) else {
            isBusy = false
            status = "这台设备没有发球机的蓝牙服务"
            return
        }
        peripheral.discoverCharacteristics([writeUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        writeChar = service.characteristics?.first { $0.uuid == writeUUID }
        flush()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        isBusy = false
        status = error == nil ? "指令已发给发球机" : "发球机没有接受这条指令"
    }

    private func send(_ data: Data) {
        pending = data
        isBusy = true
        status = "正在连接发球机"
        guard central.state == .poweredOn else { return }
        connect()
    }

    private func connect() {
        let found = central.retrievePeripherals(withIdentifiers: [target])
        guard let peripheral = found.first else {
            isBusy = false
            status = "没有找到这台发球机，请靠近后在平台里重新关联"
            return
        }
        self.peripheral = peripheral
        peripheral.delegate = self
        if writeChar != nil {
            flush()
        } else {
            central.connect(peripheral, options: nil)
        }
    }

    private func flush() {
        guard let pending, let peripheral, let writeChar else { return }
        let type: CBCharacteristicWriteType = writeChar.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(pending, for: writeChar, type: type)
        self.pending = nil
        if type == .withoutResponse {
            isBusy = false
            status = "指令已发给发球机"
        }
    }
}

enum JbotPacket {
    static func start() -> Data {
        var data = [UInt8](repeating: 0, count: 28)
        data.append(contentsOf: [30, 30, 3, 0, 0, 1])
        return packet(command: [0x07, 0x22], data: data)
    }

    static func stop() -> Data {
        packet(command: [0x06, 0x01], data: [0])
    }

    private static func packet(command: [UInt8], data: [UInt8]) -> Data {
        var bytes: [UInt8] = [0x7E, 0x3A] + command + data
        let sum = bytes.reduce(0) { $0 + Int($1) }
        bytes.append(UInt8(sum & 0xFF))
        bytes.append(contentsOf: [0x0D, 0x0A])
        return Data(bytes)
    }
}
