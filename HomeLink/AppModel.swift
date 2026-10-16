import Foundation

@MainActor
@Observable
final class AppModel {
    var accounts: [LinkedAccount] = []
    var homes: [IoTHome] = []
    var selectedHomeID: String? {
        didSet {
            guard selectedHomeID != oldValue else { return }
            UserDefaults.standard.set(selectedHomeID, forKey: "selected-home")
        }
    }
    var isRefreshing = false
    var lastError: String?
    var linkGeneration = 0
    var didBootstrap = false
    /// 「全部设备」页里用户自己置顶的设备，数组顺序就是展示顺序。
    /// 只存设备 id：设备每次同步都会重建，存整个设备快照会立刻过期。
    /// 只通过 `togglePin` / `movePinned` 改动，改完会立刻落盘。
    var pinnedDeviceIDs: [String] = []
    private static let pinnedKey = "pinned-devices"

    private let store = AccountStore()
    private let xiaomi = XiaomiCloudClient()
    private let specs = MiotSpecStore()
    private var homeKit: HomeKitBridge?
    private var allowsRefresh = true

    init() {
        accounts = store.loadAccounts()
        homes = store.loadHomes()
        selectedHomeID = UserDefaults.standard.string(forKey: "selected-home")
        pinnedDeviceIDs = UserDefaults.standard.stringArray(forKey: AppModel.pinnedKey) ?? []
        ensureSelection()
        if accounts.contains(where: { $0.platform == .homekit }) {
            activateHomeKit()
        }
    }

    var selectedHome: IoTHome? {
        if let selectedHomeID, let home = homes.first(where: { $0.id == selectedHomeID }) {
            return home
        }
        return homes.first
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        guard allowsRefresh, !accounts.isEmpty else { return }
        await refresh()
    }

    func link(_ account: LinkedAccount) {
        if let index = accounts.firstIndex(where: { sameAccount($0, account) }) {
            var updated = account
            updated.id = accounts[index].id
            if updated.gree != nil {
                let kept = accounts[index].gree?.deviceKeys ?? [:]
                if updated.gree?.deviceKeys.isEmpty == true {
                    updated.gree?.deviceKeys = kept
                }
            }
            accounts[index] = updated
        } else {
            accounts.append(account)
        }
        linkGeneration += 1
        persistAccounts()
        if account.platform == .homekit {
            activateHomeKit()
        }
        Task { await refresh() }
    }

    func linkHomeKit() {
        activateHomeKit()
        guard !accounts.contains(where: { $0.platform == .homekit }) else {
            importHomeKit()
            return
        }
        link(LinkedAccount(
            id: UUID(),
            platform: .homekit,
            displayName: "Apple 家庭",
            region: nil,
            linkedAt: Date(),
            needsRelogin: false,
            xiaomi: nil
        ))
    }

    func unlink(_ id: UUID) {
        let removed = accounts.first { $0.id == id }
        accounts.removeAll { $0.id == id }
        homes.removeAll { $0.accountId == id }
        if removed?.platform == .homekit {
            homeKit = nil
        }
        ensureSelection()
        persistAccounts()
        store.saveHomes(homes)
    }

    func refresh() async {
        guard allowsRefresh, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var next: [IoTHome] = []
        var messages: [String] = []
        let snapshot = accounts
        for account in snapshot where account.platform == .xiaomi && account.xiaomi != nil {
            let result = await loadXiaomi(account)
            apply(result, accountId: account.id, into: &next, messages: &messages)
        }
        for account in snapshot where account.platform == .gree && account.gree != nil {
            let result = await loadGree(account)
            apply(result, accountId: account.id, into: &next, messages: &messages)
        }
        for account in snapshot where account.platform == .qihoo && account.qihoo != nil {
            let result = await loadQihoo(account)
            apply(result, accountId: account.id, into: &next, messages: &messages)
        }
        for account in snapshot where account.platform == .deye && account.deye != nil {
            let result = await loadDeye(account)
            apply(result, accountId: account.id, into: &next, messages: &messages)
        }
        for account in snapshot where account.platform == .broad && account.broad != nil {
            let result = await loadBroad(account)
            apply(result, accountId: account.id, into: &next, messages: &messages)
        }
        for account in snapshot where account.platform == .midea && account.midea != nil {
            let result = await loadMidea(account)
            apply(result, accountId: account.id, into: &next, messages: &messages)
        }
        for account in snapshot where account.platform == .haier && account.haier != nil {
            let result = await loadHaier(account)
            apply(result, accountId: account.id, into: &next, messages: &messages)
        }
        for account in snapshot where account.platform == .mai && account.mai != nil {
            let result = await loadMai(account)
            apply(result, accountId: account.id, into: &next, messages: &messages)
        }
        for account in snapshot where account.platform == .jbot && account.jbot != nil {
            apply(loadJbot(account), accountId: account.id, into: &next, messages: &messages)
        }
        if let account = accounts.first(where: { $0.platform == .homekit }) {
            let imported = homeKit?.makeHomes(accountId: account.id) ?? []
            if let homeKit, !imported.isEmpty || homeKit.isAuthorized {
                next.append(contentsOf: imported)
            } else {
                next.append(contentsOf: homes.filter { $0.platform == .homekit })
            }
        }
        homes = sorted(next)
        ensureSelection()
        persistAccounts()
        store.saveHomes(homes)
        lastError = messages.first
        await loadPowerStates()
    }

