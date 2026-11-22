import ChiakiKit
import CoreHaptics
import CoreMotion
import GameController
import UIKit

/// Maps the connected game controller to chiaki's DualSense state.
///
/// - Buttons are mapped by position (A/bottom = Cross, B/right = Circle, ...).
/// - The Home/PS button and the other system buttons are claimed from iOS so
///   pressing PS opens the PS5 menu instead of the iOS overlay.
/// - Motion comes from the controller if it has sensors (DualSense), otherwise
///   from the phone (e.g. clamped in a GameSir G8+).
final class ControllerInput {
	/// Called on the main thread with the latest pad state.
	var onPad: ((CKPadState) -> Void)?
	/// gyro rad/s, accel g, DualSense axes, monotonic microseconds.
	var onMotion: ((SIMD3<Float>, SIMD3<Float>, UInt32) -> Void)?
	var onTouch: ((TouchEvent) -> Void)?
	/// Select + Start held for a second
	var onMenuCombo: (() -> Void)?

	enum TouchEvent {
		case down(slot: Int, x: UInt16, y: UInt16)
		case move(slot: Int, x: UInt16, y: UInt16)
		case up(slot: Int)
	}

	var selectIsTouchpad = false
	var phoneMotionEnabled = true

	private(set) var controllerName: String?
	private var controller: GCController?
	private let motionManager = CMMotionManager()
	private let motionQueue = OperationQueue()
	private var observers: [NSObjectProtocol] = []
	private var touchDown = [false, false]
	private var comboTimer: Timer?
	private var lastPad = CKPadState()

	let rumble = RumbleOutput()

	init() {
		motionQueue.maxConcurrentOperationCount = 1
		motionQueue.qualityOfService = .userInteractive
	}

