import ChiakiKit
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

	/// Rumble, haptics, adaptive triggers, lightbar and player LEDs
	let feedback = ControllerFeedback()

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
		feedback.detach()
		feedback.reset()
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
		feedback.attach(next)
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
		feedback.triggersMoved(left: pad.leftTrigger.value, right: pad.rightTrigger.value)
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
}
