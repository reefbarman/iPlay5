import ChiakiKit
import GameController
import os
import simd
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


	private(set) var pad = CKPadState()
	private(set) var controllerName: String?
	private(set) var motionSource = "Phone gyro"
	private(set) var hasAdaptiveTriggers = false
	private(set) var hasLight = false
	private(set) var rumbleOn = "Phone"
	/// rad/s and g, in DualSense axes
	private(set) var gyro = SIMD3<Float>.zero
	private(set) var accel = SIMD3<Float>.zero
	/// Set when the accelerometer turned out to use different axes from the gyro: which accelerometer
	/// axes line up with the gyro's x, y and z
	private(set) var gravityAxes: String?
	/// How the controller has turned since it was levelled, in the 3D model's axes
	/// (x right, y towards the triggers, z out of the face)
	private(set) var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
	/// The controller's own touchpad fingers, 0...1 across and down
	private(set) var touches: [CGPoint?] = [nil, nil]
	/// Fingers on the on-screen touch square, by slot, 0...1 across and down
	private(set) var screenTouches: [Int: CGPoint] = [:]
	/// A tap on the touch square, which the stream turns into a touchpad click
	private(set) var screenClick = false
	private(set) var buzz: Buzz?
	private(set) var triggerPreset = TriggerPreset.off
	private(set) var lightbar: CGColor?
	private(set) var player: Int?

	var touchpadClicked: Bool { isPressed(CK_BUTTON_TOUCHPAD) || screenClick }

	/// Which way is up, seen from the controller, when it's held naturally: face tipped towards
	/// you, about 40° from flat (DualSense axes). Recentre replaces it with how you hold yours.
	static let defaultNaturalUp = SIMD3<Float>(0, cos(40 * .pi / 180), -sin(40 * .pi / 180))
	private static let naturalUpKey = "ControllerTest.naturalUp"

	/// Attitude from the gyro, in DualSense axes: x right, y out of the face, z towards the player.
	/// - Gravity keeps the tilt honest (a Mahony filter).
	/// - Turning left and right has nothing to check it against, so it eases back to facing
	///   front over a few seconds rather than building up.
	/// - The gyro's small reading at rest is measured while the controller sits still and taken off.
	/// - Front-on is the natural hold (`naturalUp`), whichever way the controller faced at the start.
	/// - Controllers don't all report gravity on the same axes as their gyro (and a mismatch stops
	///   gravity levelling anything), so it works out which axes match from how the controller turns.
	private struct Motion {
		var naturalUp: SIMD3<Float>
		/// Index into `axisTurns` that puts the accelerometer into the gyro's axes
		var axes = Motion.identityAxes
		var gyro = SIMD3<Float>.zero
		var accel = SIMD3<Float>(0, 1, 0)
		/// Controller to world; the world is how the controller sat at the first sample
		var attitude = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
		/// Which way is up in that world
		var up: SIMD3<Float>?
		/// The attitude shown front-on
		var level = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
		/// Seconds until front-on is set, nil once done
		var levelIn: Float? = 0.5
		/// What the gyro reads at rest
		var bias = SIMD3<Float>.zero
		/// Recent averages, to tell when the controller is sitting still
		var gyroMean: SIMD3<Float>?
		var accelMean = SIMD3<Float>.zero
		var stillFor: Float = 0
		var lastTimestamp: UInt32?
		var scheduled = false

		// Matching the accelerometer's axes to the gyro's: where gravity should be by now, for
		// each way the axes could line up, turned along with the gyro and checked every quarter second
		var predicted: [SIMD3<Float>]?
		var windowLeft: Float = 0.25
		var turnedInWindow: Float = 0
		var mismatch = [Float](repeating: 0, count: Motion.axisTurns.count)
		var checks = 0

		/// The 24 ways to line up three axes (each axis swapped with another and/or flipped, without mirroring)
		static let axisTurns: [simd_float3x3] = {
			var turns: [simd_float3x3] = []
			for p in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
				for signs in [[1, 1, 1], [1, 1, -1], [1, -1, 1], [1, -1, -1], [-1, 1, 1], [-1, 1, -1], [-1, -1, 1], [-1, -1, -1]] {
					var m = simd_float3x3(0)
					// Output axis i is input axis p[i], times signs[i] (columns are inputs)
					for i in 0..<3 { m[p[i]][i] = Float(signs[i]) }
					if simd_determinant(m) > 0 { turns.append(m) }
				}
			}
			return turns
		}()
		static let identityAxes = axisTurns.firstIndex(of: matrix_identity_float3x3) ?? 0

		/// How the axes are matched up, for showing: where the gyro's x, y and z come from
		var axesDescription: String? {
			guard axes != Self.identityAxes else { return nil }
			let m = Self.axisTurns[axes]
			return (0..<3).map { i in
				let from = (0..<3).first { m[$0][i] != 0 } ?? i
				return (m[from][i] < 0 ? "−" : "+") + ["X", "Y", "Z"][from]
			}.joined(separator: " ")
		}

		mutating func add(gyro: SIMD3<Float>, accel rawAccel: SIMD3<Float>, timestamp: UInt32) {
			self.gyro = gyro
			self.accel = rawAccel
			defer { lastTimestamp = timestamp }
			let accel = Self.axisTurns[axes] * rawAccel
			let g = simd_length(accel)
			if up == nil {
				guard g > 0.5 else { return }
				up = accel / g
			}
			guard let last = lastTimestamp, up != nil else { return }
			let dt = min(0.05, Float(timestamp &- last) / 1_000_000)
			guard dt > 0 else { return }
			let axesBefore = axes
			matchAxes(rawAccel, rate: gyro - bias, dt: dt)
			// Just rematched: carry on in the new axes from the next reading
			guard axes == axesBefore, let up else { return }

			let k = min(1, dt / 0.2)
			if let mean = gyroMean {
				let steady = simd_length(gyro - mean) < 0.02 && simd_length(accel - accelMean) < 0.02
					// A slow turn isn't the resting reading
					&& simd_length(mean - bias) < 0.05
				stillFor = steady ? stillFor + dt : 0
				gyroMean = mean + (gyro - mean) * k
				accelMean += (accel - accelMean) * k
			} else {
				gyroMean = gyro
				accelMean = accel
			}
			if stillFor > 0.5, let mean = gyroMean {
				bias += (mean - bias) * min(1, dt / 2)
			}

			var w = gyro - bias
			if g > 0.85 && g < 1.15 {
				w += 2 * simd_cross(accel / g, attitude.inverse.act(up))
			}
			let rate = simd_length(w)
			if rate > 0 {
				attitude = simd_normalize(attitude * simd_quatf(angle: rate * dt, axis: w / rate))
			}

			if let wait = levelIn {
				levelIn = wait - dt > 0 ? wait - dt : nil
				if levelIn == nil {
					// Held: that's the natural hold. Resting on something: assume the usual one.
					setLevel(natural: stillFor > 0.3 ? naturalUp : attitude.inverse.act(up))
				}
			} else {
				// Ease the heading back to front-on, measured by where the right-hand side points
				let side = SIMD3<Float>(1, 0, 0)
				let was = level.act(side) - simd_dot(level.act(side), up) * up
				let now = attitude.act(side) - simd_dot(attitude.act(side), up) * up
				if simd_length(was) > 0.3, simd_length(now) > 0.3 {
					let turned = atan2(simd_dot(simd_cross(was, now), up), simd_dot(was, now))
					attitude = simd_normalize(simd_quatf(angle: -turned * min(1, dt / 3), axis: up) * attitude)
				}
			}
		}

		/// Turns each candidate gravity with the gyro, and every quarter second scores how far
		/// each ended up from what the accelerometer then reads. The right axes stay close.
		mutating func matchAxes(_ rawAccel: SIMD3<Float>, rate w: SIMD3<Float>, dt: Float) {
			let g = simd_length(rawAccel)
			// Swinging it about adds acceleration that isn't gravity: start the window again
			guard g > 0.75 && g < 1.25 else {
				predicted = nil
				return
			}
			let measured = Self.axisTurns.map { simd_normalize($0 * rawAccel) }
			guard var p = predicted else {
				predicted = measured
				windowLeft = 0.25
				turnedInWindow = 0
				return
			}
			for i in p.indices { p[i] = simd_normalize(p[i] + simd_cross(p[i], w) * dt) }
			predicted = p
			turnedInWindow += simd_length(w) * dt
			windowLeft -= dt
			guard windowLeft <= 0 else { return }
			// Only turning tells the candidates apart
			if turnedInWindow > 0.25 {
				for i in mismatch.indices {
					mismatch[i] = mismatch[i] * 0.85 + simd_length_squared(measured[i] - p[i])
				}
				checks += 1
				let best = mismatch.indices.min { mismatch[$0] < mismatch[$1] } ?? axes
				if checks >= 4, best != axes, mismatch[best] < 0.35 * mismatch[axes] {
					axes = best
					// Start over in the new axes, front-on at the natural hold
					let a = Self.axisTurns[axes] * rawAccel
					attitude = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
					up = simd_normalize(a)
					setLevel(natural: naturalUp)
				}
			}
			predicted = measured
			windowLeft = 0.25
			turnedInWindow = 0
		}

		/// Front-on is the attitude now, tipped so that holding the controller with `natural`
		/// pointing up shows square to the screen
		mutating func setLevel(natural: SIMD3<Float>) {
			guard let up else {
				level = attitude
				return
			}
			let upNow = attitude.inverse.act(up)
			level = attitude * simd_quatf(from: simd_normalize(natural), to: upNow)
		}

		/// The way it's held now becomes the natural hold
		mutating func recentre() -> SIMD3<Float>? {
			levelIn = nil
			guard let up else {
				level = attitude
				return nil
			}
			naturalUp = attitude.inverse.act(up)
			level = attitude
			return naturalUp
		}

		/// The turn since levelling, moved into the 3D model's axes
		var shown: simd_quatf {
			let q = level.inverse * attitude
			// DualSense (x, y, z) is the model's (x, -z, y) turned: z towards the player is down the model
			return simd_quatf(ix: q.imag.x, iy: -q.imag.z, iz: q.imag.y, r: q.real)
		}
	}

	@ObservationIgnored private let input = ControllerInput()
	/// Motion arrives faster than the screen updates: the latest values and turning,
	/// updated on the motion thread and read once per hop to main
	@ObservationIgnored private let motion = OSAllocatedUnfairLock(initialState: Motion(naturalUp: ControllerTester.savedNaturalUp))

	private static var savedNaturalUp: SIMD3<Float> {
		guard let v = UserDefaults.standard.array(forKey: naturalUpKey) as? [Float], v.count == 3 else { return defaultNaturalUp }
		let up = SIMD3(v[0], v[1], v[2])
		return simd_length(up) > 0.5 ? simd_normalize(up) : defaultNaturalUp
	}
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
				m.add(gyro: gyro, accel: accel, timestamp: timestamp)
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
		// A different controller (or the phone) starts over, level with however it's held,
		// with the axes matched last time
		let axes = UserDefaults.standard.object(forKey: axesKey) as? Int
		motion.withLock { m in
			m = Motion(naturalUp: m.naturalUp)
			if let axes, Motion.axisTurns.indices.contains(axes) { m.axes = axes }
		}
		gravityAxes = nil
		orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
	}

	private var axesKey: String { "ControllerTest.gravityAxes.\(controllerName ?? "Phone")" }

	// MARK: - Motion

	private func motionChanged() {
		let m = motion.withLock { m in
			m.scheduled = false
			return m
		}
		gyro = m.gyro
		accel = m.accel
		orientation = m.shown
		let description = m.axesDescription
		if description != gravityAxes {
			gravityAxes = description
			UserDefaults.standard.set(m.axes, forKey: axesKey)
		}
	}

	/// Shows the way the controller is held now front-on, and remembers it as the natural hold
	func recentre() {
		let natural = motion.withLock { $0.recentre() }
		if let natural {
			UserDefaults.standard.set([natural.x, natural.y, natural.z], forKey: Self.naturalUpKey)
		}
		orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
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
		lightbar = red == 0 && green == 0 && blue == 0
			? nil : CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
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

	private static let controls: [(CKButton, ControllerScene.Control)] = [
		(CK_BUTTON_CROSS, .cross), (CK_BUTTON_MOON, .circle), (CK_BUTTON_BOX, .square), (CK_BUTTON_PYRAMID, .triangle),
		(CK_BUTTON_DPAD_UP, .up), (CK_BUTTON_DPAD_DOWN, .down), (CK_BUTTON_DPAD_LEFT, .left), (CK_BUTTON_DPAD_RIGHT, .right),
		(CK_BUTTON_L1, .l1), (CK_BUTTON_R1, .r1), (CK_BUTTON_L3, .l3), (CK_BUTTON_R3, .r3),
		(CK_BUTTON_SHARE, .create), (CK_BUTTON_OPTIONS, .options), (CK_BUTTON_PS, .ps),
	]

	/// What the 3D controller shows
	private var sceneState: ControllerScene.State {
		var s = ControllerScene.State()
		s.pressed = Set(Self.controls.filter { tester.isPressed($0.0) }.map(\.1))
		if tester.touchpadClicked { s.pressed.insert(.touchpad) }
		let pad = tester.pad
		s.leftStick = SIMD2(Float(pad.left_x) / 32767, Float(pad.left_y) / 32767)
		s.rightStick = SIMD2(Float(pad.right_x) / 32767, Float(pad.right_y) / 32767)
		s.l2 = Float(pad.l2) / 255
		s.r2 = Float(pad.r2) / 255
		s.orientation = tester.orientation
		s.touches = tester.touches.compactMap { $0 }.map { .init(x: Float($0.x), y: Float($0.y), fromScreen: false) }
			+ tester.screenTouches.sorted { $0.key < $1.key }.map { .init(x: Float($0.value.x), y: Float($0.value.y), fromScreen: true) }
		s.lightbar = tester.lightbar
		s.player = tester.player
		s.triggerLook = switch tester.triggerPreset {
		case .off: .off
		case .resistance: .resistance
		case .weapon: .weapon
		case .vibration: .vibration
		}
		s.buzz = tester.buzz.map { .init(left: $0.left, right: $0.right, hz: $0.shakeHz) }
		return s
	}

	var body: some View {
		GeometryReader { geo in
			let landscape = geo.size.width > geo.size.height
			VStack(spacing: 0) {
				live
					.frame(height: landscape ? geo.size.height * 0.6 : min(geo.size.height * 0.5, geo.size.width / 1.3))
				form
			}
		}
		.background(Color(.systemGroupedBackground))
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

	/// The 3D controller, kept on screen above the list
	private var live: some View {
		ControllerSceneView(
			state: sceneState,
			onTouch: { tester.screenTouch($0) },
			onTap: { tester.screenTap(slot: $0) })
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.overlay(alignment: .bottomTrailing) {
				Button("Recentre", systemImage: "scope") { tester.recentre() }
					.buttonStyle(.bordered)
					.controlSize(.small)
					.padding(12)
					.accessibilityHint("Hold the controller the way you normally do, then tap to show it front-on")
			}
	}

	private var form: some View {
		Form {
			Section {
				LabeledContent("Pressed", value: pressedText)
				LabeledContent("Touchpad", value: touchText)
				LabeledContent("Left stick", value: Self.stick(tester.pad.left_x, tester.pad.left_y))
				LabeledContent("Right stick", value: Self.stick(tester.pad.right_x, tester.pad.right_y))
				LabeledContent("L2 / R2", value: "\(Self.percent(tester.pad.l2)) / \(Self.percent(tester.pad.r2))")
			} header: {
				Text(tester.controllerName ?? "No controller")
			} footer: {
				Text("Buttons show as the PS5 sees them, mapped by position (the bottom face button is Cross). Select shows as Create, or Touchpad if Select button is touchpad click is on.")
				Text("Touch the touchpad on screen to test touching the stream: drag to move a finger on it, tap to click it. Fingers on the controller's own touchpad show in orange.")
				Text("The controller turns as you turn yours. Hold it the way you normally do and tap Recentre to show that front-on; it's remembered for next time.")
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
				if let axes = tester.gravityAxes {
					Text("This controller reports gravity on different axes from its gyro. Matched up by how it turns: \(axes).")
				}
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
	}

	private static func stick(_ x: Int16, _ y: Int16) -> String {
		String(format: "%+.2f, %+.2f", Double(x) / 32767, Double(-Int32(y)) / 32767)
	}

	private static func percent(_ v: UInt8) -> String {
		"\(Int((Double(v) / 255 * 100).rounded()))%"
	}
}

/// A settings row that opens the Controller Test over the whole screen, so dragging on its
/// touch square can't pull the settings sheet around
struct ControllerTestLink<Content: View>: View {
	var onActiveChange: ((Bool) -> Void)?
	@ViewBuilder var label: Content
	@State private var open = false

	var body: some View {
		Button { open = true } label: {
			HStack {
				label
				Spacer()
				Image(systemName: "chevron.right")
					.font(.footnote.weight(.semibold))
					.foregroundStyle(.tertiary)
			}
			.contentShape(Rectangle())
		}
		.foregroundStyle(.primary)
		.fullScreenCover(isPresented: $open) {
			NavigationStack {
				ControllerTestView(onActiveChange: onActiveChange)
					.toolbar {
						ToolbarItem(placement: .confirmationAction) {
							Button("Done") { open = false }
						}
					}
			}
		}
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