    func toggle(_ device: IoTDevice) async {
        guard device.online, device.power == .on || device.power == .off else { return }
        let turningOn = device.power != .on
        mutate(device.id) { $0.power = turningOn ? .on : .off }
        do {
            switch device.platform {
            case .homekit:
                guard let homeKit else { throw XiaomiError.failed("家庭还没有准备好") }
                try await homeKit.setPower(id: device.did, on: turningOn)
            case .xiaomi:
                guard let session = account(for: device)?.xiaomi else { throw XiaomiError.sessionExpired }
                guard let specType = device.specType else { throw XiaomiError.failed("这个设备还不能开关") }
                let spec = try await specs.spec(for: specType)
                guard let power = MiotSpec.powerProperty(in: spec) else {
                    throw XiaomiError.failed("这个设备没有开关")
                }
                try await xiaomi.setProperty(
                    session: session,
                    did: device.did,
                    siid: power.siid,
                    piid: power.piid,
                    value: .bool(turningOn)
                )
            case .gree:
                guard let session = account(for: device)?.gree else { throw CloudError.sessionExpired("格力+") }
                try await GreeCloudClient.writeClimate(session: session, mac: device.did, power: turningOn, mode: nil, temperature: nil, fan: nil)
            case .deye:
                guard device.specType == "fog" else { throw CloudError.failed("这台德业设备使用旧协议，家联目前只能查看它是否在线") }
                let session = try await readyDeye(device)
                try await DeyeCloudClient.write(session: session, deviceID: device.did, power: turningOn, mode: nil, humidity: nil, fan: nil)
            case .midea:
                try await sendMideaPower(device, on: turningOn)
            case .qihoo, .broad, .homerun, .haier, .jbot, .mai, .huawei, .tuya, .aqara:
                throw CloudError.failed("请打开设备页操作这台设备")
            }
        } catch {
            mutate(device.id) { $0.power = turningOn ? .off : .on }
            note(error, accountId: device.accountId)
        }
    }

    func readProperties(device: IoTDevice, refs: [(siid: Int, piid: Int)]) async throws -> [PropReading] {
        guard let session = account(for: device)?.xiaomi else { throw XiaomiError.sessionExpired }
        let request = refs.map { (did: device.did, siid: $0.siid, piid: $0.piid) }
        return try await xiaomi.getProperties(session: session, refs: request)
    }

    func spec(for device: IoTDevice) async throws -> MiotSpec {
        guard let specType = device.specType else {
            throw XiaomiError.failed("米家没有提供这个设备的功能描述")
        }
        return try await specs.spec(for: specType)
    }

    func setProperty(device: IoTDevice, siid: Int, piid: Int, value: JSONScalar) async throws {
        guard let session = account(for: device)?.xiaomi else { throw XiaomiError.sessionExpired }
        try await xiaomi.setProperty(session: session, did: device.did, siid: siid, piid: piid, value: value)
        if let specType = device.specType,
           let spec = try? await specs.spec(for: specType),
           let power = MiotSpec.powerProperty(in: spec),
           power.siid == siid, power.piid == piid,
           case let .bool(on) = value {
            mutate(device.id) { $0.power = on ? .on : .off }
        }
    }

    func runAction(device: IoTDevice, siid: Int, aiid: Int, inputs: [JSONScalar] = []) async throws {
        guard let session = account(for: device)?.xiaomi else { throw XiaomiError.sessionExpired }
        try await xiaomi.runAction(session: session, did: device.did, siid: siid, aiid: aiid, inputs: inputs)
    }

