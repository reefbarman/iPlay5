import ChiakiKit
import GameController
import os
import SwiftUI

/// Reads the controller the same way a stream does, so what shows here is what
/// the PS5 would get, and plays feedback through the same path the console's
/// requests take.
@Observable
final class ControllerTester {
	enum TriggerPreset: String, CaseIterable, Identifiable {
		case off, resistance, weapon, vibration

		var id: Self { self }

		var label: String {
			switch self {
			case .off: "Off"
			case .resistance: "Resistance"
			case .weapon: "Weapon"
			case .vibration: "Vibration"
			}
		}

		var effect: TriggerEffect {
			switch self {
			case .off: .off
			case .resistance: TriggerEffect(kind: .feedback(zones: Array(repeating: 0, count: 3) + Array(repeating: 0.75, count: 7)))
			case .weapon: TriggerEffect(kind: .weapon(start: 0.2, end: 0.6, strength: 1))
			case .vibration: TriggerEffect(kind: .vibration(zones: Array(repeating: 1, count: 10), hz: 40))
			}
		}
	}

	/// Rumble or haptics playing right now, for the picture to shake along
	struct Buzz: Equatable {
		/// Per grip, 0...1
		var left: Float
		var right: Float
		/// How fast the picture shakes
		var shakeHz: Double
	}

	/// Controller tilt for the picture, in radians
	struct Tilt: Equatable {
		var pitch: Double = 0
		var roll: Double = 0
		var yaw: Double = 0
	}

	private(set) var pad = CKPadState()
	private(set) var controllerName: String?
	private(set) var motionSource = "Phone gyro"
	private(set) var hasAdaptiveTriggers = false
	private(set) var hasLight = false
	private(set) var rumbleOn = "Phone"
	/// rad/s and g, in DualSense axes
	private(set) var gyro = SIMD3<Float>.zero
	private(set) var accel = SIMD3<Float>.zero
	private(set) var tilt = Tilt()
	/// The controller's own touchpad fingers, 0...1 across and down
	private(set) var touches: [CGPoint?] = [nil, nil]
	/// Fingers on the on-screen touch square, by slot, 0...1 across and down
	private(set) var screenTouches: [Int: CGPoint] = [:]
	/// A tap on the touch square, which the stream turns into a touchpad click
	private(set) var screenClick = false
	private(set) var buzz: Buzz?
	private(set) var triggerPreset = TriggerPreset.off
	private(set) var lightbar: Color?
	private(set) var player: Int?

	var touchpadClicked: Bool { isPressed(CK_BUTTON_TOUCHPAD) || screenClick }

	private struct Motion {
		var gyro = SIMD3<Float>.zero
		var accel = SIMD3<Float>(0, 1, 0)
		var yaw: Float = 0
		var lastTimestamp: UInt32?
		var scheduled = false
	}

	@ObservationIgnored private let input = ControllerInput()
	/// Motion arrives faster than the screen updates: the latest values and turning,
	/// updated on the motion thread and read once per hop to main
	@ObservationIgnored private let motion = OSAllocatedUnfairLock(initialState: Motion())
	/// Tilt from gravity, smoothed, before recentring
	@ObservationIgnored private var rawTilt = Tilt()
	@ObservationIgnored private var tiltOrigin = Tilt()
	@ObservationIgnored private weak var lastController: GCController?
	@ObservationIgnored private var running = false
	@ObservationIgnored private var hapticsTimer: Timer?
	@ObservationIgnored private var rumbleStop: DispatchWorkItem?
	@ObservationIgnored private var buzzEnd: DispatchWorkItem?
	@ObservationIgnored private var screenClickEnd: DispatchWorkItem?

	func isPressed(_ button: CKButton) -> Bool { pad.buttons & button.rawValue != 0 }

