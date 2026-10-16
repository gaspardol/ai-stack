import AVFoundation
import EventKit
import ServiceManagement
import SwiftUI
import UserNotifications

struct SetupView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var claudeOK: Bool?
    @State private var claudeSummary = "Checking…"
    @State private var testResult: String?
    @State private var testing = false
    @State private var axTrusted = AX.isTrusted
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var systemAudioRequested = UserDefaults.standard.bool(forKey: "systemAudio.requested")
    @State private var calendarStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var modelInstalled: Bool?
    @State private var downloadingModel = false
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AI Stack").font(.title.weight(.bold))
                        Text("Writing assistant + meeting notes, powered by your Claude subscription.")
                            .foregroundStyle(.secondary)
                    }
                }

                group("Claude") {
                    row(icon: "brain", title: "Claude subscription",
                        detail: claudeSummary + (testResult.map { "\n\($0)" } ?? ""),
                        ok: claudeOK) {
                        Button(testing ? "Testing…" : "Test") { test() }.disabled(testing)
                    }
                }

                group("Writing assistant") {
                    row(icon: "character.cursor.ibeam", title: "Accessibility",
                        detail: "Lets AI Stack read the text field you're typing in and draw underlines over it.",
                        ok: axTrusted) {
                        if !axTrusted {
                            Button("Grant…") {
                                AX.requestTrust()
                                AX.openAccessibilitySettings()
                            }
                        }
                    }
                }

                group("Meeting notes") {
                    row(icon: "mic", title: "Microphone", detail: "Transcribes your side of calls (on-device).",
                        ok: micStatus == .authorized ? true : (micStatus == .notDetermined ? nil : false)) {
                        if micStatus == .notDetermined {
                            Button("Allow") {
                                AVCaptureDevice.requestAccess(for: .audio) { _ in
                                    DispatchQueue.main.async { micStatus = AVCaptureDevice.authorizationStatus(for: .audio) }
                                }
                            }
                        } else if micStatus != .authorized {
                            Button("Open Settings") { openPrivacy("Privacy_Microphone") }
                        }
                    }
                    row(icon: "speaker.wave.2", title: "Call audio",
                        detail: "Transcribes the other participants by capturing what your Mac plays. Click Allow, then accept the system prompt (or enable AI Stack under Screen & System Audio Recording → System Audio Recording Only).",
                        ok: systemAudioRequested ? true : nil) {
                        HStack {
                            Button("Allow") { requestSystemAudio() }
                            Button("Settings") { openPrivacy("Privacy_AudioCapture") }
                        }
                    }
                    row(icon: "waveform", title: "Speech model — \(AppSettings.languageName(settings.notesLanguage))",
                        detail: "On-device transcription model for your call language (change it in the menu bar).",
                        ok: modelInstalled) {
                        if modelInstalled == false {
                            Button(downloadingModel ? "Downloading…" : "Download") { downloadModel() }.disabled(downloadingModel)
                        }
                    }
                    row(icon: "calendar", title: "Calendar (optional)",
                        detail: "Names meetings after your calendar events and lists attendees.",
                        ok: calendarStatus == .fullAccess ? true : nil) {
                        if calendarStatus == .notDetermined {
                            Button("Allow") { Task { _ = await CalendarHelper.shared.requestAccess(); refresh() } }
                        } else if calendarStatus != .fullAccess {
                            Button("Open Settings") { openPrivacy("Privacy_Calendars") }
                        }
                    }
                    row(icon: "bell", title: "Notifications",
                        detail: "Tells you when note-taking starts and when notes are ready.",
                        ok: notificationStatus == .authorized ? true : (notificationStatus == .notDetermined ? nil : false)) {
                        if notificationStatus == .notDetermined {
                            Button("Allow") { Task { _ = await Notifier.requestPermission(); refresh() } }
                        }
                    }
                }

                group("Always on") {
                    row(icon: "power", title: "Open at login", detail: "Keeps AI Stack running in the menu bar.", ok: loginEnabled) {
                        Toggle("", isOn: Binding(get: { loginEnabled }, set: { value in
                            do {
                                if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            } catch { Log.error("Login item: \(error.localizedDescription)", "app") }
                            loginEnabled = SMAppService.mainApp.status == .enabled
                        }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }

                HStack {
                    Text("AI Stack lives in the menu bar (✦). Everything AI runs through your Claude login; audio never leaves your Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") {
                        settings.onboardingDone = true
                        NSApp.keyWindow?.close()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 600)
        .onAppear { refresh(); checkClaude() }
        .onReceive(timer) { _ in refresh() }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        }
    }

    private func row<Action: View>(icon: String, title: String, detail: String, ok: Bool?, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    switch ok {
                    case .some(true): Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .some(false): Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    case .none: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                    }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action()
        }
        .padding(12)
    }

    private func refresh() {
        axTrusted = AX.isTrusted
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
        systemAudioRequested = UserDefaults.standard.bool(forKey: "systemAudio.requested")
        loginEnabled = SMAppService.mainApp.status == .enabled
        Task {
            notificationStatus = await Notifier.authorizationStatus()
            if !downloadingModel { modelInstalled = await LiveTranscriber.isModelInstalled(settings.notesLanguage) }
        }
    }

    private func checkClaude() {
        Task {
            let status = await ClaudeCLI.shared.authStatus()
            claudeOK = status.ok
            claudeSummary = status.ok ? "Connected: \(status.summary)" : status.summary
        }
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            let started = Date()
            do {
                let reply = try await ClaudeCLI.shared.complete("Reply with exactly: OK",
                                                                config: ClaudeRequestConfig(model: "haiku", systemPrompt: "You are a connectivity test.", effort: "low", disableThinking: true),
                                                                timeout: 60)
                testResult = String(format: "Test reply “%@” in %.1fs", reply.trimmingCharacters(in: .whitespacesAndNewlines), Date().timeIntervalSince(started))
                claudeOK = true
            } catch {
                testResult = "Test failed: \(error.localizedDescription)"
                claudeOK = false
            }
            testing = false
        }
    }

    private func requestSystemAudio() {
        let capture = SystemAudioCapture()
        do {
            try capture.start()
            UserDefaults.standard.set(true, forKey: "systemAudio.requested")
            systemAudioRequested = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { capture.stop() }
        } catch {
            Log.error("System audio request failed: \(error.localizedDescription)", "setup")
            openPrivacy("Privacy_AudioCapture")
        }
    }

    private func downloadModel() {
        downloadingModel = true
        let id = settings.notesLanguage
        Task {
            do { _ = try await LiveTranscriber.prepareModel(for: id) } catch { Log.error("Model download: \(error.localizedDescription)", "setup") }
            downloadingModel = false
            modelInstalled = await LiveTranscriber.isModelInstalled(id)
        }
    }

    private func openPrivacy(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}
