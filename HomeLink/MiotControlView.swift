import SwiftUI

/// 米家设备详情页，照着米家 App 的样子做。
///
/// 上面一张按模式换色的大卡片：拨盘转设定温度、室温湿度读数、底下一个大圆开关。
/// 往下依次是模式、风速的芯片，摆风和其余开关的瓦片，再下面是精细调节、实时数据、
/// 快捷功能，最后是设备信息。
///
/// 功能全部从米家的设备描述（MIoT spec）里认出来，认不出来的属性按类型落到
/// 开关瓦片、滑杆、选项和实时数据里，所以什么设备都能用同一套界面。
struct MiotControlView: View {
    @Environment(AppModel.self) private var model
    var device: IoTDevice

    @State private var roles = MiotRoles()
    @State private var values: [String: JSONScalar] = [:]
    @State private var drafts: [String: Double] = [:]
    @State private var isLoading = false
    @State private var message: String?
    @State private var vacuumRooms: [VacuumRoom] = []
    @State private var selectedRooms: Set<Int> = []
    @State private var didLoadRooms = false
    @State private var sheet: VacuumSheet?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Color.clay)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.clay.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if let vacuum = roles.vacuum {
                    vacuumStatus(vacuum)
                    vacuumMap(vacuum)
                    vacuumActions(vacuum)
                    vacuumRows(vacuum)
                    vacuumStation(vacuum)
                } else {
                    hero
                    modeSection
                    fanSection
                    swingSection
                }
                toggleSection
                sliderSection
                chooserSection
                readingSection
                actionSection
                SectionCard("信息", symbol: "info.circle") {
                    DeviceInfoContent(device: device)
                }
                if let note = cloudNote(device.platform) {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 30)
        }
        .background(Color.paper)
        .refreshable { await refresh() }
        .task(id: device.id) { await load() }
        .sheet(item: $sheet) { which in
            switch which {
            case .rooms: roomSheet()
            case .settings: settingsSheet()
            }
        }
    }

    // MARK: - 大卡片

    private var hero: some View {
        HeroCard(tint: accent, dimmed: dimmed) {
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    Text(statusLine)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer(minLength: 0)
                    if isLoading {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }
                if let target = roles.target, let range = target.property.sliderBounds {
                    HStack(spacing: 8) {
                        StepButton(symbol: "minus", enabled: controlsEnabled) {
                            step(target, by: -target.property.sliderStep)
                        }
                        DialControl(
                            value: Binding(
                                get: { draft(target, range: range) },
                                set: { drafts[target.id] = $0 }
                            ),
                            range: range,
                            step: target.property.sliderStep,
                            headline: dialText(target, range: range),
                            caption: "设定温度",
                            accent: accent,
                            enabled: controlsEnabled,
                            onCommit: { commit(target) }
                        )
                        StepButton(symbol: "plus", enabled: controlsEnabled) {
                            step(target, by: target.property.sliderStep)
                        }
                    }
                } else if let brightness = roles.brightness, let range = brightness.property.sliderBounds {
                    VStack(spacing: 14) {
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.white.opacity(0.9))
                        Slider(
                            value: Binding(
                                get: { draft(brightness, range: range) },
                                set: { drafts[brightness.id] = $0 }
                            ),
                            in: range,
                            step: brightness.property.sliderStep,
                            onEditingChanged: { editing in
                                if !editing { commit(brightness) }
                            }
                        )
                        .tint(.white)
                        Text(draftText(brightness, range: range))
                            .font(.title3.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    .padding(.vertical, 4)
                } else {
                    Image(systemName: device.category.symbol)
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(height: 130)
                }
                HStack(spacing: 10) {
                    ForEach(Array(heroReadouts.enumerated()), id: \.offset) { _, item in
                        HeroReadout(title: item.title, value: item.value)
                    }
                }
                if roles.power != nil {
                    PowerButton(on: isOn, tint: accent, enabled: !isLoading && device.online) {
                        togglePower()
                    }
                }
            }
        }
    }

    // MARK: - 扫地机

    /// 页顶那颗浅灰胶囊：最近清洁时间 + 电量，跟米家里那颗一样。
    @ViewBuilder
    private func vacuumStatus(_ vacuum: VacuumRoles) -> some View {
        let battery = batteryText(vacuum)
        if lastCleanText != nil || battery != nil {
            VacuumStatusChip(
                lastClean: lastCleanText,
                battery: battery,
                batterySymbol: batterySymbol(vacuum),
                batteryTint: batteryTint(vacuum)
            )
        }
    }

    /// 扫地机页的主体：房间格就是这块「地图」。
    ///
    /// 米家里的那张地图是机器人自己画出来的栅格图，走的不是 MIoT 描述这条路，
    /// 所以这里用房间格代替：一眼看清有哪些房间、点一下选中，开始清洁就只扫选中的。
    @ViewBuilder
    private func vacuumMap(_ vacuum: VacuumRoles) -> some View {
        SectionCard(symbol: "robotic.vacuum.fill") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(vacuumStateText(vacuum))
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else if let progress = vacuumProgress(vacuum) {
                        Text("\(Int(progress))%")
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if let progress = vacuumProgress(vacuum), progress > 0 {
                    ProgressView(value: progress, total: 100)
                        .tint(Color.moss)
                }
                if vacuumRooms.isEmpty {
                    HStack(spacing: 14) {
                        Image(systemName: "robotic.vacuum.fill")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Color.moss)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(vacuumRoomHint)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text("这台扫地机没有上报房间列表，点「开始清洁」扫全屋。")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TileGrid(columns: 3) {
                        ForEach(vacuumRooms) { room in
                            RoomTile(
                                room: room,
                                selected: selectedRooms.contains(room.id),
                                enabled: !isLoading && device.online
                            ) {
                                toggleRoom(room)
                            }
                        }
                    }
                    Text(vacuumRoomHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let fault = vacuumFaultText(vacuum) {
                    Label(fault, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.clay)
                }
                let candidates: [(String, MiotPropertyRef?)] = [
                    ("已扫面积", vacuum.cleanedArea),
                    ("已扫时长", vacuum.cleanedDuration),
                ]
                let tiles: [(String, MiotPropertyRef)] = candidates.compactMap { name, ref in
                    guard let ref, values[ref.id] != nil else { return nil }
                    return (name, ref)
                }
                if !tiles.isEmpty {
                    TileGrid {
                        ForEach(Array(tiles.enumerated()), id: \.offset) { _, item in
                            ReadoutTile(
                                title: item.0,
                                symbol: ControlIcon.symbol(for: item.1.name),
                                value: readoutText(item.1)
                            )
                        }
                    }
                }
            }
        }
        .controlGroup(canControl)
    }

    /// 下面那两颗大按钮：基座、开始清洁／暂停。
    @ViewBuilder
    private func vacuumActions(_ vacuum: VacuumRoles) -> some View {
        HStack(spacing: 12) {
            if vacuum.dock != nil {
                BigActionButton(
                    title: "基座",
                    caption: "回充",
                    symbol: "bolt.square.fill",
                    tint: Color.secondary,
                    enabled: canControl
                ) {
                    sendVacuumAction(vacuum.dock, "已让扫地机回充")
                }
            }
            let running = vacuumIsRunning(vacuum)
            BigActionButton(
                title: running ? "暂停" : "开始清洁",
                caption: running ? nil : (selectedRooms.isEmpty ? "全屋" : "已选 \(selectedRooms.count) 个房间"),
                symbol: running ? "pause.fill" : "play.fill",
                tint: ControlPalette.cool,
                highlighted: !running,
                enabled: canControl && (running || vacuum.start != nil || vacuum.roomStart != nil || vacuum.on != nil)
            ) {
                if running {
                    sendVacuumAction(vacuum.pause ?? vacuum.stop, "已暂停")
                } else {
                    startVacuumCleaning(vacuum)
                }
            }
        }
    }

    /// 「区域 全屋 ›」「模式 仅拖地 ›」两行，点开去设置。
    @ViewBuilder
    private func vacuumRows(_ vacuum: VacuumRoles) -> some View {
        if !vacuumRooms.isEmpty || hasCleanSettings(vacuum) {
            SectionCard {
                VStack(spacing: 14) {
                    if !vacuumRooms.isEmpty {
                        SettingRow(
                            title: "区域",
                            value: selectedRooms.isEmpty ? "全屋" : "已选 \(selectedRooms.count) 个房间",
                            enabled: canControl
                        ) {
                            sheet = .rooms
                        }
                    }
                    if hasCleanSettings(vacuum) {
                        SettingRow(
                            title: "模式",
                            value: sweepModeText(vacuum),
                            enabled: canControl
                        ) {
                            sheet = .settings
                        }
                    }
                }
            }
            .controlGroup(canControl)
        }
    }

    /// 基站的动作和剩余时间（洗拖布、烘干、集尘），只在设备上报了这些列时出现。
    @ViewBuilder
    private func vacuumStation(_ vacuum: VacuumRoles) -> some View {
        let actions = [vacuum.mopWash, vacuum.dry, vacuum.dustArrest].compactMap { $0 }
        let candidates: [(String, MiotPropertyRef?)] = [
            ("洗拖布剩余", vacuum.mopWashLeft),
            ("烘干剩余", vacuum.dryLeft),
            ("集尘剩余", vacuum.dustLeft),
        ]
        let lefts: [(String, MiotPropertyRef)] = candidates.compactMap { name, ref in
            guard let ref, values[ref.id] != nil else { return nil }
            return (name, ref)
        }
        let station = vacuum.stationStatus.flatMap { values[$0.id] }

        if !actions.isEmpty || !lefts.isEmpty || station != nil {
            SectionCard("基站", symbol: "house.fill") {
                VStack(alignment: .leading, spacing: 14) {
                    if let station, case let .string(text) = station, !text.isEmpty {
                        Text(text)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !actions.isEmpty {
                        WrapLayout(spacing: 10, lineSpacing: 10) {
                            ForEach(actions) { ref in
                                Button {
                                    sendVacuumAction(ref, "已下发" + MiotNaming.title(type: ref.action.type, fallback: ref.action.description))
                                } label: {
                                    Label(
                                        MiotNaming.title(type: ref.action.type, fallback: ref.action.description),
                                        systemImage: ControlIcon.symbol(for: ref.name)
                                    )
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.moss)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(Color.moss.opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .disabled(!canControl)
                            }
                        }
                    }
                    if !lefts.isEmpty {
                        TileGrid {
                            ForEach(Array(lefts.enumerated()), id: \.offset) { _, item in
                                ReadoutTile(
                                    title: item.0,
                                    symbol: "timer",
                                    value: readoutText(item.1)
                                )
                            }
                        }
                    }
                }
            }
            .controlGroup(canControl)
        }
    }

    // MARK: - 扫地机的弹窗

    private func roomSheet() -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    WrapLayout(spacing: 10, lineSpacing: 10) {
                        ChoiceChip(title: "全屋", selected: selectedRooms.isEmpty) {
                            selectedRooms = []
                        }
                        ForEach(vacuumRooms) { room in
                            ChoiceChip(title: room.displayName, selected: selectedRooms.contains(room.id)) {
                                toggleRoom(room)
                            }
                        }
                    }
                    Text("选好后点「开始清洁」，只扫选中的房间；一个都不选就是全屋。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(Color.paper)
            .navigationTitle("区域")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { sheet = nil }
                }
            }
        }
    }

    private func settingsSheet() -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let vacuum = roles.vacuum {
                        optionGroup("扫拖模式", ref: vacuum.sweepMopType)
                        optionGroup("吸力", ref: vacuum.suction)
                        optionGroup("拖地水量", ref: vacuum.waterLevel)
                        optionGroup("清扫方式", ref: vacuum.sweepType)
                    }
                }
                .padding(20)
            }
            .background(Color.paper)
            .navigationTitle("清洁设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { sheet = nil }
                }
            }
        }
    }

    @ViewBuilder
    private func optionGroup(_ title: String, ref: MiotPropertyRef?) -> some View {
        if let ref, let options = ref.property.valueList, !options.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                WrapLayout(spacing: 10, lineSpacing: 10) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        ChoiceChip(
                            title: VacuumNaming.optionTitle(option.description, property: ref.name),
                            selected: values[ref.id] == option.value
                        ) {
                            write(ref, value: option.value)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 各组

    @ViewBuilder
    private var modeSection: some View {
        if let mode = roles.mode, let options = mode.property.valueList, !options.isEmpty {
            SectionCard("模式", symbol: "dial.medium") {
                WrapLayout(spacing: 10, lineSpacing: 10) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        ChoiceChip(
                            title: MiotNaming.optionTitle(option.description),
                            selected: values[mode.id] == option.value
                        ) {
                            write(mode, value: option.value)
                        }
                    }
                }
            }
            .controlGroup(controlsEnabled)
        }
    }

    @ViewBuilder
    private var fanSection: some View {
        if let fan = roles.fan {
            if let options = fan.property.valueList, !options.isEmpty {
                SectionCard("风速", symbol: "fan.fill") {
                    WrapLayout(spacing: 10, lineSpacing: 10) {
                        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                            ChoiceChip(
                                title: MiotNaming.optionTitle(option.description),
                                selected: values[fan.id] == option.value
                            ) {
                                write(fan, value: option.value)
                            }
                        }
                    }
                }
                .controlGroup(controlsEnabled)
            } else if fan.property.sliderBounds != nil {
                SectionCard("风速", symbol: "fan.fill") {
                    sliderRow(fan)
                }
                .controlGroup(controlsEnabled)
            }
        }
    }

    @ViewBuilder
    private var swingSection: some View {
        let swings = [roles.verticalSwing, roles.horizontalSwing].compactMap { $0 }
        if !swings.isEmpty {
            SectionCard("摆风", symbol: "wind") {
                TileGrid {
                    ForEach(swings) { ref in
                        boolTile(ref)
                    }
                }
            }
            .controlGroup(controlsEnabled)
        }
    }

    @ViewBuilder
    private var toggleSection: some View {
        if !roles.toggles.isEmpty {
            SectionCard("开关", symbol: "switch.2") {
                TileGrid {
                    ForEach(roles.toggles) { ref in
                        boolTile(ref)
                    }
                }
            }
            .controlGroup(controlsEnabled)
        }
    }

    @ViewBuilder
    private var sliderSection: some View {
        if !roles.sliders.isEmpty {
            SectionCard("精细调节", symbol: "slider.horizontal.3") {
                VStack(spacing: 18) {
                    ForEach(roles.sliders) { ref in
                        sliderRow(ref)
                    }
                }
            }
            .controlGroup(controlsEnabled)
        }
    }

    @ViewBuilder
    private var chooserSection: some View {
        if !roles.choosers.isEmpty {
            SectionCard("选项", symbol: "list.bullet") {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(roles.choosers) { ref in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(title(of: ref))
                                .font(.subheadline)
                            WrapLayout(spacing: 10, lineSpacing: 10) {
                                ForEach(Array((ref.property.valueList ?? []).enumerated()), id: \.offset) { _, option in
                                    ChoiceChip(
                                        title: MiotNaming.optionTitle(option.description),
                                        selected: values[ref.id] == option.value
                                    ) {
                                        write(ref, value: option.value)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .controlGroup(controlsEnabled)
        }
    }

    @ViewBuilder
    private var readingSection: some View {
        let readings = displayReadings
        if !readings.isEmpty {
            SectionCard("实时数据", symbol: "waveform.path.ecg") {
                TileGrid {
                    ForEach(readings) { ref in
                        ReadoutTile(
                            title: title(of: ref),
                            symbol: ControlIcon.symbol(for: ref.name),
                            value: readoutText(ref)
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        if !roles.actions.isEmpty {
            SectionCard("快捷功能", symbol: "bolt.fill") {
                WrapLayout(spacing: 10, lineSpacing: 10) {
                    ForEach(roles.actions) { ref in
                        Button {
                            runAction(ref)
                        } label: {
                            Text(MiotNaming.title(type: ref.action.type, fallback: ref.action.description))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.moss)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .background(Color.moss.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - 瓦片与滑杆

    private func boolTile(_ ref: MiotPropertyRef) -> some View {
        let on = boolValue(values[ref.id])
        return ControlTile(
            title: title(of: ref),
            symbol: ControlIcon.symbol(for: ref.name),
            value: on ? "开" : "关",
            highlighted: on,
            enabled: controlsEnabled
        ) {
            write(ref, value: .bool(!on))
        }
    }

    @ViewBuilder
    private func sliderRow(_ ref: MiotPropertyRef, overriding: ClosedRange<Double>? = nil) -> some View {
        if let range = overriding ?? ref.property.sliderBounds {
            SliderRow(
                title: title(of: ref),
                symbol: ControlIcon.symbol(for: ref.name),
                text: draftText(ref, range: range),
                value: Binding(
                    get: { draft(ref, range: range) },
                    set: { drafts[ref.id] = $0 }
                ),
                range: range,
                step: ref.property.sliderStep,
                enabled: controlsEnabled,
                onCommit: { commit(ref) }
            )
        }
    }

    // MARK: - 读写

    private func load() async {
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            let spec = try await model.spec(for: device)
            roles = MiotRoles(spec: spec)
            values = try await readValues(spec: spec)
            didLoadRooms = false
            syncRooms()
        } catch {
            message = humanize(error)
        }
    }

    /// 下拉刷新和发完指令之后用，不弹加载态、也不清掉已经显示的错误。
    private func refresh() async {
        guard let spec = try? await model.spec(for: device),
              let next = try? await readValues(spec: spec) else { return }
        values = next
        syncRooms()
    }

    private func readValues(spec: MiotSpec) async throws -> [String: JSONScalar] {
        var refs: [(siid: Int, piid: Int)] = []
        for ref in spec.uiProperties where ref.property.visible && ref.property.canRead {
            refs.append((ref.service.iid, ref.property.iid))
        }
        let readings = try await model.readProperties(device: device, refs: refs)
        var next: [String: JSONScalar] = [:]
        for reading in readings where reading.code == 0 || reading.code == 1 {
            guard let value = reading.value else { continue }
            next["\(reading.siid).\(reading.piid)"] = value
        }
        return next
    }

    /// 房间列表取回来；第一次顺便把设备当前选中的房间带上，
    /// 之后每次刷新都保留用户在界面上的选择。
    private func syncRooms() {
        guard let vacuum = roles.vacuum else { return }
        let rooms = VacuumRooms.parse(
            roomInformation: vacuum.roomInformation.flatMap { values[$0.id] },
            roomName: vacuum.roomName.flatMap { values[$0.id] },
            roomIds: vacuum.roomIds.flatMap { values[$0.id] }
        )
        if rooms != vacuumRooms { vacuumRooms = rooms }
        if !didLoadRooms {
            selectedRooms = vacuum.roomIds.flatMap { VacuumRooms.selected(from: values[$0.id]) } ?? []
            didLoadRooms = true
        }
        if !vacuumRooms.isEmpty {
            selectedRooms.formIntersection(Set(vacuumRooms.map(\.id)))
        }
    }

    private func toggleRoom(_ room: VacuumRoom) {
        if selectedRooms.contains(room.id) {
            selectedRooms.remove(room.id)
        } else {
            selectedRooms.insert(room.id)
        }
    }

    /// 设备描述里认出来的属性，从任意位置取当前值。
    private func current(_ ref: MiotPropertyRef?) -> JSONScalar? {
        guard let ref else { return nil }
        return values[ref.id]
    }

    private func write(_ ref: MiotPropertyRef, value: JSONScalar) {
        let previous = values[ref.id]
        values[ref.id] = value
        Task {
            await run {
                try await model.setProperty(device: device, siid: ref.service.iid, piid: ref.property.iid, value: value)
            } rollback: {
                values[ref.id] = previous
            }
        }
    }

    private func commit(_ ref: MiotPropertyRef) {
        guard let range = ref.property.sliderBounds else { return }
        let number = draft(ref, range: range)
        drafts[ref.id] = nil
        let scalar: JSONScalar = ref.property.format == "float" ? .double(number) : .int(Int(number.rounded()))
        write(ref, value: scalar)
    }

    private func step(_ ref: MiotPropertyRef, by delta: Double) {
        guard let range = ref.property.sliderBounds else { return }
        drafts[ref.id] = min(max(draft(ref, range: range) + delta, range.lowerBound), range.upperBound)
        commit(ref)
    }

    private func togglePower() {
        guard let power = roles.power else { return }
        write(power, value: .bool(!isOn))
    }

    private func runAction(_ ref: MiotActionRef) {
        Task {
            await run {
                try await model.runAction(device: device, siid: ref.service.iid, aiid: ref.action.iid)
            }
            if message == nil { message = "已执行" }
        }
    }

    private func run(_ work: () async throws -> Void, rollback: (() -> Void)? = nil) async {
        do {
            try await work()
            message = nil
        } catch {
            rollback?()
            message = humanize(error)
        }
    }

    // MARK: - 展示

    private var accent: Color {
        if let mode = roles.mode, let value = values[mode.id],
           let option = mode.property.valueList?.first(where: { $0.value == value }) {
            return ControlPalette.accent(for: option.description)
        }
        return roles.target == nil ? Color.moss : ControlPalette.cool
    }

    private var statusLine: String {
        var parts: [String] = []
        if roles.power != nil {
            parts.append(isOn ? "已开启" : "已关闭")
        }
        if let mode = roles.mode, let value = values[mode.id],
           let option = mode.property.valueList?.first(where: { $0.value == value }) {
            parts.append(MiotNaming.optionTitle(option.description))
        }
        if let fan = roles.fan, let value = values[fan.id],
           let option = fan.property.valueList?.first(where: { $0.value == value }) {
            parts.append("风速" + MiotNaming.optionTitle(option.description))
        }
        return parts.isEmpty ? device.homeName : parts.joined(separator: " · ")
    }

    /// 还没读到开关状态时先别把界面锁死，不然一进页面全是灰的。
    private var isOn: Bool {
        guard let power = roles.power, let value = values[power.id] else { return true }
        return boolValue(value)
    }

    private var isPowerKnown: Bool {
        guard let power = roles.power else { return false }
        return values[power.id] != nil
    }

    private var dimmed: Bool { isPowerKnown && !isOn }

    /// 扫地机的 `on` 是「正在工作」不是电源，不能拿它当整页的开关；
    /// 关机、离线时两个页面都把控件变灰。
    private var controlsEnabled: Bool {
        if roles.vacuum != nil { return canControl }
        return !isLoading && device.online && isOn
    }

    private var canControl: Bool { !isLoading && device.online }

    // MARK: - 扫地机的展示与指令

    /// 最近清洁时间。设备上报的是秒级时间戳，0 表示还没扫过。
    private var lastCleanText: String? {
        guard let ref = roles.vacuum?.lastClean,
              let seconds = numeric(current(ref)), seconds > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    private func vacuumFaultText(_ vacuum: VacuumRoles) -> String? {
        guard let ref = vacuum.fault, let value = values[ref.id] else { return nil }
        let code = numeric(value) ?? 0
        guard code != 0 else { return nil }
        return "故障：" + vacuumOption(ref, value)
    }

    private func vacuumStateText(_ vacuum: VacuumRoles) -> String {
        if let ref = vacuum.sweepStatus, let value = values[ref.id], (numeric(value) ?? 0) != 0 {
            return vacuumOption(ref, value)
        }
        if let ref = vacuum.status, let value = values[ref.id], let code = numeric(value), code != 1 {
            return vacuumOption(ref, value)
        }
        if chargingStateCode(vacuum) == 1 { return "充电中" }
        if vacuumIsRunning(vacuum) { return "清扫中" }
        return "待机"
    }

    private func vacuumProgress(_ vacuum: VacuumRoles) -> Double? {
        guard let percent = numeric(current(vacuum.progress)) else { return nil }
        guard (numeric(current(vacuum.status)) ?? 0) == 2 || (numeric(current(vacuum.sweepStatus)) ?? 0) != 0 else {
            return nil
        }
        return min(max(percent, 0), 100)
    }

    private func vacuumIsRunning(_ vacuum: VacuumRoles) -> Bool {
        if let code = numeric(current(vacuum.sweepStatus)), code != 0 { return true }
        if let code = numeric(current(vacuum.status)), code == 2 { return true }
        return false
    }

    private func chargingStateCode(_ vacuum: VacuumRoles) -> Int? {
        numeric(current(vacuum.chargingState)).map { Int($0) }
    }

    private func batteryText(_ vacuum: VacuumRoles) -> String? {
        guard let level = numeric(current(vacuum.batteryLevel)) else { return nil }
        let percent = Int(level.rounded())
        switch chargingStateCode(vacuum) {
        case 1: return percent >= 100 ? "充电已满" : "充电中 \(percent)%"
        case 2, 3: return "未充电 \(percent)%"
        default: return "\(percent)%"
        }
    }

    private func batterySymbol(_ vacuum: VacuumRoles) -> String {
        if chargingStateCode(vacuum) == 1 { return "battery.100.bolt" }
        switch numeric(current(vacuum.batteryLevel)) ?? 0 {
        case ..<15: return "battery.0"
        case ..<50: return "battery.25"
        case ..<80: return "battery.50"
        default: return "battery.100"
        }
    }

    private func batteryTint(_ vacuum: VacuumRoles) -> Color {
        switch numeric(current(vacuum.batteryLevel)) ?? 100 {
        case ..<15: return Color.clay
        case ..<40: return .orange
        default: return Color.moss
        }
    }

    private var vacuumRoomHint: String {
        if vacuumRooms.isEmpty { return "没有读到房间" }
        if selectedRooms.isEmpty { return "未选房间，开始清洁会扫全屋" }
        return "已选 \(selectedRooms.count) 个房间，开始清洁只扫这些"
    }

    private func hasCleanSettings(_ vacuum: VacuumRoles) -> Bool {
        [vacuum.sweepMopType, vacuum.suction, vacuum.waterLevel, vacuum.sweepType]
            .contains { ref in
                guard let ref else { return false }
                return !(ref.property.valueList ?? []).isEmpty && ref.property.canWrite
            }
    }

    private func sweepModeText(_ vacuum: VacuumRoles) -> String {
        guard let ref = vacuum.sweepMopType, let value = values[ref.id] else {
            return hasCleanSettings(vacuum) ? "去设置" : "暂无可调项"
        }
        return vacuumOption(ref, value)
    }

    private func vacuumOption(_ ref: MiotPropertyRef, _ value: JSONScalar) -> String {
        if let option = ref.property.valueList?.first(where: { $0.value == value }) {
            return VacuumNaming.optionTitle(option.description, property: ref.name)
        }
        return value.displayText
    }

    private func sendVacuumAction(_ ref: MiotActionRef?, _ success: String) {
        guard let ref else {
            message = "这台扫地机没有公开这个指令"
            return
        }
        Task {
            await run {
                try await model.runAction(device: device, siid: ref.service.iid, aiid: ref.action.iid)
            }
            if message == nil { message = success }
            await refresh()
        }
    }

    /// 有声明的房间就用 `start-room-sweep` 带上房间号，否则退回整机开始。
    private func startVacuumCleaning(_ vacuum: VacuumRoles) {
        let ids = selectedRooms.sorted()
        let roomList = ids.map(String.init).joined(separator: ",")
        Task {
            await run {
                if !ids.isEmpty, let ref = vacuum.roomStart ?? vacuum.vacuumRoomStart {
                    try await model.runAction(
                        device: device,
                        siid: ref.service.iid,
                        aiid: ref.action.iid,
                        inputs: [.string(roomList)]
                    )
                } else if let ref = vacuum.start {
                    try await model.runAction(device: device, siid: ref.service.iid, aiid: ref.action.iid)
                } else if let ref = vacuum.on {
                    try await model.setProperty(device: device, siid: ref.service.iid, piid: ref.property.iid, value: .bool(true))
                } else {
                    throw XiaomiError.failed("这台扫地机没有公开开始清扫的指令")
                }
            }
            if message == nil {
                message = ids.isEmpty ? "已开始全屋清洁" : "已开始清扫选中的房间"
            }
            await refresh()
        }
    }

    /// 大卡片底下那两格读数。优先室温湿度；没有的话退到前两个能读到的数据，
    /// 免得净化器、传感器这类设备的卡片空着。
    private var heroReadouts: [(title: String, value: String)] {
        var items: [(title: String, value: String)] = []
        if let ambient = roles.ambient, values[ambient.id] != nil {
            items.append(("室温", readoutText(ambient)))
        }
        if let humidity = roles.humidity, values[humidity.id] != nil {
            items.append(("湿度", readoutText(humidity)))
        }
        if items.isEmpty {
            for ref in displayReadings where values[ref.id] != nil {
                items.append((title(of: ref), readoutText(ref)))
                if items.count == 2 { break }
            }
        }
        return Array(items.prefix(2))
    }

    private func title(of ref: MiotPropertyRef) -> String {
        MiotNaming.title(type: ref.property.type, fallback: ref.property.description)
    }

    private func boolValue(_ value: JSONScalar?) -> Bool {
        switch value {
        case let .bool(on): on
        case let .int(number): number != 0
        default: false
        }
    }

    private func numeric(_ value: JSONScalar?) -> Double? {
        switch value {
        case let .int(number): Double(number)
        case let .double(number): number
        case let .bool(on): on ? 1 : 0
        default: nil
        }
    }

    private func draft(_ ref: MiotPropertyRef, range: ClosedRange<Double>) -> Double {
        if let draft = drafts[ref.id] { return draft }
        if let number = numeric(values[ref.id]) {
            return min(max(number, range.lowerBound), range.upperBound)
        }
        return range.lowerBound
    }

    private func draftText(_ ref: MiotPropertyRef, range: ClosedRange<Double>) -> String {
        numberText(draft(ref, range: range)) + MiotNaming.unitSuffix(ref.property.unit)
    }

    private func dialText(_ ref: MiotPropertyRef, range: ClosedRange<Double>) -> String {
        let text = numberText(draft(ref, range: range))
        if ref.property.unit == "celsius" { return text + "°" }
        return text + MiotNaming.unitSuffix(ref.property.unit)
    }

    private func numberText(_ number: Double) -> String {
        number.rounded() == number ? String(Int(number)) : String(format: "%.1f", number)
    }

    private func readoutText(_ ref: MiotPropertyRef) -> String {
        guard let value = values[ref.id] else { return "—" }
        if let option = ref.property.valueList?.first(where: { $0.value == value }) {
            return MiotNaming.optionTitle(option.description)
        }
        return value.displayText + MiotNaming.unitSuffix(ref.property.unit)
    }

    /// 「实时数据」里真正值得看的那些读数。
    /// 整段 JSON 的内部字段（房间列表、参数表……）塞进格子里只会添乱，直接滤掉。
    private var displayReadings: [MiotPropertyRef] {
        roles.readings.filter { ref in
            guard let value = values[ref.id] else { return false }
            if case let .string(text) = value {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.count > 24 { return false }
                if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") { return false }
            }
            return true
        }
    }
}

/// 从设备描述里认出来的角色。
///
/// 米家的界面只关心这十来个常用功能（开关、模式、设定温度、室温湿度、风速、摆风），
/// 其余的按「开关 / 滑杆 / 选项 / 只读」分桶，一个都不丢。
/// 扫地机另走一套（`vacuum`），气候类的角色就不认了。
struct MiotRoles {
    var power: MiotPropertyRef?
    var mode: MiotPropertyRef?
    var target: MiotPropertyRef?
    var ambient: MiotPropertyRef?
    var humidity: MiotPropertyRef?
    var fan: MiotPropertyRef?
    var verticalSwing: MiotPropertyRef?
    var horizontalSwing: MiotPropertyRef?
    var brightness: MiotPropertyRef?
    var vacuum: VacuumRoles?
    var toggles: [MiotPropertyRef] = []
    var sliders: [MiotPropertyRef] = []
    var choosers: [MiotPropertyRef] = []
    var readings: [MiotPropertyRef] = []
    var actions: [MiotActionRef] = []

    /// 内部字段，读数格子里不显示。扫地机的描述里有几十个这类名字
    /// （房间列表、地图对象名、参数表……），值要么是整段 JSON，要么是个无意义的数字。
    private static let hiddenReadings: Set<String> = [
        "cmd", "flag", "points", "query-id", "action-result", "fault-ids", "notice",
        "common-params", "current-cleaning-config", "sweep-params", "map-ids", "map-obj-name",
        "trajectory-obj-name", "carpet-obj-name", "clean-record", "map-management", "map-3d-info",
        "map-upload-stop", "map-switch-method", "map-upload-stop-action-result", "backup-map-list",
        "restore-map-result", "map-complete-dialog", "exit-remote-dialog", "plugin-info-remind",
        "position-for-linkage", "water-check-list", "room-information", "room-name", "order-clean",
        "user-define-sweep-cfg", "user-define-sweep-id", "map-hidden-zone", "restricted-sweep-areas",
        "restricted-walls", "restricted-mop-areas", "zone-ids", "room-ids", "vacuum-room-ids",
        "sweep-ai-object", "sweep-furniture", "carpet-object", "furniture-for-automation",
        "vacuum-route", "user-define",
    ]

    init() {}

    init(spec: MiotSpec) {
        let props = spec.uiProperties

        func pick(
            _ candidates: [String],
            services: [String] = [],
            check: (MiotProperty) -> Bool = { _ in true }
        ) -> MiotPropertyRef? {
            for candidate in candidates {
                if let hit = props.first(where: { ref in
                    ref.name == candidate
                        && (services.isEmpty || services.contains(ref.serviceName))
                        && check(ref.property)
                }) {
                    return hit
                }
            }
            return nil
        }

        let climates = ["air-conditioner", "heater", "water-heater", "thermostat", "air-condition-outlet", "air-fresh"]

        // 扫地机走自己那套界面，气候类的角色（模式、设定温度、风速、摆风）就不认了，
        // 免得把「吸力档位」当成空调风速、把扫地机的 on 当成电源开关。
        vacuum = VacuumRoles(spec: spec)
        if vacuum == nil {
            power = pick(["on", "power", "switch"], check: { $0.format == "bool" && $0.canWrite })
            mode = pick(["mode"], check: { $0.canWrite && !($0.valueList ?? []).isEmpty })
            target = pick(
                ["target-temperature", "target-temp", "set-temperature", "temperature"],
                services: climates,
                check: { $0.canWrite && $0.sliderBounds != nil }
            )
            ambient = pick(["temperature"], services: ["environment"], check: { $0.canRead })
                ?? pick(["temperature"], check: { $0.canRead && $0.sliderBounds != nil && $0.canWrite == false })
            humidity = pick(["relative-humidity", "humidity"], check: { $0.canRead })
            fan = pick(
                ["fan-level", "fan-speed", "wind-speed", "speed-level"],
                check: { $0.canWrite && ($0.sliderBounds != nil || !($0.valueList ?? []).isEmpty) }
            )
            verticalSwing = pick(
                ["vertical-swing", "up-down-swing", "vertical-swing-included-angle"],
                check: { $0.canWrite && ($0.format == "bool" || !($0.valueList ?? []).isEmpty) }
            )
            horizontalSwing = pick(
                ["horizontal-swing", "left-right-swing", "horizontal-swing-included-angle"],
                check: { $0.canWrite && ($0.format == "bool" || !($0.valueList ?? []).isEmpty) }
            )
            brightness = pick(["brightness"], check: { $0.canWrite && $0.sliderBounds != nil })
        }

        var claimed = Set(
            [power, mode, target, ambient, humidity, fan, verticalSwing, horizontalSwing, brightness]
                .compactMap { $0?.id }
        )
        if let vacuumRoles = vacuum { claimed.formUnion(vacuumRoles.claimed) }
        let noisy = ["fault", "abnormal-condition"]

        for ref in props where ref.property.visible && !claimed.contains(ref.id) {
            let property = ref.property
            if property.canWrite, !noisy.contains(ref.name) {
                if property.format == "bool" {
                    toggles.append(ref)
                } else if !(property.valueList ?? []).isEmpty {
                    choosers.append(ref)
                } else if property.sliderBounds != nil {
                    sliders.append(ref)
                }
                continue
            }
            if property.canRead, !Self.hiddenReadings.contains(ref.name) {
                readings.append(ref)
            }
        }
        let claimedActions = vacuum?.claimedActions ?? []
        actions = spec.uiActions.filter { $0.action.canRunWithoutInput && !claimedActions.contains($0.id) }
    }
}