	func start(selectIsTouchpad: Bool, orientation: UIInterfaceOrientation?) {
		guard !running else { return }
		running = true
		input.selectIsTouchpad = selectIsTouchpad
		if let orientation { input.interfaceOrientation = orientation }
		input.onPad = { [weak self] pad in
			guard let self else { return }
			self.pad = pad
			if self.input.activeController !== self.lastController { self.refreshController() }
		}
		input.onTouch = { [weak self] event in
			switch event {
			case .down(let slot, let x, let y), .move(let slot, let x, let y):
				self?.touches[slot] = CGPoint(x: Double(x) / 1919, y: Double(y) / 1079)
			case .up(let slot):
				self?.touches[slot] = nil
			}
		}
		input.onMotion = { [weak self] gyro, accel, timestamp in
			guard let self else { return }
			let schedule = self.motion.withLock { m in
				// Turning left and right has no gravity to measure it against: add up the
				// gyro and let it drift back to centre over a couple of seconds
				if let last = m.lastTimestamp {
					let dt = min(0.1, Float(timestamp &- last) / 1_000_000)
					m.yaw = max(-1, min(1, (m.yaw + gyro.y * dt) * exp(-dt / 2)))
				}
				m.lastTimestamp = timestamp
				m.gyro = gyro
				m.accel = accel
				defer { m.scheduled = true }
				return !m.scheduled
			}
			guard schedule else { return }
			DispatchQueue.main.async { [weak self] in self?.motionChanged() }
		}
		input.start()
		refreshController()
	}

	func stop() {
		guard running else { return }
		running = false
		stopBuzz()
		screenClickEnd?.cancel()
		input.stop()
		input.onPad = nil
		input.onTouch = nil
		input.onMotion = nil
	}

	private func refreshController() {
		let controller = input.activeController
		lastController = controller
		controllerName = input.controllerName ?? (controller != nil ? "Controller" : nil)
		hasAdaptiveTriggers = controller?.extendedGamepad is GCDualSenseGamepad
		hasLight = controller?.light != nil
		motionSource = controller?.motion?.hasRotationRate == true ? "Controller gyro" : "Phone gyro"
		rumbleOn = controller?.haptics?.supportedLocalities.isEmpty == false ? "Controller" : "Phone"
		touches = [nil, nil]
	}

	// MARK: - Motion

	private func motionChanged() {
		let m = motion.withLock { m in
			m.scheduled = false
			return m
		}
		gyro = m.gyro
		accel = m.accel
		// Tipping and tilting from gravity (the reaction to it points up, +y when flat)
		let a = SIMD3<Double>(Double(m.accel.x), Double(m.accel.y), Double(m.accel.z))
		let target = Tilt(pitch: atan2(-a.z, a.y), roll: atan2(-a.x, (a.y * a.y + a.z * a.z).squareRoot()), yaw: 0)
		let k = 0.3
		rawTilt.pitch += (target.pitch - rawTilt.pitch) * k
		rawTilt.roll += (target.roll - rawTilt.roll) * k
		tilt = Tilt(pitch: rawTilt.pitch - tiltOrigin.pitch, roll: rawTilt.roll - tiltOrigin.roll, yaw: Double(m.yaw))
	}

	/// Treats the way the controller is held now as level
	func recentre() {
		tiltOrigin = rawTilt
		motion.withLock { $0.yaw = 0 }
		tilt = Tilt()
	}

	// MARK: - Touch square

	/// Same rules as touching the stream: fingers move on the touchpad, slots 10 and 11
	func screenTouch(_ event: ControllerInput.TouchEvent) {
		switch event {
		case .down(let slot, let x, let y), .move(let slot, let x, let y):
			screenTouches[slot] = CGPoint(x: Double(x) / 1919, y: Double(y) / 1079)
		case .up(let slot):
			screenTouches[slot] = nil
		}
	}