    func readGree(_ device: IoTDevice) async throws -> GreeClimate {
        guard let session = account(for: device)?.gree else { throw CloudError.sessionExpired("格力+") }
        let climate = try await GreeCloudClient.readClimate(session: session, mac: device.did)
        mutate(device.id) { $0.power = climate.power ? .on : .off }
        return climate
    }

    func writeGree(
        _ device: IoTDevice,
        power: Bool?,
        mode: Int?,
        temperature: Int?,
        fan: Int?,
        flags: [String: Int] = [:]
    ) async throws {
        guard let session = account(for: device)?.gree else { throw CloudError.sessionExpired("格力+") }
        try await GreeCloudClient.writeClimate(
            session: session,
            mac: device.did,
            power: power,
            mode: mode,
            temperature: temperature,
            fan: fan,
            flags: flags
        )
        if let power {
            mutate(device.id) { $0.power = power ? .on : .off }
        }
    }

    func sendVacuum(_ device: IoTDevice, command: VacuumCommand) async throws {
        guard let account = account(for: device) else { throw CloudError.sessionExpired("360 智慧生活") }
        try await QihooCloudClient.send(account: account, sn: device.did, command: command)
    }

    func readDeye(_ device: IoTDevice) async throws -> DeyeClimate {
        guard device.specType == "fog" else {
            throw CloudError.failed("这台德业设备使用旧协议，家联目前只能查看它是否在线")
        }
        let session = try await readyDeye(device)
        let climate = try await DeyeCloudClient.readClimate(session: session, deviceID: device.did)
        mutate(device.id) { $0.power = climate.power ? .on : .off }
        return climate
    }

    func writeDeye(_ device: IoTDevice, power: Bool?, mode: Int?, humidity: Int?, fan: Int?) async throws {
        guard device.specType == "fog" else {
            throw CloudError.failed("这台德业设备使用旧协议，家联目前只能查看它是否在线")
        }
        let session = try await readyDeye(device)
        try await DeyeCloudClient.write(session: session, deviceID: device.did, power: power, mode: mode, humidity: humidity, fan: fan)
        if let power {
            mutate(device.id) { $0.power = power ? .on : .off }
        }
    }

    func homeKitTraits(for device: IoTDevice) async -> [HKTrait] {
        guard device.platform == .homekit, let homeKit else { return [] }
        return await homeKit.traits(for: device.did)
    }

    func setHomeKitBool(device: IoTDevice, characteristicID: UUID, on: Bool) async throws {
        guard let homeKit else { throw XiaomiError.failed("家庭还没有准备好") }
        try await homeKit.setBool(accessoryID: device.did, characteristicID: characteristicID, on: on)
        if let current = self.device(id: device.id), current.power != nil {
            let powerCharacteristic = await homeKit.traits(for: device.did).first { $0.title == "开关" && $0.isToggle }
            if powerCharacteristic?.characteristicID == characteristicID {
                mutate(device.id) { $0.power = on ? .on : .off }
            }
        }
    }

    var homeKitStatus: String {
        homeKit?.statusText ?? "尚未请求家庭权限"
    }

    func device(id: String) -> IoTDevice? {
        for home in homes {
            for room in home.rooms {
                if let device = room.devices.first(where: { $0.id == id }) {
                    return device
                }
            }
        }
        return nil
    }

    func deviceCount(for accountId: UUID) -> Int {
        homes.filter { $0.accountId == accountId }.reduce(0) { $0 + $1.devices.count }
    }

    // MARK: 置顶

    func isPinned(_ deviceID: String) -> Bool {
        pinnedDeviceIDs.contains(deviceID)
    }

    func togglePin(_ deviceID: String) {
        if let index = pinnedDeviceIDs.firstIndex(of: deviceID) {
            pinnedDeviceIDs.remove(at: index)
        } else {
            pinnedDeviceIDs.append(deviceID)
        }
        savePins()
    }

    /// 拖动置顶设备之后把新的相对顺序写回去。
    /// - Parameter visible: 当前屏幕上可见的置顶设备（搜索会滤掉一部分），
    ///   `source` / `destination` 都是相对它的下标，所以不能直接改整个数组。
    func movePinned(fromOffsets source: IndexSet, toOffset destination: Int, visible: [String]) {
        var reordered = visible
        reordered.move(fromOffsets: source, toOffset: destination)
        guard reordered != visible else { return }
        // 把可见这几个位置按新顺序换掉，其余（被搜索滤掉的）留在原位。
        let visibleSet = Set(visible)
        var remaining = reordered.makeIterator()
        var next: [String] = []
        for id in pinnedDeviceIDs {
            if visibleSet.contains(id) {
                if let replacement = remaining.next() { next.append(replacement) }
            } else {
                next.append(id)
            }
        }
        pinnedDeviceIDs = next
        savePins()
    }

