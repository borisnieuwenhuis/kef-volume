import SwiftUI

let speakerHost = ProcessInfo.processInfo.environment["KEF_HOST"] ?? "lsxlite-841715063b20.local"

@MainActor
final class Speaker: ObservableObject {
    @Published var volume: Double = 0
    @Published var reachable = false
    @Published var muted = false
    private var pendingSend: Task<Void, Never>?

    func refresh() async {
        guard let url = URL(string: "http://\(speakerHost)/api/getData?path=player:volume&roles=value"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let value = json.first?["i32_"] as? Int
        else { reachable = false; return }
        reachable = true
        volume = Double(value)
        if let url = URL(string: "http://\(speakerHost)/api/getData?path=settings:/mediaPlayer/mute&roles=value"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let m = json.first?["bool_"] as? Bool {
            muted = m
        }
    }

    func setMuted(_ on: Bool) {
        muted = on
        Task { await post(path: "settings:/mediaPlayer/mute", value: #"{"type":"bool_","bool_":\#(on)}"#) }
    }

    private func post(path: String, value: String) async {
        var request = URLRequest(url: URL(string: "http://\(speakerHost)/api/setData")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = #"{"path":"\#(path)","roles":"value","value":\#(value)}"#.data(using: .utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    // Slider drags fire many changes; only send the last one.
    func set(_ newValue: Double) {
        pendingSend?.cancel()
        pendingSend = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await post(path: "player:volume", value: #"{"type":"i32_","i32_":\#(Int(newValue))}"#)
        }
    }

    var mood: String {
        if !reachable { return "😴" }
        if muted { return "🤫" }
        switch Int(volume) {
        case 0: return "😶"
        case 1...25: return "🙂"
        case 26...50: return "😊"
        case 51...75: return "😄"
        case 76...90: return "🤩"
        default: return "🤯"
        }
    }

    func step(_ delta: Double) {
        volume = min(100, max(0, volume + delta))
        set(volume)
    }
}

@main
struct KEFVolumeApp: App {
    @StateObject private var speaker = Speaker()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("KEF LSX II").font(.headline)
                    Spacer()
                    Text(speaker.reachable ? "\(speaker.mood) \(Int(speaker.volume))" : "\(speaker.mood) offline")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                HStack {
                    Button { speaker.step(-5) } label: { Image(systemName: "speaker.minus") }
                        .buttonStyle(.borderless)
                    Slider(value: $speaker.volume, in: 0...100)
                        .onChange(of: speaker.volume) { _, v in speaker.set(v) }
                    Button { speaker.step(5) } label: { Image(systemName: "speaker.plus") }
                        .buttonStyle(.borderless)
                }
                .disabled(!speaker.reachable)
                Toggle("Mute 🤫", isOn: Binding(get: { speaker.muted }, set: { speaker.setMuted($0) }))
                    .toggleStyle(.checkbox)
                    .disabled(!speaker.reachable)
                Divider()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
            }
            .padding(12)
            .frame(width: 260)
            .task { await speaker.refresh() }
            .onAppear { Task { await speaker.refresh() } }
        } label: {
            Image(systemName: speaker.muted ? "speaker.slash.fill" : "hifispeaker.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
