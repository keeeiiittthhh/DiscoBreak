import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    var onTestDrop: () -> Void

    var body: some View {
        TabView {
            LookTab(store: store).tabItem { Label("Look", systemImage: "circle.grid.cross") }
            MotionTab(store: store).tabItem { Label("Motion", systemImage: "arrow.clockwise") }
            MusicTab(store: store).tabItem { Label("Music", systemImage: "music.note") }
            BehaviourTab(store: store).tabItem { Label("Behaviour", systemImage: "gearshape") }
        }
        .frame(width: 460, height: 400)
        .overlay(alignment: .bottom) {
            Button("Test Drop", action: onTestDrop)
                .padding(.bottom, 10)
        }
    }
}

private struct Row<Content: View>: View {
    let label: String
    let detail: String?
    @ViewBuilder var content: Content

    init(_ label: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).frame(width: 120, alignment: .leading)
                content
            }
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).padding(.leading, 124)
            }
        }
    }
}

private struct LookTab: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        Form {
            Picker("Ball", selection: $store.settings.ballChoice) {
                ForEach(BallChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(ballNote).font(.caption).foregroundStyle(.secondary)

            if store.settings.ballChoice == .hyperreal {
                Toggle("Reflect the room", isOn: Binding(
                    get: { store.settings.ballCamera },
                    set: { on in
                        guard on else { store.settings.ballCamera = false; return }
                        // Ask here, where the reason is on screen, not mid-show.
                        CameraReflection.requestAccess { store.settings.ballCamera = $0 }
                    }))
                Text(cameraNote).font(.caption).foregroundStyle(.secondary)
                Row("Dim screen", detail: "Darkens everything behind the ball so the light stands out.") {
                    Slider(value: $store.settings.dimBackground, in: 0...0.85)
                    Text("\(Int(store.settings.dimBackground * 100))%").monospacedDigit().frame(width: 46)
                }
            }

            Row("Ball size") {
                Slider(value: $store.settings.ballDiameter, in: 60...260)
                Text("\(Int(store.settings.ballDiameter))pt").monospacedDigit().frame(width: 46)
            }
            Row("Drop distance") {
                Slider(value: $store.settings.dropDistance, in: 90...500)
                Text("\(Int(store.settings.dropDistance))pt").monospacedDigit().frame(width: 46)
            }
            Row("Light intensity") {
                Slider(value: $store.settings.lightIntensity, in: 0.2...2.0)
                Text(String(format: "%.1f", store.settings.lightIntensity)).monospacedDigit().frame(width: 46)
            }
            Row("Spots", detail: "Pool size. A real ball throws about 105 at once.") {
                Slider(value: .init(get: { Double(store.settings.spotCount) },
                                    set: { store.settings.spotCount = Int($0) }), in: 20...260)
                Text("\(store.settings.spotCount)").monospacedDigit().frame(width: 46)
            }
            Row("Spread", detail: "Ball-to-wall distance. Higher throws light wider and softer.") {
                Slider(value: $store.settings.wallDistance, in: 1.5...9.0)
                Text(String(format: "%.1f", store.settings.wallDistance)).monospacedDigit().frame(width: 46)
            }
        }
        .padding(20)
    }

    private var ballNote: String {
        switch store.settings.ballChoice {
        case .classic:   return "A painted disc with a facet grid scrolling across it. Cheapest."
        case .mirror:    return "Several hundred real mirrors on a sphere, turning in 3D."
        case .hyperreal: return "A thousand mirrors drawn on the graphics chip, throwing soft specks of light. Bigger and lower than the other two."
        }
    }

    private var cameraNote: String {
        if !CameraReflection.isAvailable {
            return "No camera found, so the mirrors reflect soft studio lights instead."
        }
        if CameraReflection.isDenied {
            return "Camera access is off for DiscoBreak. Turn it on in System Settings → Privacy & Security → Camera. Until then the mirrors reflect studio lights."
        }
        return "The mirrors show your room and you. The camera runs only while the ball is down, and nothing is recorded or saved."
    }
}

private struct MotionTab: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        Form {
            Row("Rotation", detail: "Real mirror ball motors run 20-30s per turn.") {
                Slider(value: $store.settings.rotationSeconds, in: 5...60)
                Text("\(Int(store.settings.rotationSeconds))s").monospacedDigit().frame(width: 46)
            }
            Row("Frame rate") {
                Slider(value: $store.settings.frameRate, in: 15...60, step: 15)
                Text("\(Int(store.settings.frameRate))").monospacedDigit().frame(width: 46)
            }
            Row("Drop bounce", detail: "Lower is bouncier.") {
                Slider(value: $store.settings.dropDamping, in: 5...30)
                Text(String(format: "%.0f", store.settings.dropDamping)).monospacedDigit().frame(width: 46)
            }
            Row("Drop speed") {
                Slider(value: $store.settings.dropStiffness, in: 40...300)
                Text(String(format: "%.0f", store.settings.dropStiffness)).monospacedDigit().frame(width: 46)
            }
        }
        .padding(20)
    }
}

private struct MusicTab: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        Form {
            TextField("Playlist link", text: $store.settings.spotifyPlaylist,
                      prompt: Text("https://open.spotify.com/playlist/..."))
            Toggle("Shuffle", isOn: $store.settings.spotifyShuffle)

            Row("Volume") {
                Slider(value: $store.settings.volume, in: 0...1)
                Text("\(Int(store.settings.volume * 100))%").monospacedDigit().frame(width: 46)
            }

            Text(SpotifyMusicSource.isInstalled
                 ? "The ball starts this playlist and puts back whatever you were listening to when it retracts. macOS asks once whether DiscoBreak may control Spotify."
                 : "Spotify does not appear to be installed, so the show runs silent.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

private struct BehaviourTab: View {
    @ObservedObject var store: SettingsStore
    @State private var atLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(
                get: { atLogin },
                set: { store.launchesAtLogin = $0; atLogin = $0 }))

            Toggle("Light every display", isOn: $store.settings.multiDisplay)
            Text(NSScreen.screens.count > 1
                 ? "\(NSScreen.screens.count) displays attached. The ball hangs on the built-in one; the others get the light field."
                 : "Only matters when a second display is attached.")
                .font(.caption).foregroundStyle(.secondary)

            Row("Hot zone padding", detail: "Grows the notch target so it is easier to hit.") {
                Slider(value: $store.settings.hotZonePadding, in: 0...40)
                Text("\(Int(store.settings.hotZonePadding))pt").monospacedDigit().frame(width: 46)
            }
            Row("Exit delay", detail: "How long the pointer must be away before it retracts.") {
                Slider(value: $store.settings.exitDelay, in: 0...2)
                Text(String(format: "%.1fs", store.settings.exitDelay)).monospacedDigit().frame(width: 46)
            }
        }
        .padding(20)
    }
}
