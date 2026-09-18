import SwiftUI
import AppKit

// MARK: - Device detail (tabs)

struct DeviceDetailView: View {
    let device: RemoteDevice
    @EnvironmentObject var service: KDEConnectService
    @State private var tab: DeviceTab = .overview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LocalNetworkNotice(service: service)
                .padding(.bottom, 8)

            if device.paired {
                tabs
            } else {
                PairingWizardView(device: device)
            }
        }
        .padding()
        .navigationTitle(device.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    service.refreshAll(deviceId: device.id)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Ask the phone for its battery, notifications, messages and players")
                .disabled(!device.connected || !device.paired)
            }
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            OverviewTab(device: device)
                .tabItem { Label("Overview", systemImage: "info.circle") }
                .tag(DeviceTab.overview)
            NotificationsTab(device: device)
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(DeviceTab.notifications)
            SmsTab(device: device)
                .tabItem { Label("SMS", systemImage: "message") }
                .tag(DeviceTab.sms)
        }
        .onChange(of: service.requestedDetailTab) {
            guard let requested = service.requestedDetailTab else { return }
            tab = requested
            service.requestedDetailTab = nil
        }
    }
}

// MARK: - Pairing wizard

/// Shown in place of the tabs while a device is not paired.
///
/// Every control in the tabs is disabled until pairing succeeds, so showing
/// them only demonstrates a UI that cannot be used. This walks through the one
/// thing that is possible instead: getting the two devices to agree.
struct PairingWizardView: View {
    let device: RemoteDevice
    @EnvironmentObject var service: KDEConnectService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                connectStep
                pairStep
            }
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: device.deviceType == "tablet" ? "ipad" : "iphone")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Pair with \(device.name)")
                .font(.title2.weight(.semibold))
            Text("Notifications, messages and battery stay hidden until both devices agree to pair. The phone confirms it on its own screen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Steps

    private var connectStep: some View {
        step(number: 1, title: "Connect to the phone",
             state: device.connected ? .done : .current) {
            if device.connected {
                Text(verbatim: "Reachable at \(device.host):\(device.tcpPort).")
                    .foregroundStyle(.secondary)
            } else {
                Text("Open KDE Connect on the phone, on the same Wi-Fi, and bring up this Mac. It appears here as soon as the phone answers.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pairStep: some View {
        step(number: 2, title: "Confirm pairing", state: pairStepState) {
            pairStepContent
        }
    }

    private var pairStepState: WizardStepState {
        if device.pairRequestedByPeer || device.pairRequestedByUs { return .current }
        return device.connected ? .current : .pending
    }

    @ViewBuilder
    private var pairStepContent: some View {
        if device.pairRequestedByPeer {
            Text("Your phone asked to pair with this Mac. Compare the key on both screens, then accept here if they match.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            verificationKey
            HStack {
                Button("Accept") { service.acceptPairing(deviceId: device.id) }
                    .buttonStyle(.borderedProminent)
                Button("Decline") { service.declinePairing(deviceId: device.id) }
            }
        } else if device.pairRequestedByUs {
            Text("The request is on its way. Accept it on the phone — the key below should match the one it shows.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            verificationKey
        } else if device.connected {
            Text("Send a pairing request, then accept it on the phone. Both devices show the same verification key; if they differ, decline.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Request pairing") { service.requestPairing(deviceId: device.id) }
                .buttonStyle(.borderedProminent)
        } else {
            Text("Available once the phone is reachable.")
                .foregroundStyle(.secondary)
        }
    }

    /// The key both devices show while pairing, so a person can confirm they
    /// are pairing with the device in their hand and not an impostor. On a row
    /// of its own: mixed into the sentence it wrapped badly and could not be
    /// read out loud clearly, which defeats the point of comparing it.
    @ViewBuilder
    private var verificationKey: some View {
        if let key = service.verificationKey(deviceId: device.id) {
            HStack(spacing: 8) {
                Text("Verification key")
                Text(key)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 6))
            .help("Compare this with the key shown on the phone. If they differ, don't pair.")
        }
    }

    private enum WizardStepState {
        case pending, current, done

        var tint: Color {
            switch self {
            case .pending: return .secondary
            case .current: return .accentColor
            case .done: return .green
            }
        }
    }

    private func step<Content: View>(number: Int, title: String,
                                     state: WizardStepState,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(state.tint.opacity(0.18))
                    .frame(width: 26, height: 26)
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(state.tint)
                } else {
                    Text(verbatim: "\(number)")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(state.tint)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Overview: media, battery, ring, call, status

private struct OverviewTab: View {
    let device: RemoteDevice
    @EnvironmentObject var service: KDEConnectService
    @State private var selectedPlayer: String?

    private var players: [MediaPlayer] { service.mediaPlayers[device.id] ?? [] }

    private var activePlayer: MediaPlayer? {
        if let selectedPlayer, let match = players.first(where: { $0.name == selectedPlayer }) {
            return match
        }
        return players.first
    }

    var body: some View {
        Form {
            Section("Media") {
                mediaSection
            }

            Section("Battery") {
                BatteryRow(state: service.batteries[device.id] ?? BatteryState())
            }
            .disabled(!device.connected || !device.paired)

            Section("Ring phone") {
                Text(service.ringingDevices.contains(device.id)
                     ? "Ringing — make sure you hear it, then stop it here."
                     : "Makes your phone ring loudly, even on silent.")
                .font(.callout)
                .foregroundStyle(.secondary)
                HStack {
                    Button(service.ringingDevices.contains(device.id) ? "Stop ringing" : "Ring phone") {
                        service.toggleRing(deviceId: device.id)
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    Button("Send ping") { service.sendPing(deviceId: device.id) }
                }
            }
            .disabled(!device.connected || !device.paired)

            Section("Call") {
                Text("While the phone rings you can silence its ringer from here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Mute ringer") { service.muteCall(deviceId: device.id) }
                    .disabled(!device.connected || !device.paired)
            }

            Section("Status") {
                LabeledContent("Connection", value: device.connected ? "Connected (\(device.host):\(device.tcpPort))" : "Offline")
                LabeledContent("Pairing", value: device.paired ? "Paired" : "Not paired")
                if let call = service.lastCallEvent[device.id] {
                    LabeledContent("Phone", value: call)
                }
                if device.paired {
                    Button("Unpair", role: .destructive) { service.unpair(deviceId: device.id) }
                        .help(device.connected
                              ? "Forgets this phone on the Mac and asks the phone to forget the Mac."
                              : "Forgets this phone here. Do the same on the phone to pair again.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { service.requestPlayerList(deviceId: device.id) }
    }

    @ViewBuilder
    private var mediaSection: some View {
        if players.isEmpty {
            Text("No media players detected. Start playback on the phone, then refresh.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .disabled(!device.connected || !device.paired)
        } else {
            if players.count > 1 {
                Picker("Player", selection: Binding(
                    get: { activePlayer?.name ?? "" },
                    set: { selectedPlayer = $0 }
                )) {
                    ForEach(players) { Text($0.name).tag($0.name) }
                }
                .pickerStyle(.segmented)
            }
            if let player = activePlayer {
                MediaControlsView(device: device, player: player)
            }
        }
    }
}

private struct BatteryRow: View {
    let state: BatteryState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: state.symbolName)
                    .font(.title)
                    .foregroundStyle(state.charging ? .green : (state.low ? .red : .accentColor))
                Text(state.displayText).font(.title2).monospacedDigit()
                if state.charging { Text("charging").foregroundStyle(.secondary) }
                if state.low && !state.charging {
                    Label("low", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                Spacer()
                if let updated = state.updated {
                    Text("updated \(updated, style: .time)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Notifications

private struct NotificationsTab: View {
    let device: RemoteDevice
    @EnvironmentObject var service: KDEConnectService
    @State private var replies: [String: String] = [:]

    var items: [PhoneNotification] { service.notifications[device.id] ?? [] }

    var body: some View {
        VStack {
            HStack {
                Text("\(items.count) notifications")
                    .font(.headline)
                Spacer()
                Button("Remove all") { service.clearNotifications(deviceId: device.id) }
                    .font(.callout)
                    .disabled(items.isEmpty)
            }
            .padding(.horizontal, 16)
            NotificationPermissionNotice(service: service)
                .padding(.horizontal, 16)
                .padding(.top, 4)
            if items.isEmpty {
                Spacer()
                Text("No notifications yet.\nNew phone notifications appear here live; Refresh pulls the current list.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        if let icon = resolveIcon(item) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 32, height: 32)
                                .cornerRadius(7)
                        } else {
                            // Shown whenever there is no icon, which is not
                            // only a "still loading" state: Android offers no
                            // icon at all for some apps — work profiles, or
                            // ones it cannot resolve — and those rows had
                            // nothing at all.
                            //
                            // Drawn as a tile rather than a bare glyph, because
                            // that is what the phone sends for every app that
                            // does have an icon: a rounded square, filled. A
                            // lone symbol reads as a broken row beside them.
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.secondary.opacity(0.18))
                                .frame(width: 32, height: 32)
                                .overlay {
                                    Image(systemName: "questionmark")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.appName).font(.headline)
                                Spacer()
                                Text(item.time, style: .time).font(.caption).foregroundStyle(.secondary)
                            }
                            if !item.title.isEmpty { Text(item.title).font(.subheadline).bold() }
                            if !item.text.isEmpty { Text(item.text).font(.body) }
                            else if !item.ticker.isEmpty { Text(item.ticker).font(.body).foregroundStyle(.secondary) }

                            if let replyId = item.requestReplyId {
                                HStack {
                                    TextField("Reply…", text: Binding(
                                        get: { replies[replyId] ?? "" },
                                        set: { replies[replyId] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { sendReply(item: item) }
                                    Button("Send") { sendReply(item: item) }
                                        .disabled((replies[replyId] ?? "").isEmpty)
                                }
                            }
                        }
                        if item.isClearable {
                            Button {
                                service.dismissPhoneNotification(deviceId: device.id, notifId: item.notifId)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            .help("Dismiss on phone")
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .task(id: item.notifId) {
                        // Retry a missing icon off the render path. This never
                        // mutates state during view body evaluation.
                        await service.ensureIcon(for: item)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func sendReply(item: PhoneNotification) {
        guard let replyId = item.requestReplyId else { return }
        let text = (replies[replyId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        service.replyToNotification(deviceId: device.id, requestReplyId: replyId, message: text)
        replies[replyId] = ""
    }

    /// Load the icon for a notification: first check the model path, then
    /// fall back to a cache lookup by payload hash. This makes icons appear
    /// immediately even if the async model update hasn't run yet.
    ///
    /// IMPORTANT: this must stay side-effect free. Mutating `@Published`
    /// service state from inside a view body triggers "Publishing changes
    /// from within view updates", after which SwiftUI stops updating the
    /// list (the notifications tab appeared empty).
    private func resolveIcon(_ item: PhoneNotification) -> NSImage? {
        service.iconImage(for: item)
    }
}

// MARK: - SMS

private struct SmsTab: View {
    let device: RemoteDevice
    @EnvironmentObject var service: KDEConnectService
    @State private var selectedThread: UInt64?
    @State private var draft = ""
    @State private var newRecipient = ""

    var convos: [SmsConversation] { service.conversations[device.id] ?? [] }
    var active: SmsConversation? {
        convos.first { $0.threadId == selectedThread } ?? convos.first
    }

    var body: some View {
        HStack(spacing: 0) {
            // Conversation list
            VStack {
                HStack {
                    Text("Conversations").font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 8)
                if convos.isEmpty {
                    Text("No messages.\nReload to fetch SMS threads from the phone.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding()
                    Spacer()
                } else {
                    List(convos, selection: $selectedThread) { convo in
                        VStack(alignment: .leading) {
                            Text(convo.title).font(.body).lineLimit(1)
                            Text(convo.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .tag(convo.threadId as UInt64?)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(minWidth: 220, maxWidth: 300)

            Divider()

            // Messages + composer
            VStack {
                if let convo = active {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(convo.messages.sorted(by: { $0.date < $1.date })) { msg in
                                    MessageBubble(message: msg)
                                        .id(msg.id)
                                }
                            }
                            .padding()
                        }
                        .onChange(of: convo.messages.count) {
                            if let last = convo.messages.sorted(by: { $0.date < $1.date }).last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                        .onAppear {
                            service.requestConversation(deviceId: device.id, threadId: convo.threadId)
                        }
                    }
                    .padding(8)
                } else {
                    Text("Select a conversation")
                        .foregroundStyle(.secondary)
                    Spacer()
                }

            }
        }
        .disabled(!device.connected || !device.paired)
    }

    private func sendActive() {
        guard let convo = active else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        service.sendSMS(deviceId: device.id, addresses: convo.participants, message: text)
        draft = ""
    }

    private func sendNew() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipient = newRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !recipient.isEmpty else { return }
        service.sendSMS(deviceId: device.id, addresses: [recipient], message: text)
        draft = ""
    }
}

private struct MessageBubble: View {
    let message: SmsMessageItem

    var body: some View {
        HStack {
            if !message.incoming { Spacer() }
            VStack(alignment: .leading, spacing: 2) {
                if message.incoming, let from = message.addresses.first {
                    Text(from).font(.caption).foregroundStyle(.secondary)
                }
                Text(message.body).font(.body)
                Text(message.date, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(8)
            .background(message.incoming ? Color.gray.opacity(0.2) : Color.accentColor.opacity(0.2))
            .cornerRadius(10)
            if message.incoming { Spacer() }
        }
    }
}

private func sampleDevice() -> RemoteDevice {
    RemoteDevice(deviceId: "preview", name: "Preview Phone", deviceType: "phone",
                 host: "192.168.1.50", tcpPort: 1716,
                 connected: true, paired: true, protocolVersion: 8)
}

#Preview("Overview") {
    let svc = KDEConnectService.shared
    svc.batteries["preview"] = BatteryState(level: 74, charging: false, low: false, updated: Date())
    svc.mediaPlayers["preview"] = [mediaPreviewPlayer()]
    return DeviceDetailView(device: sampleDevice())
        .environmentObject(svc)
        .frame(width: 700, height: 820)
}

#Preview("Pairing") {
    let svc = KDEConnectService.shared
    return DeviceDetailView(device: RemoteDevice(deviceId: "preview", name: "Sample Phone",
                                                 deviceType: "phone", host: "192.168.1.50",
                                                 tcpPort: 1716, connected: true, paired: false,
                                                 protocolVersion: 8))
        .environmentObject(svc)
        .frame(width: 700, height: 820)
}

#Preview("Notifications") {
    let svc = KDEConnectService.shared
    svc.notifications["preview"] = [
        PhoneNotification(deviceId: "preview", notifId: "1", appName: "Example App",
                          title: "Notification title", text: "Notification body text.",
                          ticker: "", time: Date(), isClearable: true,
                          requestReplyId: "reply-1", actions: [],
                          iconFilePath: "/tmp/preview_notif_icon.png"),
        PhoneNotification(deviceId: "preview", notifId: "2", appName: "Second App",
                          title: "Another title", text: "More body text.", ticker: "",
                          time: Date(), isClearable: false,
                          requestReplyId: nil, actions: [], iconHash: "deadbeef"),
        // No icon hash at all, as a work profile app sends.
        PhoneNotification(deviceId: "preview", notifId: "3", appName: "Third App",
                          title: "No icon offered", text: "The phone sent no icon for this one.",
                          ticker: "", time: Date(), isClearable: false,
                          requestReplyId: nil, actions: []),
    ]
    return NotificationsTab(device: sampleDevice())
        .environmentObject(svc)
        .frame(width: 700, height: 500)
        .padding()
}


// MARK: - Media (MPRIS)

/// Transport, progress and volume for one player. Rendered inside the
/// Overview tab's Media section.
private struct MediaControlsView: View {
    let device: RemoteDevice
    let player: MediaPlayer
    @EnvironmentObject var service: KDEConnectService

    /// Local slider values, so dragging doesn't fight incoming updates.
    @State private var seekValue: Double = 0
    @State private var volumeValue: Double = 0
    @State private var isSeeking = false
    /// Set when a seek is sent; the dragged position is shown until the phone
    /// reports a new one.
    @State private var seekPending = false
    @State private var isSettingVolume = false

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                artwork(player)
                VStack(alignment: .leading, spacing: 4) {
                    Text(player.title.isEmpty ? "Unknown track" : player.title)
                        .font(.title3)
                        .bold()
                        .lineLimit(2)
                    if !player.artist.isEmpty {
                        Text(player.artist).font(.body).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !player.album.isEmpty {
                        Text(player.album).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(player.isPlaying ? "Playing" : "Paused")
                        .font(.callout)
                        .foregroundStyle(player.isPlaying ? Color.accentColor : .secondary)
                }
                Spacer()
            }

            transport(player)

            if player.lengthMs > 0 {
                // Drive the position from the display clock so the knob moves
                // every frame instead of in half-second steps. Capped at 30 Hz
                // to keep the redraw cheap, and paused when nothing is playing.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !player.isPlaying)) { context in
                    let position = displayedPosition(player, at: context.date)
                    VStack(spacing: 2) {
                        Slider(
                            value: Binding(
                                get: { isSeeking ? seekValue : Double(position) },
                                set: { seekValue = $0 }
                            ),
                            in: 0...Double(player.lengthMs)
                        ) { editing in
                            isSeeking = editing
                            if editing {
                                seekValue = Double(position)
                            } else {
                                // Hold the dragged value until the phone
                                // reports a new position, so it doesn't snap
                                // back first.
                                seekPending = true
                                service.setMediaPosition(deviceId: device.id, player: player.name,
                                                         positionMs: Int(seekValue))
                            }
                        }
                        .labelsHidden()
                        .disabled(!player.canSeek)
                        HStack {
                            Text(timeString(position))
                            Spacer()
                            Text(timeString(player.lengthMs))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $volumeValue, in: 0...100) { editing in
                    isSettingVolume = editing
                    if !editing {
                        service.setMediaVolume(deviceId: device.id, player: player.name,
                                               volume: Int(volumeValue))
                    }
                }
                .labelsHidden()
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }

            if let updated = player.updated {
                Text("Updated \(updated, style: .time)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // Track volume from the phone, except while being dragged.
        .onAppear { syncSliders(player) }
        .onChange(of: player.title) { syncSliders(player); seekPending = false }
        .onChange(of: player.volume) { if !isSettingVolume { volumeValue = Double(player.volume) } }
        // The phone acknowledged our seek: hand display back to its position.
        .onChange(of: player.positionMs) { seekPending = false }
    }

    /// Smoothly interpolated play position: advance from the last position the
    /// phone reported rather than waiting for the next packet, which can be
    /// seconds apart.
    private func displayedPosition(_ player: MediaPlayer, at date: Date) -> Int {
        if isSeeking || seekPending { return Int(seekValue) }
        guard player.isPlaying, let updated = player.updated else { return player.positionMs }
        let elapsed = date.timeIntervalSince(updated)
        let interpolated = player.positionMs + Int(elapsed * 1000)
        return max(0, min(player.lengthMs, interpolated))
    }

    private func transport(_ player: MediaPlayer) -> some View {
        HStack(spacing: 28) {
            Button {
                service.sendMediaAction(deviceId: device.id, player: player.name, action: "Previous")
            } label: {
                Image(systemName: "backward.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(!player.canGoPrevious)

            Button {
                service.sendMediaAction(deviceId: device.id, player: player.name, action: "PlayPause")
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
            }
            .buttonStyle(.plain)
            .disabled(!player.canPlay && !player.canPause)

            Button {
                service.sendMediaAction(deviceId: device.id, player: player.name, action: "Next")
            } label: {
                Image(systemName: "forward.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(!player.canGoNext)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func artwork(_ player: MediaPlayer) -> some View {
        Group {
            if let path = player.albumArtPath, let image = NSImage(contentsOfFile: path) {
                // Scale to fit rather than stretch: album art and YouTube
                // thumbnails are often not square.
                let size = Self.fittedSize(of: image, max: 110)
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
            } else {
                ZStack {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                    Image(systemName: "music.note")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 110, height: 110)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Largest size that fits `image` inside a `max`×`max` box, keeping its
    /// aspect ratio. Uses pixel dimensions so image DPI can't skew the result.
    private static func fittedSize(of image: NSImage, max: CGFloat) -> CGSize {
        let rep = image.representations.first
        let width = CGFloat(rep?.pixelsWide ?? Int(image.size.width))
        let height = CGFloat(rep?.pixelsHigh ?? Int(image.size.height))
        guard width > 0, height > 0 else { return CGSize(width: max, height: max) }
        let scale = min(max / width, max / height)
        return CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
    }

    private func syncSliders(_ player: MediaPlayer) {
        seekValue = Double(player.positionMs)
        volumeValue = Double(player.volume)
    }

    private func timeString(_ ms: Int) -> String {
        let total = max(0, ms) / 1000
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private func mediaPreviewPlayer() -> MediaPlayer {
    MediaPlayer(name: "Music Player", title: "Song Title",
                artist: "Artist Name", album: "Album Name",
                isPlaying: true, canPlay: true, canPause: true,
                canGoNext: true, canGoPrevious: true, canSeek: true,
                lengthMs: 214000, positionMs: 62000, volume: 65)
}

#Preview("Media") {
    MediaControlsView(device: sampleDevice(), player: mediaPreviewPlayer())
        .environmentObject(KDEConnectService.shared)
        .frame(width: 640, height: 340)
        .padding()
}