    private func savePins() {
        UserDefaults.standard.set(pinnedDeviceIDs, forKey: AppModel.pinnedKey)
    }

    private func loadPowerStates() async {
        struct PowerRef: Sendable {
            var id: String
            var did: String
            var siid: Int
            var piid: Int
            var accountId: UUID
        }
        let store = specs
        let pairs: [(id: String, did: String, type: String, accountId: UUID)] = homes
            .flatMap(\.devices)
            .compactMap { device in
                guard device.platform == .xiaomi, let type = device.specType else { return nil }
                return (device.id, device.did, type, device.accountId)
            }
        let found: [PowerRef] = await withTaskGroup(of: PowerRef?.self) { group in
            for item in pairs {
                group.addTask {
                    guard let spec = try? await store.spec(for: item.type),
                          let power = MiotSpec.powerProperty(in: spec) else { return nil }
                    return PowerRef(id: item.id, did: item.did, siid: power.siid, piid: power.piid, accountId: item.accountId)
                }
            }
            var output: [PowerRef] = []
            for await row in group {
                if let row { output.append(row) }
            }
            return output
        }
        let grouped = Dictionary(grouping: found, by: \.accountId)
        for (accountId, refs) in grouped {
            guard let session = accounts.first(where: { $0.id == accountId })?.xiaomi else { continue }
            let request = refs.map { (did: $0.did, siid: $0.siid, piid: $0.piid) }
            guard let readings = try? await xiaomi.getProperties(session: session, refs: request) else { continue }
            for ref in refs {
                let reading = readings.first { $0.did == ref.did && $0.siid == ref.siid && $0.piid == ref.piid }
                let state: PowerState
                switch reading?.value {
                case let .bool(on):
                    state = on ? .on : .off
                case let .int(value):
                    state = value == 0 ? .off : .on
                default:
                    state = .unavailable
                }
                mutate(ref.id) { $0.power = state }
            }
        }
    }

    private func activateHomeKit() {
        guard homeKit == nil else { return }
        let bridge = HomeKitBridge()
        bridge.onUpdate = { [weak self] in
            self?.importHomeKit()
        }
        homeKit = bridge
    }

    private func importHomeKit() {
        guard let homeKit, let account = accounts.first(where: { $0.platform == .homekit }) else { return }
        var next = homes.filter { $0.platform != .homekit }
        next.append(contentsOf: homeKit.makeHomes(accountId: account.id))
        homes = sorted(next)
        ensureSelection()
        store.saveHomes(homes)
    }

    private func account(for device: IoTDevice) -> LinkedAccount? {
        accounts.first { $0.id == device.accountId }
    }

    private func mutate(_ id: String, _ body: (inout IoTDevice) -> Void) {
        var copy = homes
        for homeIndex in copy.indices {
            for roomIndex in copy[homeIndex].rooms.indices {
                guard let deviceIndex = copy[homeIndex].rooms[roomIndex].devices.firstIndex(where: { $0.id == id }) else { continue }
                body(&copy[homeIndex].rooms[roomIndex].devices[deviceIndex])
            }
        }
        homes = copy
    }

    private func note(_ error: Error, accountId: UUID) {
        lastError = humanize(error)
        let expiredXiaomi = (error as? XiaomiError).map { if case .sessionExpired = $0 { return true }; return false } ?? false
        let expiredCloud = (error as? CloudError).map { if case .sessionExpired = $0 { return true }; return false } ?? false
        if expiredXiaomi || expiredCloud {
            if let index = accounts.firstIndex(where: { $0.id == accountId }) {
                accounts[index].needsRelogin = true
                persistAccounts()
            }
        }
    }

    private struct SyncResult {
        var homes: [IoTHome] = []
        var message: String?
        var relogin = false
        var greeKeys: [String: String]?
        var qihoo: QihooSession?
        var deyeToken: String?
        var haier: HaierSession?
    }

    private func loadXiaomi(_ account: LinkedAccount) async -> SyncResult {
        do {
            let fetched = try await xiaomi.fetchHomes(account: account)
            return SyncResult(homes: fetched)
        } catch XiaomiError.sessionExpired {
            return SyncResult(message: "\(account.displayName) 的登录已过期", relogin: true)
        } catch {
            return SyncResult(message: "\(account.displayName)：\(humanize(error))")
        }
    }

