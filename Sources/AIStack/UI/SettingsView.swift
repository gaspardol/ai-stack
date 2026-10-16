import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var claudePathDisplay = ""

    private let models = [("haiku", "Haiku — fastest"), ("sonnet", "Sonnet — balanced"), ("opus", "Opus — best quality")]

    var body: some View {
        Form {
            Section("Writing assistant") {
                Toggle("Check my writing in every app", isOn: $settings.writingEnabled)
                Toggle("Suggest better phrasing (blue underlines)", isOn: $settings.styleSuggestions)
                Picker("Model", selection: $settings.writingModel) {
                    ForEach(models, id: \.0) { Text($0.1).tag($0.0) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Turned off in").font(.callout)
                    ForEach(settings.disabledApps, id: \.self) { bundleID in
                        HStack {
                            Text(appName(bundleID))
                            Text(bundleID).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                settings.disabledApps.removeAll { $0 == bundleID }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Text("Tip: use the menu bar icon → “Turn Off in <App>” while that app is in front.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Meeting notes") {
                Toggle("Detect calls", isOn: $settings.notesEnabled)
                Picker("When a call starts", selection: $settings.notesMode) {
                    Text("Take notes automatically").tag("auto")
                    Text("Ask me with a notification").tag("ask")
                    Text("Do nothing (start manually)").tag("manual")
                }
                Picker("Call language", selection: $settings.notesLanguage) {
                    ForEach(AppSettings.notesLanguages, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Notes model", selection: $settings.notesModel) {
                    ForEach(models, id: \.0) { Text($0.1).tag($0.0) }
                }
                HStack {
                    Text("Markdown folder")
                    Spacer()
                    Text(settings.notesFolder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }
                }
            }

            Section("Claude") {
                HStack {
                    Text("Claude Code CLI")
                    Spacer()
                    Text(claudePathDisplay).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                TextField("Custom path (optional)", text: $settings.claudePath)
                Text("All AI requests run through the `claude` CLI and its login, so they use your Claude subscription. No API key needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Data") {
                HStack {
                    Button("Open Meeting Data") { NSWorkspace.shared.open(AppPaths.meetings) }
                    Button("Open Log") { NSWorkspace.shared.open(Log.fileURL) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 560)
        .onAppear {
            DispatchQueue.global().async {
                let path = ClaudeCLI.shared.binaryPath() ?? "Not found"
                DispatchQueue.main.async { claudePathDisplay = path }
            }
        }
    }

    private func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.notesFolderURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.notesFolder = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}
