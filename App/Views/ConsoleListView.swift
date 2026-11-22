import SwiftUI

struct ConsoleListView: View {
	@Environment(ConsoleStore.self) private var store
	@Environment(SettingsStore.self) private var settings
	@State private var monitor = HostMonitor()
	@State private var discovery = LANDiscovery()
	@State private var showingAdd = false
	@State private var showingSettings = false
	@State private var playing: Console?
	@State private var waking: UUID?

	var body: some View {
		NavigationStack {
			List {
				if store.consoles.isEmpty {
					ContentUnavailableView {
						Label("No consoles yet", systemImage: "playstation.logo")
					} description: {
						Text("Link your PS5 to start streaming. Have it on the same Wi-Fi, then open Settings › System › Remote Play › Link Device on the PS5 to get a PIN.\n\nPlay with a connected game controller or use the virtual controls.")
					} actions: {
						Button("Add console") { showingAdd = true }
							.buttonStyle(.borderedProminent)
					}
				}
				ForEach(store.consoles) { console in
					ConsoleRow(
						console: console,
						status: monitor.statuses[console.id],
						waking: waking == console.id,
						play: { connect(console) },
						wake: { wake(console) }
					)
					.swipeActions {
						Button("Remove", role: .destructive) { store.remove(console) }
					}
				}
			}
			.navigationTitle("iPlay5")
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button { showingSettings = true } label: { Image(systemName: "gearshape") }
				}
				ToolbarItem(placement: .topBarTrailing) {
					Button { showingAdd = true } label: { Image(systemName: "plus") }
				}
			}
			.sheet(isPresented: $showingAdd, onDismiss: { if playing == nil { discovery.start() } }) {
				AddConsoleView()
					.onAppear { discovery.stop() } // the sheet runs its own sweep
			}
			.sheet(isPresented: $showingSettings) { SettingsView() }
			.fullScreenCover(item: $playing) { console in
				StreamView(console: console)
			}
		}
		.onAppear {
			monitor.sync(with: store.consoles)
			discovery.start()
		}
		.onChange(of: store.consoles) { _, consoles in monitor.sync(with: consoles) }
		.onChange(of: playing) { _, playing in
			// Don't poll or sweep the network while streaming
			if playing == nil {
				monitor.sync(with: store.consoles)
				discovery.start()
			} else {
				monitor.stopAll()
				discovery.stop()
			}
		}
		.onChange(of: discovery.consoles) { _, found in
			// Follow a linked console to its new IP if DHCP moved it
			for console in store.consoles {
				if let match = found.first(where: { $0.id == console.hostID }), match.host != console.host {
					var updated = console
					updated.host = match.host
					store.update(updated)
				}
			}
		}
		.onChange(of: monitor.statuses) { _, statuses in
			// Auto-connect once a console we woke up reports ready
			if let id = waking, statuses[id]?.state == .ready, let console = store.consoles.first(where: { $0.id == id }) {
				waking = nil
				connect(console)
			}
		}
	}

	private func connect(_ console: Console) {
		playing = console
	}

	private func wake(_ console: Console) {
		if ConsoleWaker.wake(console) {
			waking = console.id
			// Give up auto-connecting after a while
			DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
				if waking == console.id { waking = nil }
			}
		}
	}
}

private struct ConsoleRow: View {
	let console: Console
	let status: HostStatus?
	let waking: Bool
	let play: () -> Void
	let wake: () -> Void

	var body: some View {
		HStack(spacing: 14) {
			Image(systemName: "playstation.logo")
				.font(.title)
				.frame(width: 44)
			VStack(alignment: .leading, spacing: 3) {
				Text(console.name).font(.headline)
				Text(console.host).font(.caption).foregroundStyle(.secondary)
				statusLabel
			}
			Spacer()
			if waking {
				ProgressView()
			} else if status?.state == .standby {
				Button("Wake", action: wake).buttonStyle(.bordered)
			} else {
				Button("Play", action: play)
					.buttonStyle(.borderedProminent)
					.disabled(status?.state != .ready && status != nil)
			}
		}
		.padding(.vertical, 6)
	}

	@ViewBuilder private var statusLabel: some View {
		switch status?.state {
		case .ready:
			Label(status?.runningApp.isEmpty == false ? status!.runningApp : "Ready", systemImage: "circle.fill")
				.font(.caption).foregroundStyle(.green)
		case .standby:
			Label("Rest mode", systemImage: "moon.fill").font(.caption).foregroundStyle(.orange)
		default:
			Label(waking ? "Waking…" : "Not found", systemImage: "circle").font(.caption).foregroundStyle(.secondary)
		}
	}
}