    private func loadGree(_ account: LinkedAccount) async -> SyncResult {
        do {
            let fetched = try await GreeCloudClient.fetchHomes(account: account)
            return SyncResult(homes: fetched.homes, greeKeys: fetched.keys)
        } catch let error as CloudError {
            if case .sessionExpired = error {
                return SyncResult(message: "\(account.displayName) 的登录已过期", relogin: true)
            }
            return SyncResult(message: "\(account.displayName)：\(humanize(error))")
        } catch {
            return SyncResult(message: "\(account.displayName)：\(humanize(error))")
        }
    }

    private func loadQihoo(_ account: LinkedAccount) async -> SyncResult {
        do {
            let fetched = try await QihooCloudClient.fetchHomes(account: account)
            return SyncResult(homes: fetched.homes, qihoo: fetched.session)
        } catch let error as CloudError {
            if case .sessionExpired = error {
                return SyncResult(message: "\(account.displayName) 的登录已过期", relogin: true)
            }
            return SyncResult(message: "\(account.displayName)：\(humanize(error))")
        } catch {
            return SyncResult(message: "\(account.displayName)：\(humanize(error))")
        }
    }

    func setMideaPower(_ device: IoTDevice, on: Bool) async throws {
        try await sendMideaPower(device, on: on)
        mutate(device.id) { $0.power = on ? .on : .off }
    }

    private func sendMideaPower(_ device: IoTDevice, on: Bool) async throws {
        guard let session = account(for: device)?.midea else { throw CloudError.sessionExpired("美的美居") }
        guard let specType = device.specType else { throw CloudError.failed("这台美的设备还没有读到开关") }
        try await MideaCloudClient.setPower(session: session, deviceID: device.did, specType: specType, on: on)
    }

    private func loadBroad(_ account: LinkedAccount) async -> SyncResult {
        do {
            return SyncResult(homes: try await BroadCloudClient.fetchHomes(account: account))
        } catch let error as CloudError {
            if case .sessionExpired = error {
                return SyncResult(message: "\(account.displayName) 的登录已过期", relogin: true)
            }
            return SyncResult(message: "\(account.displayName)：\(humanize(error))")
        } catch {
            return SyncResult(message: "\(account.displayName)：\(humanize(error))")
        }
    }

    private func loadMidea(_ account: LinkedAccount) async -> SyncResult {
        do {
            return SyncResult(homes: try await MideaCloudClient.fetchHomes(account: account))
        } catch let error as CloudError {
            if case .sessionExpired = error {
                return SyncResult(message: "\(account.displayName) 的登录已过期", relogin: true)
            }
            return SyncResult(message: "\(account.displayName)：\(humanize(error))")
        } catch {
            return SyncResult(message: "\(account.displayName)：\(humanize(error))")
        }
    }

    private func loadHaier(_ account: LinkedAccount) async -> SyncResult {
        do {
            let fetched = try await HaierCloudClient.fetchHomes(account: account)
            return SyncResult(homes: fetched.homes, haier: fetched.session)
        } catch let error as CloudError {
            if case .sessionExpired = error {
                return SyncResult(message: "\(account.displayName) 的登录已过期", relogin: true)
            }
            return SyncResult(message: "\(account.displayName)：\(humanize(error))")
        } catch {
            return SyncResult(message: "\(account.displayName)：\(humanize(error))")
        }
    }

    private func loadMai(_ account: LinkedAccount) async -> SyncResult {
        do {
            return SyncResult(homes: try await MaiCloudClient.fetchHomes(account: account))
        } catch let error as CloudError {
            if case .sessionExpired = error {
                return SyncResult(message: "\(account.displayName) 的登录已过期", relogin: true)
            }
            return SyncResult(message: "\(account.displayName)：\(humanize(error))")
        } catch {
            return SyncResult(message: "\(account.displayName)：\(humanize(error))")
        }
    }

    private func loadJbot(_ account: LinkedAccount) -> SyncResult {
        guard let session = account.jbot else { return SyncResult() }
        let device = IoTDevice(
            id: "\(account.id.uuidString):\(session.peripheralID)",
            did: session.peripheralID,
            name: session.name,
            model: "Jbotsports Pro",
            online: true,
            specType: "ble",
            localIP: nil,
            roomName: "身边",
            homeName: "发球机",
            homeId: account.id.uuidString,
            accountId: account.id,
            platform: .jbot,
            category: .other,
            power: nil
        )
        let room = IoTRoom(id: "\(account.id.uuidString):court", name: "身边", devices: [device])
        return SyncResult(homes: [IoTHome(
            id: account.id.uuidString,
            homeId: account.id.uuidString,
            name: "发球机",
            platform: .jbot,
            accountId: account.id,
            rooms: [room]
        )])
    }