	/// A quick tap: the stream clicks the touchpad where the finger is, then lifts it
	func screenTap(slot: Int) {
		screenClickEnd?.cancel()
		screenClick = true
		let end = DispatchWorkItem { [weak self] in
			self?.screenClick = false
			self?.screenTouches[slot] = nil
		}
		screenClickEnd = end
		// Longer than the stream's 80 ms so you can see it
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: end)
	}

	// MARK: - Feedback

	/// Classic rumble for a moment: left is the heavy motor, right the light one
	func rumble(left: UInt8, right: UInt8) {
		stopBuzz()
		input.feedback.rumble(left: left, right: right)
		let stop = DispatchWorkItem { [weak self] in self?.input.feedback.rumble(left: 0, right: 0) }
		rumbleStop = stop
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: stop)
		showBuzz(Buzz(left: Float(left) / 255, right: Float(right) / 255, shakeHz: left > 0 ? 16 : 30), seconds: 0.6)
	}

	/// DualSense-style haptics for a moment: a sine wave at `hz` in the 3 kHz PCM the console sends
	func haptics(hz: Double) {
		stopBuzz()
		var phase = 0.0
		var remaining = 60
		let frames = 30  // 10 ms at 3 kHz, as the console sends them
		let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] timer in
			guard let self, remaining > 0 else { return timer.invalidate() }
			remaining -= 1
			var samples = [Int16](repeating: 0, count: frames * 2)
			for i in 0..<frames {
				let v = Int16(sin(phase) * 16_000)
				samples[i * 2] = v
				samples[i * 2 + 1] = v
				phase += 2 * .pi * hz / 3000
			}
			samples.withUnsafeBufferPointer { self.input.feedback.haptics($0.baseAddress!, frames: frames) }
		}
		RunLoop.main.add(timer, forMode: .common)
		hapticsTimer = timer
		showBuzz(Buzz(left: 1, right: 1, shakeHz: hz < 100 ? 13 : 32), seconds: 0.6)
	}

	private func showBuzz(_ buzz: Buzz, seconds: Double) {
		self.buzz = buzz
		let end = DispatchWorkItem { [weak self] in self?.buzz = nil }
		buzzEnd = end
		DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: end)
	}

	private func stopBuzz() {
		rumbleStop?.cancel()
		rumbleStop = nil
		hapticsTimer?.invalidate()
		hapticsTimer = nil
		buzzEnd?.cancel()
		buzzEnd = nil
		buzz = nil
		input.feedback.rumble(left: 0, right: 0)
	}

	func setTriggers(_ preset: TriggerPreset) {
		triggerPreset = preset
		input.feedback.setTriggerEffects(left: preset.effect, right: preset.effect)
	}

	func setLightbar(red: UInt8, green: UInt8, blue: UInt8) {
		lightbar = red == 0 && green == 0 && blue == 0 ? nil : Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
		input.feedback.padInfo(CK_PAD_INFO_LIGHTBAR, red, green, blue)
	}

	func setPlayer(_ number: Int) {
		player = number
		input.feedback.padInfo(CK_PAD_INFO_PLAYER, UInt8(number), 0, 0)
	}
}

struct ControllerTestView: View {
	/// Set when opened during a stream: true on open so the stream lets go of the controller, false on close
	var onActiveChange: ((Bool) -> Void)?

	@Environment(SettingsStore.self) private var store
	@State private var tester = ControllerTester()

	private static let lightbarColors: [(name: String, r: UInt8, g: UInt8, b: UInt8)] = [
		("Red", 255, 0, 0), ("Green", 0, 255, 0), ("Blue", 0, 0, 255),
		("Purple", 160, 0, 255), ("White", 255, 255, 255), ("Off", 0, 0, 0),
	]

	private static let buttonNames: [(CKButton, String)] = [
		(CK_BUTTON_CROSS, "Cross"), (CK_BUTTON_MOON, "Circle"), (CK_BUTTON_BOX, "Square"), (CK_BUTTON_PYRAMID, "Triangle"),
		(CK_BUTTON_DPAD_UP, "Up"), (CK_BUTTON_DPAD_DOWN, "Down"), (CK_BUTTON_DPAD_LEFT, "Left"), (CK_BUTTON_DPAD_RIGHT, "Right"),
		(CK_BUTTON_L1, "L1"), (CK_BUTTON_R1, "R1"), (CK_BUTTON_L3, "L3"), (CK_BUTTON_R3, "R3"),
		(CK_BUTTON_SHARE, "Create"), (CK_BUTTON_OPTIONS, "Options"), (CK_BUTTON_TOUCHPAD, "Touchpad"), (CK_BUTTON_PS, "PS"),
	]

