import SwiftUI

let speakerHost = ProcessInfo.processInfo.environment["KEF_HOST"] ?? "lsxlite-841715063b20.local"

@MainActor
final class Speaker: ObservableObject {
    @Published var volume: Double = 0
    @Published var reachable = false
    @Published var muted = false
    @Published var source = ""
    @Published var title = ""
    @Published var subtitle = ""
    @Published var artwork: URL?
    @Published var playing = false
    private var pendingSend: Task<Void, Never>?
    private let radio = RadioStreamLookup()

    private func getValue(_ path: String) async -> [String: Any]? {
        guard let url = URL(string: "http://\(speakerHost)/api/getData?path=\(path)&roles=value"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return json.first
    }

    func refreshNowPlaying() async {
        let physical = await getValue("settings:/kef/play/physicalSource")?["kefPhysicalSource"] as? String ?? ""
        let player = await getValue("player:player/data")
        let track = player?["trackRoles"] as? [String: Any]
        let meta = (track?["mediaData"] as? [String: Any])?["metaData"] as? [String: Any]
        let service = meta?["serviceID"] as? String ?? ""

        let newPlaying = player?["state"] as? String == "playing"
        var newSource = physical == "wifi" ? Self.serviceName(service) : Self.inputName(physical)
        var newTitle = "", newSubtitle = "", newArtwork: URL?
        if physical == "wifi", let track {
            newTitle = track["title"] as? String ?? ""
            let artist = meta?["artist"] as? String ?? ""
            let album = meta?["album"] as? String ?? ""
            newSubtitle = [artist, album].filter { !$0.isEmpty }.joined(separator: " — ")
            newArtwork = (track["icon"] as? String).flatMap(URL.init(string:))
            if newSubtitle.isEmpty, meta?["radioStation"] as? Bool == true {
                newSubtitle = meta?["slogan"] as? String ?? ""
                let stream = meta?["organization"] as? String ?? ""
                let station = (player?["mediaRoles"] as? [String: Any])?["title"] as? String ?? newTitle
                var song: Song?
                // Some stations already put "Artist - Title" in the track title; searching by it would find nothing or the wrong station.
                if newTitle != station, let split = newTitle.range(of: " - ") {
                    song = (String(newTitle[split.upperBound...]), String(newTitle[..<split.lowerBound]), nil)
                }
                if song == nil { song = await Self.fipNowPlaying(stream: stream, title: station) }
                if song == nil { song = await radio.nowPlaying(station: station, stream: stream) }
                if let song {
                    newSource = station
                    newTitle = song.title
                    newSubtitle = song.artist
                    newArtwork = song.cover ?? newArtwork
                }
            }
        }
        // Assigning a @Published property re-renders even when the value is the same, which makes the popover flicker.
        if playing != newPlaying { playing = newPlaying }
        if source != newSource { source = newSource }
        if title != newTitle { title = newTitle }
        if subtitle != newSubtitle { subtitle = newSubtitle }
        if artwork != newArtwork { artwork = newArtwork }
    }

    // The speaker only reports the station for radio, so FIP songs come from Radio France's live feed.
    private static let fipStations: [String: Int] = [
        "fip": 7, "fiprock": 64, "fipjazz": 65, "fipgroove": 66, "fipworld": 69, "fipmonde": 69,
        "fipnouveautes": 70, "fipreggae": 71, "fipelectro": 74, "fipmetal": 77, "fippop": 78,
        "fiphiphop": 95, "fipsacrefrancais": 96, "fipcultes": 709,
    ]

    private static func fipNowPlaying(stream: String, title: String) async -> (title: String, artist: String, cover: URL?)? {
        func key(_ s: String) -> String {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).filter(\.isLetter)
        }
        // Stream names look like "fipcultes-hifi.aac".
        let streamKey = key(String(stream.split(separator: "-").first ?? ""))
        guard let id = fipStations[streamKey] ?? fipStations[key(title)],
              let url = URL(string: "https://api.radiofrance.fr/livemeta/live/\(id)/transistor_musical_player"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let now = json["now"] as? [String: Any],
              now["secondLineSongUuid"] is String,
              let line = now["secondLine"] as? String
        else { return nil }
        let parts = line.components(separatedBy: " • ")
        let artist = parts.count > 1 ? parts[0] : ""
        let song = parts.count > 1 ? parts.dropFirst().joined(separator: " • ") : line
        let cover = (now["cover"] as? String).flatMap {
            URL(string: "https://www.radiofrance.fr/pikapi/images/\($0)/200x200")
        }
        return (song, artist, cover)
    }

    private static func serviceName(_ id: String) -> String {
        switch id.lowercased() {
        case "": return "Wi‑Fi"
        case "spotify": return "Spotify"
        case "airableradios": return "Internet Radio"
        case "airablepodcasts": return "Podcast"
        case "airplay": return "AirPlay"
        case "googlecast", "cast", "chromecast": return "Chromecast"
        case "tidal": return "TIDAL"
        case "qobuz": return "Qobuz"
        case "deezer": return "Deezer"
        case "amazon", "amazonmusic": return "Amazon Music"
        case "upnp", "dlna": return "Music Server"
        default: return id
        }
    }

    private static func inputName(_ id: String) -> String {
        switch id {
        case "bluetooth": return "Bluetooth"
        case "tv": return "TV"
        case "optic", "optical": return "Optical"
        case "coaxial": return "Coaxial"
        case "analog": return "Aux"
        case "usb": return "USB"
        case "standby": return "Standby"
        default: return id.capitalized
        }
    }

    var sourceIcon: String {
        switch source {
        case "Spotify", "TIDAL", "Qobuz", "Deezer", "Amazon Music": return "music.note"
        case "Internet Radio": return "antenna.radiowaves.left.and.right"
        case "Podcast": return "mic"
        case "AirPlay": return "airplayaudio"
        case "Chromecast": return "tv.and.mediabox"
        case "Bluetooth": return "dot.radiowaves.left.and.right"
        case "TV": return "tv"
        case "Optical", "Coaxial": return "cable.connector"
        case "USB": return "cable.connector.horizontal"
        case "Aux": return "headphones"
        default: return "hifispeaker"
        }
    }

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

typealias Song = (title: String, artist: String, cover: URL?)

// The speaker never exposes a radio station's real stream URL, so the station is looked up by name
// in the public radio-browser.info directory and the song is read from the stream's ICY metadata.
@MainActor
final class RadioStreamLookup {
    private var streams: [String: URL?] = [:]
    private var lastRead: (station: String, at: Date, song: Song?)?

    func nowPlaying(station: String, stream: String) async -> Song? {
        // Each read opens the audio stream, so reuse the last result for a while.
        if let lastRead, lastRead.station == station, Date().timeIntervalSince(lastRead.at) < 15 {
            return lastRead.song
        }
        let url: URL?
        if let cached = streams[station] {
            url = cached
        } else {
            url = await Self.findStream(station: station, streamName: stream)
            streams[station] = url
        }
        let song = url == nil ? nil : await Self.readStreamTitle(url!)
        lastRead = (station, Date(), song)
        return song
    }

    private static func findStream(station: String, streamName: String) async -> URL? {
        guard !station.isEmpty,
              let name = station.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://de1.api.radio-browser.info/json/stations/byname/\(name)?hidebroken=true&order=votes&reverse=true&limit=20")
        else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("KEFVolume/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let results = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        // Speaker stream names look like "fipcultes-hifi.aac"; a URL containing that stem is the strongest match.
        let stem = String(streamName.split(separator: "-").first ?? "").lowercased()
        func score(_ s: [String: Any]) -> Int {
            let url = (s["url_resolved"] as? String ?? "").lowercased()
            let exact = (s["name"] as? String)?.caseInsensitiveCompare(station) == .orderedSame
            return (stem.count > 2 && url.contains(stem) ? 2 : 0) + (exact ? 1 : 0)
        }
        // Results arrive sorted by votes, and max(by:) keeps the first of equal scores.
        let best = results
            .filter { !($0["url_resolved"] as? String ?? "").lowercased().contains(".m3u8") }
            .enumerated()
            .max { (score($0.element), -$0.offset) < (score($1.element), -$1.offset) }?.element
        return (best?["url_resolved"] as? String).flatMap(URL.init(string:))
    }

    private static func readStreamTitle(_ url: URL) async -> Song? {
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("KEFVolume/1.0", forHTTPHeaderField: "User-Agent")
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request) else { return nil }
        defer { bytes.task.cancel() }
        guard let interval = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "icy-metaint")).flatMap(Int.init),
              interval > 0
        else { return nil }
        var iterator = bytes.makeAsyncIterator()
        do {
            for _ in 0..<interval { guard try await iterator.next() != nil else { return nil } }
            guard let length = try await iterator.next() else { return nil }
            var meta = [UInt8]()
            for _ in 0..<(Int(length) * 16) {
                guard let b = try await iterator.next() else { break }
                meta.append(b)
            }
            let text = String(decoding: meta.filter { $0 != 0 }, as: UTF8.self)
            return parse(text)
        } catch {
            return nil
        }
    }

