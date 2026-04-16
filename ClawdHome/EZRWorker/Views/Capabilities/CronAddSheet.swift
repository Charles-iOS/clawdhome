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
    @State private var selectedScheduleMode: ScheduleMode = .daily
    @State private var selectedWeekdays = Set(Weekday.workdays)
    @State private var selectedDate = Date()
    @State private var selectedTime = Date.defaultCronTime
    @State private var intervalValue = "1"
    @State private var selectedIntervalUnit: IntervalUnit = .hours
    @State private var showingDatePopover = false
    @State private var showingTimePopover = false
    @State private var showingTemplatePicker = false
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
            syncDefaultsIfNeeded()
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        HStack(alignment: .top) {
            Text(L10n.k("cron.add.title", fallback: "创建任务"))
                .font(.system(size: 34, weight: .bold))

            Spacer()

            Button(L10n.k("cron.add.use_template", fallback: "使用模板")) {
                showingTemplatePicker = true
            }
                .buttonStyle(CronGhostButtonStyle())
                .popover(isPresented: $showingTemplatePicker, arrowEdge: .top) {
                    templatePickerContent
                }
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
                        VStack(alignment: .leading, spacing: 12) {
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

                            Text(payloadHint)
                                .font(.system(size: 15))
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    labeledBlock("指定会话") {
                        VStack(alignment: .leading, spacing: 12) {
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

                            Text(payloadHint)
                                .font(.system(size: 15))
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

    private var templatePickerContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("选择模板")
                .font(.system(size: 20, weight: .semibold))

            Text("从常用预设开始，系统会自动填充名称、提示词、目标和调度方式，你还可以继续修改。")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                ForEach(CronTemplate.presets) { template in
                    templateCard(template)
                }
            }
        }
        .padding(22)
        .frame(width: 620)
        .background(Color.white)
    }

    private func templateCard(_ template: CronTemplate) -> some View {
        Button {
            applyTemplate(template)
            showingTemplatePicker = false
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Text(template.icon)
                        .font(.system(size: 26))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(template.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)

                        Text(template.summary)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }

                Text(template.scheduleDescription)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 144, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
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
            return selectedAgentId == "main" ? "main" : "isolated"
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
        switch selectedDeliveryMode {
        case .agent:
            return selectedAgentId == "main" ? .systemEvent : .agentTurn
        case .session:
            return .agentTurn
        }
    }

    private var payloadHint: String {
        switch effectivePayloadMode {
        case .systemEvent:
            return "发送到数字员工时会自动创建主会话 systemEvent，并通过 agent 参数指定目标智能体。"
        case .agentTurn:
            if selectedDeliveryMode == .agent {
                return "非默认数字员工会自动创建 isolated 会话，并通过 agent 参数指定目标智能体。"
            }
            return "指定会话时会自动使用智能体消息，并继续沿用该会话上下文。"
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
            return selectedAgentId == "main"
                ? "默认智能体会使用主会话 systemEvent。"
                : "非默认智能体会自动切到 isolated 会话和 agentTurn。"
        case .session:
            return availableSessions.isEmpty
                ? "当前还没有可用会话，请先在会话页或聊天中产生会话。"
                : "从所有现有会话中选择一个；指定会话时会自动按智能体消息发送。"
        }
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

    private func applyTemplate(_ template: CronTemplate) {
        name = template.name
        message = template.message
        errorText = nil

        selectedDeliveryMode = template.deliveryMode
        switch template.deliveryMode {
        case .agent:
            selectedAgentId = resolvedAgentId(for: template)
        case .session:
            selectedSessionKey = availableSessions.first?.key
        }

        switch template.schedule {
        case let .daily(weekdays, hour, minute):
            selectedScheduleMode = .daily
            selectedWeekdays = Set(weekdays)
            selectedTime = resolvedTime(hour: hour, minute: minute)
        case let .once(offsetDays, hour, minute):
            selectedScheduleMode = .once
            selectedDate = Calendar.current.date(byAdding: .day, value: offsetDays, to: .now) ?? .now
            selectedTime = resolvedTime(hour: hour, minute: minute)
        case let .interval(value, unit):
            selectedScheduleMode = .interval
            intervalValue = String(value)
            selectedIntervalUnit = unit
        }

        normalizeSelectionAfterModeChange()
    }

    private func resolvedAgentId(for template: CronTemplate) -> String {
        switch template.agentPreference {
        case .main:
            if availableAgents.contains(where: { $0.id == "main" }) {
                return "main"
            }
            return availableAgents.first?.id ?? "main"
        case .nonMainPreferred:
            return availableAgents.first(where: { $0.id != "main" })?.id
                ?? availableAgents.first?.id
                ?? "main"
        }
    }

    private func resolvedTime(hour: Int, minute: Int) -> Date {
        Calendar.current.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: .now
        ) ?? .now
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
                channel: nil,
                to: nil,
                bestEffortDeliver: true
            )
        }

        let params = GatewayCronAddParams(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: nil,
            enabled: true,
            deleteAfterRun: nil,
            schedule: scheduleValue,
            agentId: selectedDeliveryMode == .agent ? selectedAgentId : nil,
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

private struct CronTemplate: Identifiable {
    enum AgentPreference {
        case main
        case nonMainPreferred
    }

    enum SchedulePreset {
        case daily(weekdays: [Weekday], hour: Int, minute: Int)
        case once(offsetDays: Int, hour: Int, minute: Int)
        case interval(value: Int, unit: IntervalUnit)
    }

    let id: String
    let icon: String
    let title: String
    let summary: String
    let name: String
    let message: String
    let deliveryMode: DeliveryMode
    let payloadMode: PayloadMode
    let agentPreference: AgentPreference
    let schedule: SchedulePreset

    var scheduleDescription: String {
        switch schedule {
        case let .daily(weekdays, hour, minute):
            if weekdays.count == Weekday.workdays.count && Set(weekdays) == Set(Weekday.workdays) {
                return "工作日 \(String(format: "%02d:%02d", hour, minute))"
            }
            if weekdays.count == 1, let day = weekdays.first {
                return "\(day.localizedLabel) \(String(format: "%02d:%02d", hour, minute))"
            }
            return "每天 \(String(format: "%02d:%02d", hour, minute))"
        case let .once(offsetDays, hour, minute):
            let dayText = offsetDays == 0 ? "今天" : (offsetDays == 1 ? "明天" : "\(offsetDays) 天后")
            return "\(dayText) \(String(format: "%02d:%02d", hour, minute))"
        case let .interval(value, unit):
            return "每 \(value) \(unit.title)"
        }
    }

    static let presets: [CronTemplate] = [
        CronTemplate(
            id: "workday-standup",
            icon: "☀️",
            title: "工作日站会总结",
            summary: "每天上班前自动整理昨天的进展、阻塞和待跟进事项。",
            name: "工作日站会总结",
            message: "请总结昨天的项目进展，按“已完成 / 进行中 / 风险与阻塞 / 今日建议”输出，方便我直接用于站会。",
            deliveryMode: .agent,
            payloadMode: .systemEvent,
            agentPreference: .main,
            schedule: .daily(weekdays: Weekday.workdays, hour: 9, minute: 30)
        ),
        CronTemplate(
            id: "end-of-day-brief",
            icon: "📝",
            title: "下班前日报草稿",
            summary: "在工作日傍晚生成一份日报草稿，适合收尾回顾和同步。",
            name: "下班前日报草稿",
            message: "请根据今天的上下文整理一份简洁日报，包含：今日完成、关键决策、未完成事项、明日计划。",
            deliveryMode: .agent,
            payloadMode: .systemEvent,
            agentPreference: .main,
            schedule: .daily(weekdays: Weekday.workdays, hour: 18, minute: 0)
        ),
        CronTemplate(
            id: "weekly-retro",
            icon: "📊",
            title: "周五复盘",
            summary: "每周固定输出本周回顾，包括亮点、问题和下周关注点。",
            name: "周五复盘",
            message: "请回顾本周工作，输出：本周亮点、重要决策、遗留问题、下周优先级建议，语气简洁直接。",
            deliveryMode: .agent,
            payloadMode: .systemEvent,
            agentPreference: .main,
            schedule: .daily(weekdays: [.friday], hour: 16, minute: 30)
        ),
        CronTemplate(
            id: "inbox-triage",
            icon: "📬",
            title: "定期任务巡检",
            summary: "按固定间隔提醒梳理当前待办、消息和需要推进的事情。",
            name: "定期任务巡检",
            message: "请检查最近需要我处理的事项，整理成一份按优先级排序的清单，并标出可以立即推进的下一步。",
            deliveryMode: .agent,
            payloadMode: .systemEvent,
            agentPreference: .main,
            schedule: .interval(value: 4, unit: .hours)
        ),
        CronTemplate(
            id: "morning-broadcast",
            icon: "📣",
            title: "晨间提醒广播",
            summary: "适合投递到外部渠道，自动生成一条简短晨间提醒。",
            name: "晨间提醒广播",
            message: "请生成一条简短的晨间提醒，包含一句鼓励、一条今日重点和一句行动建议，适合直接发送到聊天渠道。",
            deliveryMode: .agent,
            payloadMode: .agentTurn,
            agentPreference: .nonMainPreferred,
            schedule: .daily(weekdays: Weekday.allCases, hour: 8, minute: 30)
        ),
        CronTemplate(
            id: "tomorrow-follow-up",
            icon: "⏰",
            title: "明日一次性跟进",
            summary: "快速创建一个明天执行一次的提醒或跟进任务。",
            name: "明日一次性跟进",
            message: "请在任务触发时提醒我跟进当前最重要的一件待办，并附上一句简短行动建议。",
            deliveryMode: .agent,
            payloadMode: .systemEvent,
            agentPreference: .main,
            schedule: .once(offsetDays: 1, hour: 10, minute: 0)
        )
    ]
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

private extension Weekday {
    var localizedLabel: String {
        switch self {
        case .monday: return "周一"
        case .tuesday: return "周二"
        case .wednesday: return "周三"
        case .thursday: return "周四"
        case .friday: return "周五"
        case .saturday: return "周六"
        case .sunday: return "周日"
        }
    }
}
