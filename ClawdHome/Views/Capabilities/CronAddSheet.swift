// ClawdHome/Views/Capabilities/CronAddSheet.swift

import SwiftUI

struct CronAddSheet: View {
    @Environment(GatewayService.self) private var gateway
    @Environment(AgentStore.self) private var agentStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var message = ""
    @State private var selectedDeliveryMode: DeliveryMode = .agent
    @State private var selectedAgentId = "main"
    @State private var availableSessions: [SessionEntry] = []
    @State private var selectedSessionKey: String?
    @State private var selectedPayloadMode: PayloadMode = .systemEvent
    @State private var channel = ""
    @State private var recipient = ""
    @State private var selectedScheduleMode: ScheduleMode = .daily
    @State private var selectedWeekdays = Set(Weekday.workdays)
    @State private var selectedDate = Date()
    @State private var selectedTime = Date.defaultCronTime
    @State private var intervalValue = "1"
    @State private var selectedIntervalUnit: IntervalUnit = .hours
    @State private var showingDatePopover = false
    @State private var showingTimePopover = false
    @State private var configuredChannels: [ChannelType] = []
    @State private var isSaving = false
    @State private var errorText: String?

    private let mutedFill = Color(red: 0.95, green: 0.95, blue: 0.95)
    private let borderColor = Color.black.opacity(0.10)

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            formSection
            Divider()
            footerSection
        }
        .frame(width: 1080, height: 820)
        .background(
            Rectangle()
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.12), radius: 24, y: 10)
        )
        .overlay(
            Rectangle()
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
        .interactiveDismissDisabled(isSaving)
        .task {
            await loadAvailableSessions()
            await loadConfiguredChannels()
            syncDefaultsIfNeeded()
        }
        .onChange(of: selectedDeliveryMode) { _, newValue in
            if newValue == .agent, selectedAgentId == "main" {
                selectedPayloadMode = .systemEvent
            }
        }
        .onChange(of: selectedAgentId) { _, newValue in
            if newValue == "main" {
                selectedPayloadMode = .systemEvent
            }
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        HStack(alignment: .top) {
            Text(L10n.k("cron.add.title", fallback: "创建任务"))
                .font(.system(size: 34, weight: .bold))

            Spacer()

            Button(L10n.k("cron.add.use_template", fallback: "使用模板")) {}
                .buttonStyle(CronGhostButtonStyle())
                .disabled(true)
                .help(L10n.k("cron.add.template_unavailable", fallback: "模板功能即将上线"))
        }
        .padding(.horizontal, 56)
        .padding(.top, 42)
        .padding(.bottom, 28)
    }

    @ViewBuilder
    private var formSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                labeledBlock(L10n.k("cron.add.name", fallback: "名称")) {
                    TextField(L10n.k("cron.add.name_placeholder", fallback: "站会总结"), text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20))
                        .padding(.horizontal, 20)
                        .frame(height: 62)
                        .background(fieldBackground)
                }

                labeledBlock(L10n.k("cron.add.delivery", fallback: "发送到")) {
                    VStack(alignment: .leading, spacing: 12) {
                        deliveryModePicker
                        Text(deliveryHint)
                            .font(.system(size: 15))
                            .foregroundStyle(.tertiary)
                    }
                }

                if selectedDeliveryMode == .agent {
                    labeledBlock("数字员工") {
                        Menu {
                            ForEach(availableAgents) { agent in
                                Button(agent.name) {
                                    selectedAgentId = agent.id
                                }
                            }
                        } label: {
                            selectionMenuLabel(text: selectedAgentName, width: nil)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    labeledBlock("指定会话") {
                        Menu {
                            ForEach(availableSessions) { session in
                                Button(sessionPickerLabel(for: session)) {
                                    selectedSessionKey = session.key
                                }
                            }
                        } label: {
                            selectionMenuLabel(text: selectedSessionLabel, width: nil)
                        }
                        .buttonStyle(.plain)
                    }
                }

                labeledBlock("消息类型") {
                    VStack(alignment: .leading, spacing: 12) {
                        payloadModePicker
                        Text(payloadHint)
                            .font(.system(size: 15))
                            .foregroundStyle(.tertiary)
                    }
                }

                if effectivePayloadMode == .agentTurn {
                    labeledBlock("渠道与目标") {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 16) {
                                if configuredChannels.isEmpty {
                                    inlineField(
                                        title: "渠道",
                                        placeholder: "例如：telegram / discord / weixin",
                                        text: $channel
                                    )
                                } else {
                                    inlineMenuField(
                                        title: "渠道",
                                        text: selectedChannelLabel
                                    ) {
                                        ForEach(configuredChannels) { channelType in
                                            Button(channelType.displayName) {
                                                channel = channelType.rawValue
                                            }
                                        }
                                    }
                                }
                                inlineField(
                                    title: "目标",
                                    placeholder: "例如：群组 ID、用户 ID 或频道 ID",
                                    text: $recipient
                                )
                            }
                            Text("留空则由 Gateway 使用默认投递设置；填写后会作为 agentTurn 的 channel/to 参数发送。")
                                .font(.system(size: 14))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                labeledBlock(L10n.k("cron.add.prompt", fallback: "提示词")) {
                    TextEditor(text: $message)
                        .font(.system(size: 18))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .frame(minHeight: 164)
                        .background(fieldBackground)
                        .overlay(alignment: .topLeading) {
                            if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(promptPlaceholder)
                                    .font(.system(size: 18))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 22)
                                    .padding(.vertical, 22)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                labeledBlock(L10n.k("cron.add.schedule_section", fallback: "调度")) {
                    VStack(alignment: .leading, spacing: 16) {
                        scheduleModePicker

                        HStack(alignment: .center, spacing: 18) {
                            if selectedScheduleMode == .once {
                                dateField
                                timeField
                            } else if selectedScheduleMode == .interval {
                                intervalValueField
                                intervalUnitPicker
                            } else {
                                timeField
                            }

                            if selectedScheduleMode == .daily {
                                weekdaySelector
                            } else {
                                Text(scheduleHintText)
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let errorText, !errorText.isEmpty {
                    Text(errorText)
                        .font(.system(size: 14))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 34)
        }
    }

    @ViewBuilder
    private var footerSection: some View {
        HStack {
            Button(L10n.k("common.cancel", fallback: "取消")) {
                dismiss()
            }
            .buttonStyle(.plain)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.secondary)
            .disabled(isSaving)

            Spacer()

            Button {
                Task { await create() }
            } label: {
                if isSaving {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 108, height: 54)
                } else {
                    Text(L10n.k("common.create", fallback: "创建"))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 108, height: 54)
                }
            }
            .buttonStyle(.plain)
            .background(Capsule().fill(Color.black))
            .disabled(!canCreate || isSaving)
            .opacity((!canCreate || isSaving) ? 0.55 : 1)
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 26)
    }

    private var deliveryModePicker: some View {
        HStack(spacing: 0) {
            ForEach(DeliveryMode.allCases) { option in
                let isSelected = option == selectedDeliveryMode
                Button {
                    selectedDeliveryMode = option
                } label: {
                    Text(option.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(isSelected ? Color.white : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(isSelected ? borderColor : .clear, lineWidth: 1)
                                )
                                .shadow(
                                    color: isSelected ? Color.black.opacity(0.08) : Color.clear,
                                    radius: 10,
                                    y: 2
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(mutedFill)
        )
    }

    private var payloadModePicker: some View {
        HStack(spacing: 0) {
            ForEach(PayloadMode.allCases) { mode in
                let isSelected = mode == effectivePayloadMode
                Button {
                    guard !isMainAgentTarget || mode == .systemEvent else { return }
                    selectedPayloadMode = mode
                } label: {
                    Text(mode.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(isSelected ? Color.white : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(isSelected ? borderColor : .clear, lineWidth: 1)
                                )
                                .shadow(
                                    color: isSelected ? Color.black.opacity(0.06) : Color.clear,
                                    radius: 8,
                                    y: 2
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(isMainAgentTarget && mode == .agentTurn)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(mutedFill)
        )
    }

    private func inlineField(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .padding(.horizontal, 18)
                .frame(height: 56)
                .background(fieldBackground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inlineMenuField<MenuContent: View>(
        title: String,
        text: String,
        @ViewBuilder content: () -> MenuContent
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Menu {
                content()
            } label: {
                selectionMenuLabel(text: text, width: nil)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scheduleModePicker: some View {
        HStack(spacing: 24) {
            ForEach(ScheduleMode.allCases) { mode in
                Button {
                    selectedScheduleMode = mode
                    normalizeSelectionAfterModeChange()
                } label: {
                    Text(mode.title)
                        .font(.system(size: 18, weight: selectedScheduleMode == mode ? .semibold : .medium))
                        .foregroundStyle(selectedScheduleMode == mode ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var timeField: some View {
        customPickerField(
            width: 180,
            icon: "clock",
            text: timeDisplayText
        )
        .onTapGesture { showingTimePopover = true }
        .popover(isPresented: $showingTimePopover, arrowEdge: .bottom) {
            timePopoverContent
        }
    }

    private var dateField: some View {
        customPickerField(
            width: 220,
            icon: "calendar",
            text: dateDisplayText
        )
        .onTapGesture { showingDatePopover = true }
        .popover(isPresented: $showingDatePopover, arrowEdge: .bottom) {
            datePopoverContent
        }
    }

    private var weekdaySelector: some View {
        HStack(spacing: 12) {
            ForEach(Weekday.allCases) { day in
                let isSelected = selectedWeekdays.contains(day)
                Button {
                    toggleWeekday(day)
                } label: {
                    Text(day.shortLabel)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                        .frame(width: 48, height: 48)
                        .background(
                            Circle()
                                .fill(isSelected ? Color.black : Color.clear)
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.black.opacity(isSelected ? 0 : 0.12), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var intervalValueField: some View {
        TextField("1", text: $intervalValue)
            .textFieldStyle(.plain)
            .font(.system(size: 20))
            .padding(.horizontal, 20)
            .frame(width: 180, height: 58)
            .background(fieldBackground)
    }

    private var intervalUnitPicker: some View {
        Menu {
            ForEach(IntervalUnit.allCases) { unit in
                Button(unit.title) {
                    selectedIntervalUnit = unit
                }
            }
        } label: {
            selectionMenuLabel(text: selectedIntervalUnit.title, width: 180)
        }
        .buttonStyle(.plain)
    }

    private func customPickerField(
        width: CGFloat,
        icon: String,
        text: String
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.58))

            Text(text)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            Image(systemName: "chevron.down")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.30))
        }
        .padding(.horizontal, 20)
        .frame(width: width, height: 62)
        .background(fieldBackground)
    }

    private var datePopoverContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择日期")
                .font(.system(size: 18, weight: .semibold))

            DatePicker(
                "",
                selection: $selectedDate,
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.graphical)

            HStack {
                Spacer()
                Button("完成") {
                    showingDatePopover = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
            }
        }
        .padding(20)
        .frame(width: 300)
        .background(Color.white)
    }

    private var timePopoverContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择时间")
                .font(.system(size: 18, weight: .semibold))

            HStack(spacing: 12) {
                Picker("小时", selection: hourBinding) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(String(format: "%02d", hour)).tag(hour)
                    }
                }
                .labelsHidden()
                .frame(width: 92)

                Text(":")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)

                Picker("分钟", selection: minuteBinding) {
                    ForEach(0..<60, id: \.self) { minute in
                        Text(String(format: "%02d", minute)).tag(minute)
                    }
                }
                .labelsHidden()
                .frame(width: 92)
            }

            HStack {
                Spacer()
                Button("完成") {
                    showingTimePopover = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
            }
        }
        .padding(20)
        .frame(width: 280)
        .background(Color.white)
    }

    private func selectionMenuLabel(text: String, width: CGFloat?) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 20))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 12)

            Image(systemName: "chevron.down")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.30))
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .frame(width: width, height: 62)
        .background(fieldBackground)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(borderColor, lineWidth: 1.2)
            )
    }

    private var dateDisplayText: String {
        selectedDate.formatted(.dateTime.year().month().day())
    }

    private var timeDisplayText: String {
        selectedTime.formatted(date: .omitted, time: .shortened)
    }

    private var hourBinding: Binding<Int> {
        Binding(
            get: { Calendar.current.component(.hour, from: selectedTime) },
            set: { newHour in
                let minute = Calendar.current.component(.minute, from: selectedTime)
                selectedTime = Calendar.current.date(
                    bySettingHour: newHour,
                    minute: minute,
                    second: 0,
                    of: selectedTime
                ) ?? selectedTime
            }
        )
    }

    private var minuteBinding: Binding<Int> {
        Binding(
            get: { Calendar.current.component(.minute, from: selectedTime) },
            set: { newMinute in
                let hour = Calendar.current.component(.hour, from: selectedTime)
                selectedTime = Calendar.current.date(
                    bySettingHour: hour,
                    minute: newMinute,
                    second: 0,
                    of: selectedTime
                ) ?? selectedTime
            }
        )
    }

    private var canCreate: Bool {
        let hasCoreFields =
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let targetOK = selectedDeliveryMode == .agent
            ? !selectedAgentId.isEmpty
            : selectedSessionKey != nil
        let scheduleOK = selectedScheduleMode == .interval ? intervalMilliseconds != nil : true
        return hasCoreFields && targetOK && scheduleOK
    }

    private var normalizedSessionTarget: String {
        switch selectedDeliveryMode {
        case .agent:
            return selectedAgentId
        case .session:
            guard
                let selectedSessionKey,
                let session = availableSessions.first(where: { $0.key == selectedSessionKey })
            else { return "" }
            let rawId = session.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = (rawId?.isEmpty == false) ? rawId! : session.key
            return resolved.hasPrefix("session:") ? resolved : "session:\(resolved)"
        }
    }

    private var effectivePayloadMode: PayloadMode {
        isMainAgentTarget ? .systemEvent : selectedPayloadMode
    }

    private var payloadHint: String {
        switch effectivePayloadMode {
        case .systemEvent:
            if isMainAgentTarget {
                return "主数字员工任务当前只能使用系统事件类型。"
            }
            return "系统事件会把提示词直接作为文本事件投递到目标会话。"
        case .agentTurn:
            return "智能体消息会按 agentTurn 创建任务，可额外指定 channel 和 to。"
        }
    }

    private var promptPlaceholder: String {
        switch effectivePayloadMode {
        case .systemEvent:
            return "总结昨天的 Git 活动以供站会使用。"
        case .agentTurn:
            return "请在目标渠道里发送一条早安提醒，并附上今日待办摘要。"
        }
    }

    private var deliveryHint: String {
        switch selectedDeliveryMode {
        case .agent:
            return "从已配置的数字员工里选择一个作为任务目标。主数字员工当前只支持系统事件。"
        case .session:
            return availableSessions.isEmpty
                ? "当前还没有可用会话，请先在会话页或聊天中产生会话。"
                : "从所有现有会话中选择一个，任务会持续发送到该会话。"
        }
    }

    private var selectedChannelLabel: String {
        guard !channel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "选择渠道"
        }
        return ChannelType(rawValue: channel)?.displayName ?? channel
    }

    private var availableAgents: [Agent] {
        let agents = agentStore.agents
        if agents.isEmpty { return [Agent(id: "main", name: "Accio", emoji: "🤖", description: "", category: .strategy)] }
        return agents.sorted { lhs, rhs in
            if lhs.id == "main" { return true }
            if rhs.id == "main" { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var isMainAgentTarget: Bool {
        selectedDeliveryMode == .agent && selectedAgentId == "main"
    }

    private var selectedAgentName: String {
        availableAgents.first(where: { $0.id == selectedAgentId })?.name ?? "选择数字员工"
    }

    private var selectedSessionLabel: String {
        guard
            let selectedSessionKey,
            let session = availableSessions.first(where: { $0.key == selectedSessionKey })
        else { return "选择会话" }
        return sessionPickerLabel(for: session)
    }

    private func sessionPickerLabel(for session: SessionEntry) -> String {
        let owner = sessionOwnerLabel(for: session)
        let title = session.displayName

        if title == owner {
            return "\(owner) · \(sessionKeyTail(for: session))"
        }
        return "\(owner) · \(title)"
    }

    private func sessionOwnerLabel(for session: SessionEntry) -> String {
        let parts = session.key.split(separator: ":").map(String.init)
        guard parts.count >= 2, parts[0] == "agent" else {
            return "未知数字员工"
        }

        let agentId = parts[1]
        if let agent = availableAgents.first(where: { $0.id == agentId }) {
            return agent.emoji.isEmpty ? agent.name : "\(agent.emoji) \(agent.name)"
        }
        return agentId
    }

    private func sessionKeyTail(for session: SessionEntry) -> String {
        let parts = session.key.split(separator: ":").map(String.init)
        guard parts.count > 2 else { return session.key }
        return parts.dropFirst(2).joined(separator: ":")
    }

    private var scheduleHintText: String {
        switch selectedScheduleMode {
        case .once:
            return "单次任务会在选定日期和时间执行一次。"
        case .daily:
            return ""
        case .interval:
            return "按固定间隔重复执行，创建后会立即进入间隔调度。"
        }
    }

    private func labeledBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            content()
        }
    }

    private func toggleWeekday(_ day: Weekday) {
        if selectedWeekdays.contains(day) {
            if selectedWeekdays.count > 1 {
                selectedWeekdays.remove(day)
            }
        } else {
            selectedWeekdays.insert(day)
        }
    }

    private func normalizeSelectionAfterModeChange() {
        if selectedScheduleMode == .daily, selectedWeekdays.isEmpty {
            selectedWeekdays = Set(Weekday.workdays)
        }
        if selectedScheduleMode == .interval,
           intervalValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            intervalValue = "1"
        }
    }

    private func syncDefaultsIfNeeded() {
        if availableAgents.contains(where: { $0.id == selectedAgentId }) == false,
           let firstAgent = availableAgents.first {
            selectedAgentId = firstAgent.id
        }
        if selectedSessionKey == nil {
            selectedSessionKey = availableSessions.first?.key
        }
    }

    private func loadAvailableSessions() async {
        do {
            let payload = try await gateway.request(
                method: "sessions.list",
                params: ["limit": 200, "includeDerivedTitles": true, "includeLastMessage": false]
            )
            let items = payload?["sessions"] as? [[String: Any]] ?? []
            availableSessions = items.compactMap(SessionEntry.from).sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            availableSessions = []
        }
    }

    private func loadConfiguredChannels() async {
        do {
            let (config, _) = try await gateway.configGetFull()
            let channelsDict = config["channels"] as? [String: Any] ?? [:]

            configuredChannels = ChannelType.enabledCases.filter { channelType in
                guard let channelConfig = channelsDict[channelType.rawValue] as? [String: Any] else {
                    return false
                }
                return channelType.configFields.contains { field in
                    let value = channelConfig[field.id] as? String
                    return value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                }
            }

            if channel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let first = configuredChannels.first {
                channel = first.rawValue
            }
        } catch {
            configuredChannels = []
        }
    }

    private func create() async {
        errorText = nil
        isSaving = true
        defer { isSaving = false }

        let payload: GatewayCronPayload
        switch effectivePayloadMode {
        case .systemEvent:
            payload = .systemEvent(text: message.trimmingCharacters(in: .whitespacesAndNewlines))
        case .agentTurn:
            payload = .agentTurn(
                message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                thinking: nil,
                timeoutSeconds: nil,
                deliver: true,
                channel: normalizedOptional(channel),
                to: normalizedOptional(recipient),
                bestEffortDeliver: true
            )
        }

        let params = GatewayCronAddParams(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: nil,
            enabled: true,
            deleteAfterRun: nil,
            schedule: scheduleValue,
            sessionTarget: normalizedSessionTarget,
            wakeMode: "now",
            payload: payload
        )

        do {
            try await gateway.cronStore.add(params)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func normalizedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var cronExpression: String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: selectedTime)
        let minute = components.minute ?? 0
        let hour = components.hour ?? 9

        switch selectedScheduleMode {
        case .daily:
            let weekdays = selectedWeekdays.sorted(by: { $0.rawValue < $1.rawValue })
            if weekdays.count == Weekday.allCases.count {
                return "\(minute) \(hour) * * *"
            }
            let weekdayValue = weekdays.map(\.cronValue).joined(separator: ",")
            return "\(minute) \(hour) * * \(weekdayValue)"
        case .once, .interval:
            return "\(minute) \(hour) * * *"
        }
    }

    private var intervalMilliseconds: Int? {
        guard let value = Int(intervalValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0
        else { return nil }
        return value * selectedIntervalUnit.multiplierMs
    }

    private var scheduleValue: GatewayCronSchedule {
        switch selectedScheduleMode {
        case .once:
            let calendar = Calendar.current
            let dateComponents = calendar.dateComponents([.year, .month, .day], from: selectedDate)
            let timeComponents = calendar.dateComponents([.hour, .minute], from: selectedTime)
            let merged = DateComponents(
                year: dateComponents.year,
                month: dateComponents.month,
                day: dateComponents.day,
                hour: timeComponents.hour,
                minute: timeComponents.minute,
                second: 0
            )
            let resolved = calendar.date(from: merged) ?? selectedDate
            return .at(at: GatewayCronSchedule.formatIsoDate(resolved))
        case .daily:
            return .cron(expr: cronExpression, tz: nil)
        case .interval:
            return .every(everyMs: intervalMilliseconds ?? IntervalUnit.hours.multiplierMs, anchorMs: nil)
        }
    }
}

private enum DeliveryMode: String, CaseIterable, Identifiable {
    case agent
    case session

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agent: return "数字员工"
        case .session: return "指定会话"
        }
    }
}

private enum PayloadMode: String, CaseIterable, Identifiable {
    case systemEvent
    case agentTurn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemEvent: return "系统事件"
        case .agentTurn: return "智能体消息"
        }
    }
}

private enum ScheduleMode: String, CaseIterable, Identifiable {
    case once
    case daily
    case interval

    var id: String { rawValue }

    var title: String {
        switch self {
        case .once: return "单次"
        case .daily: return "每天"
        case .interval: return "间隔"
        }
    }
}

private enum IntervalUnit: String, CaseIterable, Identifiable {
    case minutes
    case hours
    case days

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minutes: return "分钟"
        case .hours: return "小时"
        case .days: return "天"
        }
    }

    var multiplierMs: Int {
        switch self {
        case .minutes: return 60 * 1000
        case .hours: return 60 * 60 * 1000
        case .days: return 24 * 60 * 60 * 1000
        }
    }
}

private enum Weekday: Int, CaseIterable, Identifiable {
    case monday = 1
    case tuesday = 2
    case wednesday = 3
    case thursday = 4
    case friday = 5
    case saturday = 6
    case sunday = 7

    static let workdays: [Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday]

    var id: Int { rawValue }

    var shortLabel: String {
        switch self {
        case .monday: return "Mo"
        case .tuesday: return "Tu"
        case .wednesday: return "We"
        case .thursday: return "Th"
        case .friday: return "Fr"
        case .saturday: return "Sa"
        case .sunday: return "Su"
        }
    }

    var cronValue: String {
        switch self {
        case .sunday: return "0"
        default: return "\(rawValue)"
        }
    }
}

private struct CronGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 22)
            .frame(height: 50)
            .background(
                Capsule()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(
                        Capsule()
                            .stroke(Color.black.opacity(0.10), lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

private extension Date {
    static var defaultCronTime: Date {
        Calendar.current.date(
            bySettingHour: 9,
            minute: 0,
            second: 0,
            of: .now
        ) ?? .now
    }
}
