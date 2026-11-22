import Foundation

/// "Optimise connection": watches the running stream for a short while and suggests
/// a bitrate (and network smoothing) from what actually arrived.
///
/// There's no way to measure raw throughput to the PS5, and it sends much less on a
/// quiet screen than in busy gameplay, so this judges the real stream: packet loss,
/// lost frames and how much of the requested bitrate turned up.
struct ConnectionCheck {
	static let duration = 20

	private struct Sample {
		let bitrateMbps: Double
		let packetLoss: Double
		let lostFrames: Int
		let failedFrames: Int
		let rttMs: Double
	}

	private var samples: [Sample] = []

	var progress: Double { min(1, Double(samples.count) / Double(Self.duration)) }
	var isComplete: Bool { samples.count >= Self.duration }
	var secondsLeft: Int { max(0, Self.duration - samples.count) }

	mutating func add(_ stats: StreamStats) {
		samples.append(Sample(
			bitrateMbps: stats.bitrateMbps, packetLoss: stats.packetLoss,
			lostFrames: stats.lostFrames, failedFrames: stats.failedFrames, rttMs: stats.rttMs))
	}

	func result(for settings: StreamSettings) -> ConnectionCheckResult {
		guard let first = samples.first, let last = samples.last else {
			return ConnectionCheckResult(
				verdict: .inconclusive, title: "Couldn't check the connection",
				detail: "The stream wasn't running long enough. Try again while playing.")
		}
		let requested = settings.bitrateMbps
		let averageLoss = samples.map(\.packetLoss).reduce(0, +) / Double(samples.count)
		let lost = max(0, last.lostFrames - first.lostFrames) + max(0, last.failedFrames - first.failedFrames)
		let peak = samples.map(\.bitrateMbps).max() ?? 0
		let ping = samples.map(\.rttMs).max() ?? 0
		let lossText = String(format: "%.1f%%", averageLoss * 100)
		let framesText = lost == 1 ? "1 frame" : "\(lost) frames"
		let pingNote = ping > 40
			? " Ping is high (\(Int(ping)) ms), so a 5 GHz network or the PS5 on Ethernet would help too."
			: ""

		if averageLoss >= 0.01 || lost >= 3 {
			// Aim well under what was getting through, so there's headroom for busier scenes
			let basis = peak > 1 ? min(Double(requested), peak) : Double(requested)
			let suggestion = min(requested - 5, max(10, Self.roundDown5(basis * 0.7)))
			let smoothing = !settings.networkSmoothing
			var detail = "\(lossText) of packets and \(framesText) were lost in \(Self.duration) seconds at \(requested) Mbps."
			if suggestion >= 10, suggestion < requested {
				detail += " Try \(suggestion) Mbps\(smoothing ? " with network smoothing on" : "")."
			} else if smoothing {
				detail += " The bitrate is already low, so try network smoothing, or move closer to the router."
			} else {
				detail += " The bitrate is already low. Moving closer to the router, or the PS5 on Ethernet, should help."
			}
			return ConnectionCheckResult(
				verdict: .tooHigh, title: "Your connection is dropping video", detail: detail + pingNote,
				bitrateMbps: suggestion >= 10 && suggestion < requested ? suggestion : nil,
				networkSmoothing: smoothing ? true : nil)
		}

		if averageLoss >= 0.003 || lost >= 1 {
			let smoothing = !settings.networkSmoothing
			let detail = "\(framesText.capitalizedFirst) lost in \(Self.duration) seconds at \(requested) Mbps. That's a small hitch now and then."
				+ (smoothing ? " Network smoothing should ride these out." : " Keep the current settings.")
			return ConnectionCheckResult(
				verdict: .minorHiccups, title: "Mostly smooth, a few hiccups", detail: detail + pingNote,
				networkSmoothing: smoothing ? true : nil)
		}

		// Clean. Only suggest more if the stream actually used most of what was asked for.
		if peak < Double(requested) * 0.6 {
			return ConnectionCheckResult(
				verdict: .inconclusive, title: "No loss, but not a full test",
				detail: "Nothing was lost, but the PS5 only sent up to \(Int(peak.rounded())) of the \(requested) Mbps you asked for. That's normal on menus and quiet scenes. Check again during busy gameplay to see whether a higher bitrate would hold up." + pingNote)
		}
		if requested < 100 {
			let suggestion = min(100, Self.roundDown5(Double(requested) * 1.5))
			return ConnectionCheckResult(
				verdict: .roomToGrow, title: "Clean connection",
				detail: "No loss at \(requested) Mbps. You could try \(suggestion) Mbps for a sharper picture in busy scenes, then check again." + pingNote,
				bitrateMbps: suggestion)
		}
		return ConnectionCheckResult(
			verdict: .good, title: "Clean connection",
			detail: "No loss at \(requested) Mbps. Your current settings are a good fit." + pingNote)
	}

	private static func roundDown5(_ value: Double) -> Int { Int(value / 5) * 5 }
}

struct ConnectionCheckResult: Equatable {
	enum Verdict { case good, roomToGrow, minorHiccups, tooHigh, inconclusive }

	let verdict: Verdict
	let title: String
	let detail: String
	/// Suggested changes, nil where it suggests keeping the current value
	var bitrateMbps: Int?
	var networkSmoothing: Bool?

	var hasSuggestion: Bool { bitrateMbps != nil || networkSmoothing != nil }

	/// What the Apply button says
	var applyLabel: String {
		switch (bitrateMbps, networkSmoothing) {
		case (let rate?, true?): "Use \(rate) Mbps and smoothing"
		case (let rate?, _): "Use \(rate) Mbps"
		case (nil, true?): "Turn on smoothing"
		default: "Apply"
		}
	}

	func apply(to settings: inout StreamSettings) {
		if let bitrateMbps { settings.bitrateMbps = bitrateMbps }
		if let networkSmoothing { settings.networkSmoothing = networkSmoothing }
	}
}

private extension String {
	var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
