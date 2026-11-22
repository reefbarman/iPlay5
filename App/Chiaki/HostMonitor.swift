import ChiakiKit
import Foundation
import Observation

struct HostStatus: Equatable {
	enum State { case unknown, ready, standby }
	var state: State
	var name: String
	var runningApp: String
}

/// Polls registered consoles over unicast UDP so the list can show Ready/Standby/Offline.
/// Consoles with a remote address are polled there too, which answers when
/// the router forwards the Remote Play ports (UDP 9302 for status).
@Observable
final class HostMonitor {
	private var local: [UUID: HostStatus] = [:]
	private var remote: [UUID: HostStatus] = [:]
	/// Consoles that have a remote address being polled
	private var remoteWatched: Set<UUID> = []

	/// The LAN status while the console answers there, otherwise the remote
	/// one. A console with a remote address that hasn't answered either way
	/// has no status, so Play stays available and dials the remote address.
	var statuses: [UUID: HostStatus] {
		var result = local
		for id in remoteWatched where !answeringLocally(id) {
			result[id] = remote[id]
		}
		return result
	}

	/// Whether to dial this console's remote address: it has one and isn't
	/// answering on the local network.
	func usesRemote(_ console: Console) -> Bool {
		console.remoteAddress != nil && !answeringLocally(console.id)
	}

	private func answeringLocally(_ id: UUID) -> Bool {
		(local[id]?.state ?? .unknown) != .unknown
	}

	private struct Key: Hashable {
		let id: UUID
		let remote: Bool
	}

	@ObservationIgnored private var monitors: [Key: (handle: OpaquePointer, context: Unmanaged<Context>, host: String)] = [:]

	private final class Context {
		let key: Key
		weak var owner: HostMonitor?
		init(key: Key, owner: HostMonitor) {
			self.key = key
			self.owner = owner
		}
	}

	func sync(with consoles: [Console]) {
		var wanted: [Key: String] = [:]
		for console in consoles {
			let localKey = Key(id: console.id, remote: false)
			if wanted[localKey] == nil { wanted[localKey] = console.host }
			if let address = console.remoteAddress { wanted[Key(id: console.id, remote: true)] = address }
		}
		// Drop removed consoles and addresses, and restart ones whose address changed
		for (key, monitor) in monitors where wanted[key] != monitor.host {
			stop(key)
		}
		for (key, host) in wanted where monitors[key] == nil {
			start(key, host: host)
		}
		let watched = Set(wanted.keys.filter(\.remote).map(\.id))
		if watched != remoteWatched { remoteWatched = watched }
	}

	private func start(_ key: Key, host: String) {
			let context = Unmanaged.passRetained(Context(key: key, owner: self))
		let handle = ck_host_monitor_start(host, { user, status in
			guard let user, let status else { return }
			let context = Unmanaged<Context>.fromOpaque(user).takeUnretainedValue()
			let s = status.pointee
			let state: HostStatus.State =
				switch s.state {
				case CK_HOST_STATE_READY: .ready
				case CK_HOST_STATE_STANDBY: .standby
				default: .unknown
				}
			var copy = s
			let name = withUnsafeBytes(of: &copy.host_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
			let app = withUnsafeBytes(of: &copy.running_app_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
			let key = context.key
			DispatchQueue.main.async { [weak owner = context.owner] in
				owner?.record(HostStatus(state: state, name: name, runningApp: app), for: key)
			}
		}, context.toOpaque())
		if let handle {
			monitors[key] = (handle, context, host)
		} else {
			context.release()
		}
	}

	private func record(_ status: HostStatus?, for key: Key) {
		// Callbacks queued before a stop can land after it; ignore those
		guard status == nil || monitors[key] != nil else { return }
		if key.remote { remote[key.id] = status } else { local[key.id] = status }
	}

	func stopAll() {
		for key in monitors.keys { stop(key) }
	}

	private func stop(_ key: Key) {
		guard let (handle, context, _) = monitors.removeValue(forKey: key) else { return }
		// Joins the discovery thread, so no callbacks run after this returns.
		ck_host_monitor_stop(handle)
		context.release()
		record(nil, for: key)
	}

	deinit { stopAll() }
}

enum ConsoleWaker {
	static func wake(_ console: Console) -> Bool {
		console.registKey.withUnsafeBytes { raw in
			guard raw.count == 16 else { return false }
			return ck_wakeup(console.host, raw.bindMemory(to: UInt8.self).baseAddress, console.ps5) == 0
		}
	}
}