    private func loadDeye(_ account: LinkedAccount) async -> SyncResult {
        do {
            let fetched = try await DeyeCloudClient.fetchHomes(account: account)
            return SyncResult(homes: fetched.homes, deyeToken: fetched.token)
        } catch let error as CloudError {
            if case .sessionExpired = error {
                return SyncResult(message: "\(account.displayName) 的登录已过期", relogin: true)
            }
            return SyncResult(message: "\(account.displayName)：\(humanize(error))")
        } catch {
            return SyncResult(message: "\(account.displayName)：\(humanize(error))")
        }
    }

    private func apply(_ result: SyncResult, accountId: UUID, into next: inout [IoTHome], messages: inout [String]) {
        guard let index = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        if result.relogin {
            accounts[index].needsRelogin = true
        } else if result.message == nil {
            accounts[index].needsRelogin = false
        }
        if let keys = result.greeKeys, !keys.isEmpty {
            var merged = accounts[index].gree?.deviceKeys ?? [:]
            for (mac, key) in keys { merged[mac] = key }
            accounts[index].gree?.deviceKeys = merged
        }
        if let session = result.qihoo {
            accounts[index].qihoo = session
        }
        if let token = result.deyeToken {
            accounts[index].deye?.token = token
        }
        if let session = result.haier {
            accounts[index].haier = session
        }
        if result.homes.isEmpty {
            next.append(contentsOf: homes.filter { $0.accountId == accountId })
        } else {
            next.append(contentsOf: result.homes)
        }
        if let message = result.message {
            messages.append(message)
        }
    }

    private func sameAccount(_ existing: LinkedAccount, _ account: LinkedAccount) -> Bool {
        guard existing.platform == account.platform else { return false }
        switch account.platform {
        case .xiaomi:
            return account.xiaomi?.userId != nil && existing.xiaomi?.userId == account.xiaomi?.userId && existing.region == account.region
        case .homekit:
            return true
        case .gree:
            return account.gree?.username != nil && existing.gree?.username == account.gree?.username && existing.region == account.region
        case .qihoo:
            return account.qihoo?.qid != nil && existing.qihoo?.qid == account.qihoo?.qid
        case .deye:
            return account.deye?.username != nil && existing.deye?.username == account.deye?.username
        case .broad:
            return account.broad?.username != nil && existing.broad?.username == account.broad?.username
        case .midea:
            return account.midea?.account != nil && existing.midea?.account == account.midea?.account
        case .haier:
            if let userID = account.haier?.userID, !userID.isEmpty {
                return existing.haier?.userID == userID
            }
            return account.haier?.username != nil && existing.haier?.username == account.haier?.username
        case .mai:
            return account.mai?.email.lowercased() != nil && existing.mai?.email.lowercased() == account.mai?.email.lowercased()
        case .jbot:
            return account.jbot?.peripheralID != nil && existing.jbot?.peripheralID == account.jbot?.peripheralID
        case .homerun, .huawei, .tuya, .aqara:
            return false
        }
    }

    private func readyDeye(_ device: IoTDevice) async throws -> DeyeSession {
        guard let current = account(for: device)?.deye else { throw CloudError.sessionExpired("德业智能") }
        let next = try await DeyeCloudClient.renew(current)
        if next.token != current.token, let index = accounts.firstIndex(where: { $0.id == device.accountId }) {
            accounts[index].deye = next
            accounts[index].needsRelogin = false
            persistAccounts()
        }
        return next
    }

    private func ensureSelection() {
        if let selectedHomeID, homes.contains(where: { $0.id == selectedHomeID }) { return }
        selectedHomeID = homes.first?.id
    }

    private func persistAccounts() {
        do {
            try store.saveAccounts(accounts)
        } catch {
            lastError = humanize(error)
        }
    }

    private func sorted(_ homes: [IoTHome]) -> [IoTHome] {
        homes.sorted { lhs, rhs in
            if lhs.platform.sortOrder != rhs.platform.sortOrder {
                return lhs.platform.sortOrder < rhs.platform.sortOrder
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