	private var pressedText: String {
		var names = Self.buttonNames.filter { tester.isPressed($0.0) }.map(\.1)
		if tester.screenClick && !tester.isPressed(CK_BUTTON_TOUCHPAD) { names.append("Touchpad (tap)") }
		if tester.pad.l2 > 0 { names.append("L2") }
		if tester.pad.r2 > 0 { names.append("R2") }
		return names.isEmpty ? "None" : names.joined(separator: ", ")
	}

	private var touchText: String {
		let points = tester.touches.compactMap { $0 } + tester.screenTouches.sorted { $0.key < $1.key }.map(\.value)
		guard !points.isEmpty else { return "None" }
		return points.map { "\(Int(($0.x * 1919).rounded())), \(Int(($0.y * 1079).rounded()))" }.joined(separator: "  ·  ")
	}

	var body: some View {
		Form {
			Section {
				ControllerRender(tester: tester)
					.padding(.top, 8)
					.overlay(alignment: .topTrailing) {
						Button("Recentre", systemImage: "scope") { tester.recentre() }
							.labelStyle(.iconOnly)
							.buttonStyle(.borderless)
							.padding(4)
					}
				TouchSquare(
					onTouch: { tester.screenTouch($0) },
					onTap: { tester.screenTap(slot: $0) })
					.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
				LabeledContent("Pressed", value: pressedText)
				LabeledContent("Touchpad", value: touchText)
				LabeledContent("Left stick", value: Self.stick(tester.pad.left_x, tester.pad.left_y))
				LabeledContent("Right stick", value: Self.stick(tester.pad.right_x, tester.pad.right_y))
				LabeledContent("L2 / R2", value: "\(Self.percent(tester.pad.l2)) / \(Self.percent(tester.pad.r2))")
			} header: {
				Text(tester.controllerName ?? "No controller")
			} footer: {
				Text("Buttons show as the PS5 sees them, mapped by position (the bottom face button is Cross). Select shows as Create, or Touchpad if Select button is touchpad click is on. The square works like touching the stream: drag to move a finger on the touchpad, tap to click it. The controller tilts and turns with the gyro; tap the target to make the way you're holding it level.")
				if onActiveChange != nil {
					Text("While this screen is open, the PS5 doesn't get anything from your controller, and the game's rumble and lights don't reach it.")
				}
			}

			Section {
				AxisRow(label: "Pitch", value: tester.gyro.x * 180 / .pi, range: 360, format: "%+.0f°/s")
				AxisRow(label: "Yaw", value: tester.gyro.y * 180 / .pi, range: 360, format: "%+.0f°/s")
				AxisRow(label: "Roll", value: tester.gyro.z * 180 / .pi, range: 360, format: "%+.0f°/s")
				AxisRow(label: "Accel X", value: tester.accel.x, range: 2, format: "%+.2f g")
				AxisRow(label: "Accel Y", value: tester.accel.y, range: 2, format: "%+.2f g")
				AxisRow(label: "Accel Z", value: tester.accel.z, range: 2, format: "%+.2f g")
			} header: {
				Text("Motion: \(tester.motionSource)")
			} footer: {
				Text("Held still and flat, the gyro should read near zero and Accel Y about +1 g.")
			}

			Section {
				Button("Rumble left (heavy motor)") { tester.rumble(left: 255, right: 0) }
				Button("Rumble right (light motor)") { tester.rumble(left: 0, right: 255) }
				Button("Rumble both") { tester.rumble(left: 255, right: 255) }
				Button("Haptics: low thud") { tester.haptics(hz: 60) }
				Button("Haptics: high buzz") { tester.haptics(hz: 300) }
			} header: {
				Text("Rumble and haptics: \(tester.rumbleOn)")
			} footer: {
				Text("Haptics play the kind of signal a PS5 game sends a DualSense. Controllers without motors, like a Backbone, play everything on the phone.")
			}

			Section {
				Picker("Effect", selection: Binding(get: { tester.triggerPreset }, set: { tester.setTriggers($0) })) {
					ForEach(ControllerTester.TriggerPreset.allCases) { Text($0.label).tag($0) }
				}
			} header: {
				Text("Adaptive triggers: \(tester.hasAdaptiveTriggers ? "DualSense" : "emulated")")
			} footer: {
				Text("Pull L2 or R2 to feel it. Resistance pushes back from a third of the way down, Weapon resists then gives way like a gun trigger, and Vibration buzzes. Without a DualSense, controllers with trigger motors (Xbox) or the phone play a click or buzz instead.")
			}

			Section {
				HStack(spacing: 12) {
					ForEach(Self.lightbarColors, id: \.name) { c in
						Button {
							tester.setLightbar(red: c.r, green: c.g, blue: c.b)
						} label: {
							Circle()
								.fill(Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255))
								.overlay(Circle().stroke(Color(.separator)))
								.frame(width: 32, height: 32)
						}
						.buttonStyle(.borderless)
						.accessibilityLabel(c.name)
					}
				}
				Picker("Player", selection: Binding(get: { tester.player ?? 0 }, set: { tester.setPlayer($0) })) {
					ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
				}
				.pickerStyle(.segmented)
			} header: {
				Text("Lightbar and player lights")
			} footer: {
				Text(tester.hasLight ? "Leaving this screen puts the lights back how they were." : "This controller has no lightbar iOS can change.")
			}
		}
		.navigationTitle("Controller Test")
		.navigationBarTitleDisplayMode(.inline)
		.onAppear {
			onActiveChange?(true)
			let orientation = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation
			tester.start(selectIsTouchpad: store.settings.selectIsTouchpad, orientation: orientation)
		}
		.onDisappear {
			tester.stop()
			onActiveChange?(false)
		}
	}

	private static func stick(_ x: Int16, _ y: Int16) -> String {
		String(format: "%+.2f, %+.2f", Double(x) / 32767, Double(-Int32(y)) / 32767)
	}

	private static func percent(_ v: UInt8) -> String {
		"\(Int((Double(v) / 255 * 100).rounded()))%"
	}
}

