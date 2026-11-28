import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var engine: OnlineEngine
    @State private var showOffline = false
    @State private var showModels = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Images", selection: $engine.imageEngine) { ForEach(ImageEngine.allCases) { Text($0.title).tag($0) } }
                    Picker("Videos", selection: $engine.videoEngine) { ForEach(VideoEngine.allCases) { Text($0.title).tag($0) } }
                    Stepper("Images per prompt: \(engine.imagesPerPrompt)", value: $engine.imagesPerPrompt, in: 1...4)
                    Toggle("Save everything to Photos automatically", isOn: $engine.autoSave)
                    Toggle("Endless feed (more images when you reach the bottom)", isOn: $engine.endless)
                } header: { Text("Engines") } footer: {
                    Text("Auto tries the free services in order and moves to the next one when one is busy or out of free time: Z-Image Turbo → FLUX.1 schnell → FLUX.1 dev → Pollinations → AI Horde. Photo edits use FLUX.1 Kontext, then AI Horde.")
                }

                Section {
                    SecureField("hf_… (optional)", text: $engine.settings.hfToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Link("Get a free token (huggingface.co → Settings → Access Tokens, type Read)", destination: URL(string: "https://huggingface.co/settings/tokens")!)
                        .font(.footnote)
                } header: { Text("Hugging Face (free)") } footer: {
                    Text("Without a token you share a small daily GPU allowance (about 2 minutes) with everyone on your network. A free account's token raises it to about 5 minutes a day, enough for roughly 30 to 60 images or several videos. The token stays in this phone's Keychain.")
                }

                Section {
                    SecureField("Pollinations key sk_… (optional)", text: $engine.settings.pollinationsKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("AI Horde key (optional)", text: $engine.settings.hordeKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Link("Pollinations keys", destination: URL(string: "https://enter.pollinations.ai")!).font(.footnote)
                    Link("Free AI Horde account", destination: URL(string: "https://aihorde.net/register")!).font(.footnote)
                } header: { Text("Backup services") } footer: {
                    Text("Without a key, Pollinations allows 1 image every 45 seconds and AI Horde keeps anonymous images small (about 512 px) and may queue for a while. Both are free.")
                }

                Section {
                    TextField("A1111 / Forge, e.g. http://1.2.3.4:7860", text: $engine.settings.a1111URL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("ComfyUI, e.g. http://1.2.3.4:8188", text: $engine.settings.comfyURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("ComfyUI checkpoint file", text: $engine.settings.comfyCheckpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    NavigationLink("ComfyUI image workflow") {
                        WorkflowEditor(title: "Image workflow", text: $engine.settings.comfyImageWorkflow, reset: ComfyUI.defaultImageWorkflow)
                    }
                    NavigationLink("ComfyUI video workflow (Wan / LTX)") {
                        WorkflowEditor(title: "Video workflow", text: $engine.settings.comfyVideoWorkflow, reset: "")
                    }
                } header: { Text("My server (optional)") } footer: {
                    Text("For your own GPU server (for example on Oracle Cloud). Workflows use ComfyUI's \"Save (API Format)\" JSON with placeholders: {{PROMPT}} {{NEGATIVE}} {{SEED}} {{WIDTH}} {{HEIGHT}} {{IMAGE}} {{FRAMES}} {{FPS}} {{STEPS}} {{CFG}} {{CHECKPOINT}}.")
                }

                Section {
                    Button { showOffline = true } label: { Label("Offline generator (on-device Stable Diffusion)", systemImage: "iphone") }
                    Button { showModels = true } label: { Label("Offline models", systemImage: "cpu") }
                } header: { Text("Offline (optional)") } footer: {
                    Text("Makes images with no internet using Core ML models you download once (1 to 3.5 GB). Much slower than online and lower quality.")
                }

                Section {
                    Text("Imagine 2.0 by Bobby Media Co. Free, open-source models only. No content filter is added by this app; each online service applies its own rules.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showOffline) { CreateView() }
            .sheet(isPresented: $showModels) { ModelsView() }
        }
    }
}

struct WorkflowEditor: View {
    let title: String
    @Binding var text: String
    let reset: String
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Paste") { if let s = UIPasteboard.general.string { text = s } }
                Button("Check") {
                    do { _ = try ComfyUI.fill(text, values: [:]); error = "Looks like valid JSON." } catch { self.error = error.localizedDescription }
                }
                Spacer()
                Button("Reset", role: .destructive) { text = reset }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .navigationTitle(title)
    }
}