	func start() {
		GCController.shouldMonitorBackgroundEvents = false
		observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
			self?.pickController()
		})
		observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
			self?.pickController()
		})
		pickController()
	}

	func stop() {
		observers.forEach(NotificationCenter.default.removeObserver)
		observers.removeAll()
		comboTimer?.invalidate()
		comboTimer = nil
		motionManager.stopDeviceMotionUpdates()
		if let controller {
			restoreSystemGestures(controller)
			controller.extendedGamepad?.valueChangedHandler = nil
			controller.motion?.valueChangedHandler = nil
			controller.motion?.sensorsActive = false
		}
		controller = nil
		controllerName = nil
		lastPad = CKPadState()
		releaseTouchpad()
		rumble.detach()
	}

	// MARK: - Controller selection

	private static var candidates: [GCController] {
		GCController.controllers().filter { $0.extendedGamepad != nil }
	}

	static var hasSupportedController: Bool { !candidates.isEmpty }

	private func pickController() {
		let candidates = Self.candidates
		let next = GCController.current.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates.first
		guard next !== controller else {
			if next == nil { startPhoneMotion() }
			return
		}

		if let controller {
			restoreSystemGestures(controller)
			controller.extendedGamepad?.valueChangedHandler = nil
			controller.motion?.valueChangedHandler = nil
			controller.motion?.sensorsActive = false
			updateMenuCombo(select: false, start: false)
			releaseTouchpad()
		}
		controller = next
		controllerName = next?.vendorName
		rumble.attach(next)
		guard let next, let pad = next.extendedGamepad else {
			lastPad = CKPadState()
			onPad?(lastPad)
			startPhoneMotion()
			return
		}
		log.notice("Using controller: \(next.vendorName ?? "?", privacy: .public) (\(next.productCategory, privacy: .public))")

		claimSystemGestures(next)
		pad.valueChangedHandler = { [weak self] pad, _ in
			guard let self, self.controller?.extendedGamepad === pad else { return }
			self.padChanged(pad)
		}

		if let motion = next.motion, motion.hasRotationRate {
			motionManager.stopDeviceMotionUpdates()
			motion.sensorsActive = true
			motion.valueChangedHandler = { [weak self] motion in self?.controllerMotion(motion) }
		} else {
			startPhoneMotion()
		}
		padChanged(pad)
	}

	private func claimSystemGestures(_ controller: GCController) {
		for button in controller.physicalInputProfile.buttons.values {
			button.preferredSystemGestureState = .disabled
		}
	}

	private func restoreSystemGestures(_ controller: GCController) {
		for button in controller.physicalInputProfile.buttons.values {
			button.preferredSystemGestureState = .enabled
		}
	}

	// MARK: - Buttons and sticks

	private func padChanged(_ pad: GCExtendedGamepad) {
		var b: UInt32 = 0
		func set(_ pressed: Bool, _ flag: CKButton) { if pressed { b |= flag.rawValue } }

		set(pad.buttonA.isPressed, CK_BUTTON_CROSS)
		set(pad.buttonB.isPressed, CK_BUTTON_MOON)
		set(pad.buttonX.isPressed, CK_BUTTON_BOX)
		set(pad.buttonY.isPressed, CK_BUTTON_PYRAMID)
		set(pad.dpad.left.isPressed, CK_BUTTON_DPAD_LEFT)
		set(pad.dpad.right.isPressed, CK_BUTTON_DPAD_RIGHT)
		set(pad.dpad.up.isPressed, CK_BUTTON_DPAD_UP)
		set(pad.dpad.down.isPressed, CK_BUTTON_DPAD_DOWN)
		set(pad.leftShoulder.isPressed, CK_BUTTON_L1)
		set(pad.rightShoulder.isPressed, CK_BUTTON_R1)
		set(pad.leftThumbstickButton?.isPressed ?? false, CK_BUTTON_L3)
		set(pad.rightThumbstickButton?.isPressed ?? false, CK_BUTTON_R3)
		set(pad.buttonMenu.isPressed, CK_BUTTON_OPTIONS)
		set(pad.buttonHome?.isPressed ?? false, CK_BUTTON_PS)

		let selectPressed = pad.buttonOptions?.isPressed ?? false
		if let ds = pad as? GCDualSenseGamepad {
			set(selectPressed, CK_BUTTON_SHARE)
			set(ds.touchpadButton.isPressed, CK_BUTTON_TOUCHPAD)
			dualSenseTouch(ds)
		} else {
			set(selectPressed, selectIsTouchpad ? CK_BUTTON_TOUCHPAD : CK_BUTTON_SHARE)
		}

		var state = CKPadState()
		state.buttons = b
		state.l2 = UInt8(clamping: Int((pad.leftTrigger.value * 255).rounded()))
		state.r2 = UInt8(clamping: Int((pad.rightTrigger.value * 255).rounded()))
		state.left_x = Self.axis(pad.leftThumbstick.xAxis.value)
		state.left_y = Self.axis(-pad.leftThumbstick.yAxis.value)
		state.right_x = Self.axis(pad.rightThumbstick.xAxis.value)
		state.right_y = Self.axis(-pad.rightThumbstick.yAxis.value)

		lastPad = state
		onPad?(state)
		updateMenuCombo(select: selectPressed, start: pad.buttonMenu.isPressed)
	}

	private static func axis(_ v: Float) -> Int16 {
		Int16(clamping: Int((v * 32767).rounded()))
	}

	private func updateMenuCombo(select: Bool, start: Bool) {
		if select && start {
			guard comboTimer == nil else { return }
			comboTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
				self?.comboTimer = nil
				self?.onMenuCombo?()
			}
		} else {
			comboTimer?.invalidate()
			comboTimer = nil
		}
	}

	// MARK: - DualSense touchpad

	private func releaseTouchpad() {
		for slot in touchDown.indices where touchDown[slot] {
			touchDown[slot] = false
			onTouch?(.up(slot: slot))
		}
	}

	private func dualSenseTouch(_ ds: GCDualSenseGamepad) {
		for (slot, pad) in [ds.touchpadPrimary, ds.touchpadSecondary].enumerated() {
			let x = pad.xAxis.value
			let y = pad.yAxis.value
			let touching = x != 0 || y != 0
			let px = UInt16(clamping: Int(((x + 1) / 2 * 1919).rounded()))
			let py = UInt16(clamping: Int(((1 - y) / 2 * 1079).rounded()))
			if touching && !touchDown[slot] {
				touchDown[slot] = true
				onTouch?(.down(slot: slot, x: px, y: py))
			} else if touching {
				onTouch?(.move(slot: slot, x: px, y: py))
			} else if touchDown[slot] {
				touchDown[slot] = false
				onTouch?(.up(slot: slot))
			}
		}
	}

	// MARK: - Motion

	private func controllerMotion(_ motion: GCMotion) {
		// GameController reports DualSense motion in its own frame; untested
		// against real games, so treat as a starting point.
		let r = motion.rotationRate
		let g = motion.gravity
		let u = motion.userAcceleration
		let gyro = SIMD3<Float>(Float(r.x), Float(r.y), Float(r.z))
		let accel = -SIMD3<Float>(Float(g.x + u.x), Float(g.y + u.y), Float(g.z + u.z))
		onMotion?(gyro, accel, Self.nowMicros())
	}

	private func startPhoneMotion() {
		guard phoneMotionEnabled, motionManager.isDeviceMotionAvailable else { return }
		guard !motionManager.isDeviceMotionActive else { return }
		motionManager.deviceMotionUpdateInterval = 1.0 / 100.0
		motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] data, _ in
			guard let self, let data else { return }
			self.phoneMotion(data)
		}
	}

	/// Interface orientation, cached on the main thread for the motion queue.
	var interfaceOrientation: UIInterfaceOrientation = .landscapeRight

	private func phoneMotion(_ m: CMDeviceMotion) {
		// Device axes: x right / y up in portrait, z out of the screen.
		// Map to the screen as held in landscape, which lines up with how a
		// DualSense's axes behave when the phone is upright in a clamp controller.
		let r = m.rotationRate
		let a = (x: m.gravity.x + m.userAcceleration.x, y: m.gravity.y + m.userAcceleration.y, z: m.gravity.z + m.userAcceleration.z)
		let gyro: SIMD3<Float>
		let accel: SIMD3<Float>
		switch interfaceOrientation {
		case .landscapeLeft:  // device top on the right
			gyro = SIMD3(Float(r.y), Float(-r.x), Float(r.z))
			accel = SIMD3(Float(a.y), Float(-a.x), Float(a.z))
		default:  // landscapeRight: device top on the left
			gyro = SIMD3(Float(-r.y), Float(r.x), Float(r.z))
			accel = SIMD3(Float(-a.y), Float(a.x), Float(a.z))
		}
		// CoreMotion reports gravity's direction; DualSense reports the reaction (+1 g up at rest)
		onMotion?(gyro, -accel, UInt32(truncatingIfNeeded: UInt64(m.timestamp * 1_000_000)))
	}

	private static func nowMicros() -> UInt32 {
		UInt32(truncatingIfNeeded: UInt64(CACurrentMediaTime() * 1_000_000))
	}

	// MARK: - Adaptive triggers

	/// Applies a PS5 trigger effect to a DualSense. Decodes the common effect
	/// types approximately; anything unrecognised turns the trigger off.
	func applyTriggerEffect(typeLeft: UInt8, left: [UInt8], typeRight: UInt8, right: [UInt8]) {
		guard let ds = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
		Self.apply(type: typeLeft, data: left, to: ds.leftTrigger)
		Self.apply(type: typeRight, data: right, to: ds.rightTrigger)
	}

	private static func apply(type: UInt8, data d: [UInt8], to trigger: GCDualSenseAdaptiveTrigger) {
		guard d.count >= 10 else { return }
		func zones() -> [Int] {
			let mask = Int(d[0]) | Int(d[1]) << 8
			return (0..<10).filter { mask & (1 << $0) != 0 }
		}
		func strengths() -> [Float] {
			let packed = UInt64(d[2]) | UInt64(d[3]) << 8 | UInt64(d[4]) << 16 | UInt64(d[5]) << 24
			return (0..<10).map { Float((packed >> (3 * UInt64($0))) & 0x7) }
		}
		switch type {
		case 0x21:  // feedback (per-zone resistance)
			let z = zones()
			guard let first = z.first else { return trigger.setModeOff() }
			let s = strengths()
			let avg = z.map { s[$0] + 1 }.reduce(0, +) / Float(z.count) / 8
			trigger.setModeFeedbackWithStartPosition(Float(first) / 9, resistiveStrength: avg)
		case 0x25:  // weapon (resistance that breaks at a point)
			let z = zones()
			guard z.count >= 2 else { return trigger.setModeOff() }
			trigger.setModeWeaponWithStartPosition(Float(z[0]) / 9, endPosition: Float(z[z.count - 1]) / 9, resistiveStrength: (Float(d[2]) + 1) / 8)
		case 0x26:  // vibration
			let z = zones()
			guard let first = z.first else { return trigger.setModeOff() }
			let s = strengths()
			let amp = z.map { s[$0] + 1 }.reduce(0, +) / Float(z.count) / 8
			trigger.setModeVibrationWithStartPosition(Float(first) / 9, amplitude: amp, frequency: Float(d[8]) / 255)
		case 0x01:  // legacy continuous resistance
			trigger.setModeFeedbackWithStartPosition(Float(d[0]) / 255, resistiveStrength: Float(d[1]) / 255)
		case 0x02:  // legacy section resistance
			trigger.setModeWeaponWithStartPosition(Float(d[0]) / 255, endPosition: Float(d[1]) / 255, resistiveStrength: 1)
		case 0x06:  // legacy vibration
			trigger.setModeVibrationWithStartPosition(Float(d[2]) / 255, amplitude: Float(d[1]) / 255, frequency: Float(d[0]) / 255)
		default:
			trigger.setModeOff()
		}
	}
}