/// A bar from the centre for a signed value
private struct AxisRow: View {
	let label: String
	let value: Float
	let range: Float
	let format: String

	var body: some View {
		HStack(spacing: 12) {
			Text(label).frame(width: 64, alignment: .leading)
			GeometryReader { geo in
				let half = geo.size.width / 2
				let f = CGFloat(max(-1, min(1, value / range)))
				ZStack(alignment: .leading) {
					Capsule().fill(Color(.systemGray5))
					Rectangle().fill(Color.accentColor)
						.frame(width: abs(f) * half)
						.offset(x: f >= 0 ? half : half + f * half)
					Rectangle().fill(Color(.systemGray2)).frame(width: 1).offset(x: half)
				}
			}
			.frame(height: 8)
			Text(String(format: format, value))
				.monospacedDigit()
				.foregroundStyle(.secondary)
				.frame(width: 76, alignment: .trailing)
		}
		.font(.subheadline)
	}
}

/// A stand-in for the touchpad: two fingers, drag to move, quick tap to click
private struct TouchSquare: View {
	let onTouch: (ControllerInput.TouchEvent) -> Void
	let onTap: (Int) -> Void

	var body: some View {
		TouchSurface(onTouch: onTouch, onTap: onTap)
			.aspectRatio(1920.0 / 1080.0, contentMode: .fit)
			.background {
				RoundedRectangle(cornerRadius: 14, style: .continuous)
					.fill(Color(.tertiarySystemFill))
					.overlay {
						RoundedRectangle(cornerRadius: 14, style: .continuous)
							.strokeBorder(Color(.separator), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
					}
					.overlay {
						VStack(spacing: 4) {
							Image(systemName: "hand.tap")
							Text("Touch here like the touchpad")
						}
						.font(.footnote)
						.foregroundStyle(.secondary)
					}
			}
			.accessibilityLabel("Touchpad test area")
	}
}

/// Tracks up to two fingers the way the stream's touch handling does
private struct TouchSurface: UIViewRepresentable {
	let onTouch: (ControllerInput.TouchEvent) -> Void
	let onTap: (Int) -> Void

