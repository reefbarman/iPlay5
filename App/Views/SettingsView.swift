import SwiftUI

/// Stream settings, shared by the main settings sheet and the in-stream menu.
struct StreamSettingsForm: View {
	@Binding var settings: StreamSettings

	var body: some View {
		Section {
			Picker("Resolution", selection: $settings.resolution) {
				ForEach(StreamResolution.allCases) { Text($0.label).tag($0) }
			}
			Picker("Frame rate", selection: $settings.fps) {
				Text("60 fps").tag(60)
				Text("30 fps").tag(30)
			}
			VStack(alignment: .leading) {
				HStack {
					Text("Bitrate")
					Spacer()
					Text("\(settings.bitrateMbps) Mbps").foregroundStyle(.secondary).monospacedDigit()
				}
				Slider(value: Binding(get: { Double(settings.bitrateMbps) }, set: { settings.bitrateMbps = Int($0) }), in: 5...100, step: 5)
			}
			Picker("Codec", selection: $settings.codec) {
				ForEach(VideoCodecChoice.allCases) { Text($0.label).tag($0) }
			}
			.disabled(settings.hdr)
			Toggle("HDR", isOn: $settings.hdr)
		} header: {
			Text("Video")
		} footer: {
			Text("PS5 Remote Play tops out at 1080p60. The PS5 may cap the bitrate below what you ask for, so watch the stats overlay. HDR needs H.265 and HDR turned on in the PS5's video output settings. Changing these reconnects the stream.")
		}

		Section {
			Picker("Picture", selection: $settings.displayMode) {
				ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
			}
			Toggle("Sharp upscaling", isOn: $settings.sharpUpscaling)
			if UIScreen.main.maximumFramesPerSecond > 60 {
				Toggle("120 Hz screen", isOn: $settings.highRefreshDisplay)
			}
			Picker("Frame generation (experimental)", selection: $settings.frameGenMode) {
				ForEach(FrameGenMode.allCases) { Text($0.label).tag($0) }
			}
			Toggle("Show stats", isOn: $settings.showStats)
		} header: {
			Text("Display")
		} footer: {
			Text("Fit shows the whole picture, with black bars where the screen is a different shape to 16:9. Zoom fills the screen and crops the overflow. 120 Hz screen gets each frame on screen sooner, for a little more battery. Frame generation makes an extra frame between each pair the PS5 sends, so 30 fps looks like 60 and 60 like 120, for half a frame of extra delay. 60 fps needs the 120 Hz screen. FlyHigh uses the FlyHighFG model by the FlyHigh engine authors (CC BY-NC 4.0).")
		}

		Section {
			Toggle("Rumble", isOn: $settings.rumble)
			Toggle("Phone gyro for motion controls", isOn: $settings.phoneMotion)
			Toggle("Select button is touchpad click", isOn: $settings.selectIsTouchpad)
		} header: {
			Text("Controller")
		} footer: {
			Text("Phone gyro is used when the controller has no motion sensors, like a GameSir G8+. Hold Select + Start for a second during a stream to open the menu.")
		}

		Section {
			Toggle("Frame capture button", isOn: $settings.frameCapture)
		} header: {
			Text("Debug")
		} footer: {
			Text("Adds a button at the bottom left of the stream that saves the last couple of seconds of frames, real and generated, to Files › On My iPhone › iPlay5 › Frame captures. Uses up to about 800 MB of memory while on.")
		}
	}
}

struct SettingsView: View {
	@Environment(SettingsStore.self) private var store
	@Environment(ConsoleStore.self) private var consoles
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		@Bindable var store = store
		NavigationStack {
			Form {
				StreamSettingsForm(settings: $store.settings)

				Section {
					ShareLink(
						item: DiagnosticsReport(consoleNames: consoles.consoles.map(\.name), settings: store.settings),
						preview: SharePreview("iPlay5 diagnostics")
					) {
						Label("Share diagnostics", systemImage: "ladybug")
					}
					Link(destination: URL(string: "https://github.com/reefbarman/iPlay5/issues/new")!) {
						Label("Report a problem on GitHub", systemImage: "exclamationmark.bubble")
					}
				} header: {
					Text("Help")
				} footer: {
					Text("The report has your phone model, screen details, settings and the app's logs since it was opened. IP addresses, keys, account IDs and console names are removed. Share it before closing the app, so the logs still cover the problem.")
				}
			}
			.navigationTitle("Settings")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
			}
		}
	}
}