/// Rumble through the controller's haptic motors (if it has any).
///
/// Uses one continuous haptic player per side and changes its intensity as
/// PS5 rumble values arrive, which is cheaper than scheduling new patterns.
final class RumbleOutput {
	private var engines: [CHHapticEngine] = []
	private var players: [CHHapticAdvancedPatternPlayer] = []
	var enabled = true

	func attach(_ controller: GCController?) {
		detach()
		guard let haptics = controller?.haptics else { return }
		let localities: [GCHapticsLocality] =
			haptics.supportedLocalities.contains(.leftHandle) && haptics.supportedLocalities.contains(.rightHandle)
			? [.leftHandle, .rightHandle] : [.default]
		for locality in localities {
			guard let engine = haptics.createEngine(withLocality: locality) else { continue }
			do {
				try engine.start()
				let event = CHHapticEvent(
					eventType: .hapticContinuous,
					parameters: [
						CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
						CHHapticEventParameter(parameterID: .hapticSharpness, value: locality == .rightHandle ? 0.8 : 0.3),
					], relativeTime: 0, duration: 30)
				let pattern = try CHHapticPattern(events: [event], parameters: [])
				let player = try engine.makeAdvancedPlayer(with: pattern)
				player.loopEnabled = true
				try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0, relativeTime: 0)], atTime: CHHapticTimeImmediate)
				try player.start(atTime: CHHapticTimeImmediate)
				engines.append(engine)
				players.append(player)
			} catch {
				log.error("Haptics: \(error.localizedDescription, privacy: .public)")
			}
		}
	}

	func detach() {
		players.forEach { try? $0.stop(atTime: CHHapticTimeImmediate) }
		engines.forEach { $0.stop() }
		players = []
		engines = []
	}

	/// left = low frequency (heavy) motor, right = high frequency (light) motor, 0...255.
	func set(left: UInt8, right: UInt8) {
		guard enabled, !players.isEmpty else { return }
		let l = Float(left) / 255
		let r = Float(right) / 255
		let values = players.count == 2 ? [l, r] : [max(l, r)]
		for (player, value) in zip(players, values) {
			try? player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: value, relativeTime: 0)], atTime: CHHapticTimeImmediate)
		}
	}
}