	func makeUIView(context: Context) -> View {
		let view = View()
		view.backgroundColor = .clear
		view.isMultipleTouchEnabled = true
		return view
	}

	func updateUIView(_ view: View, context: Context) {
		view.onTouch = onTouch
		view.onTap = onTap
	}

	final class View: UIView {
		var onTouch: ((ControllerInput.TouchEvent) -> Void)?
		var onTap: ((Int) -> Void)?

		// The stream's rules (MetalRenderer)
		private static let tapMaxDuration: TimeInterval = 0.25
		private static let tapMaxMovement: CGFloat = 12

		private struct Tracked {
			let slot: Int
			let start: CGPoint
			let time: TimeInterval
			var moved = false
		}

		private var tracked: [ObjectIdentifier: Tracked] = [:]
		/// The form scrolls: hold it still while a finger is down so swipes stay on the square
		private weak var scrollView: UIScrollView?
		private var scrollViewDelayed = true

		override func didMoveToWindow() {
			super.didMoveToWindow()
			if window != nil {
				var view = superview
				while let v = view, !(v is UIScrollView) { view = v.superview }
				scrollView = view as? UIScrollView
				if let scrollView {
					// Touches reach the square straight away, before the form can start scrolling
					scrollViewDelayed = scrollView.delaysContentTouches
					scrollView.delaysContentTouches = false
				}
			} else {
				scrollView?.delaysContentTouches = scrollViewDelayed
				scrollView?.isScrollEnabled = true
			}
		}

		private func holdScroll() {
			scrollView?.isScrollEnabled = tracked.isEmpty
		}

		private func point(_ p: CGPoint) -> (UInt16, UInt16) {
			guard bounds.width > 0, bounds.height > 0 else { return (0, 0) }
			let nx = min(max(p.x / bounds.width, 0), 1)
			let ny = min(max(p.y / bounds.height, 0), 1)
			return (UInt16((nx * 1919).rounded()), UInt16((ny * 1079).rounded()))
		}

		override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
			for touch in touches {
				let used = Set(tracked.values.map(\.slot))
				guard let slot = [10, 11].first(where: { !used.contains($0) }) else { continue }
				let p = touch.location(in: self)
				tracked[ObjectIdentifier(touch)] = Tracked(slot: slot, start: p, time: touch.timestamp)
				let (x, y) = point(p)
				onTouch?(.down(slot: slot, x: x, y: y))
			}
			holdScroll()
		}

		override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
			for touch in touches {
				let key = ObjectIdentifier(touch)
				guard var t = tracked[key] else { continue }
				let p = touch.location(in: self)
				if !t.moved, hypot(p.x - t.start.x, p.y - t.start.y) > Self.tapMaxMovement {
					t.moved = true
					tracked[key] = t
				}
				let (x, y) = point(p)
				onTouch?(.move(slot: t.slot, x: x, y: y))
			}
		}

		override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
			finish(touches, allowsTap: true)
		}

		override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
			finish(touches, allowsTap: false)
		}

		private func finish(_ touches: Set<UITouch>, allowsTap: Bool) {
			for touch in touches {
				guard let t = tracked.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
				let p = touch.location(in: self)
				if allowsTap, !t.moved, hypot(p.x - t.start.x, p.y - t.start.y) <= Self.tapMaxMovement,
				   touch.timestamp - t.time <= Self.tapMaxDuration {
					onTap?(t.slot)
				} else {
					onTouch?(.up(slot: t.slot))
				}
			}
			holdScroll()
		}
	}
}