    // Metadata looks like: StreamTitle='Artist - Title';StreamUrl='...';
    private static func parse(_ meta: String) -> Song? {
        func field(_ name: String) -> String? {
            guard let start = meta.range(of: "\(name)='") else { return nil }
            let rest = meta[start.upperBound...]
            let end = rest.range(of: "';")?.lowerBound ?? rest.endIndex
            let value = rest[..<end].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        guard let title = field("StreamTitle") else { return nil }
        let cover = field("StreamUrl").flatMap(URL.init(string:)).flatMap {
            ["jpg", "jpeg", "png", "webp"].contains($0.pathExtension.lowercased()) ? $0 : nil
        }
        guard let split = title.range(of: " - ") else { return (title, "", cover) }
        return (String(title[split.upperBound...]), String(title[..<split.lowerBound]), cover)
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
                if speaker.reachable && !speaker.source.isEmpty {
                    HStack(spacing: 10) {
                        AsyncImage(url: speaker.artwork) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: speaker.sourceIcon)
                                .font(.title2).foregroundStyle(.secondary)
                        }
                        .frame(width: 44, height: 44)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Label(speaker.source, systemImage: speaker.sourceIcon)
                                .font(.caption).foregroundStyle(.secondary)
                            if !speaker.title.isEmpty {
                                Text(speaker.title).font(.callout.weight(.medium)).lineLimit(1)
                            }
                            if !speaker.subtitle.isEmpty {
                                Text(speaker.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if !speaker.title.isEmpty && !speaker.playing {
                            Image(systemName: "pause.fill").foregroundStyle(.secondary)
                        }
                    }
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
            // Track changes happen on the speaker side, so poll while the popover is open.
            .task {
                while !Task.isCancelled {
                    await speaker.refreshNowPlaying()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        } label: {
            Image(systemName: speaker.muted ? "speaker.slash.fill" : "hifispeaker.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
