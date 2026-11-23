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

	private(set) var pad = CKPadState()
	private(set) var controllerName: String?
	private(set) var motionSource = "Phone gyro"
	private(set) var hasAdaptiveTriggers = false
	private(set) var hasLight = false
	private(set) var rumbleOn = "Phone"
	/// rad/s and g, in DualSense axes
	private(set) var gyro = SIMD3<Float>.zero
	private(set) var accel = SIMD3<Float>.zero
	/// Touchpad fingers, 0...1 across and down
	private(set) var touches: [CGPoint?] = [nil, nil]

	@ObservationIgnored private let input = ControllerInput()
	/// Motion arrives faster than the screen updates: keep the latest and update once per hop to main
	@ObservationIgnored private let pendingMotion = OSAllocatedUnfairLock<(SIMD3<Float>, SIMD3<Float>)?>(initialState: nil)
	@ObservationIgnored private weak var lastController: GCController?
	@ObservationIgnored private var running = false
	@ObservationIgnored private var hapticsTimer: Timer?
	@ObservationIgnored private var rumbleStop: DispatchWorkItem?

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
		input.onMotion = { [weak self] gyro, accel, _ in
			guard let self else { return }
			let schedule = self.pendingMotion.withLock { pending in
				defer { pending = (gyro, accel) }
				return pending == nil
			}
			guard schedule else { return }
			DispatchQueue.main.async { [weak self] in
				guard let self, let (gyro, accel) = self.pendingMotion.withLock({ pending in
					defer { pending = nil }
					return pending
				}) else { return }
				self.gyro = gyro
				self.accel = accel
			}
		}
		input.start()
		refreshController()
	}

	func stop() {
		guard running else { return }
		running = false
		stopBuzz()
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

	// MARK: - Feedback

	/// Classic rumble for a moment: left is the heavy motor, right the light one
	func rumble(left: UInt8, right: UInt8) {
		stopBuzz()
		input.feedback.rumble(left: left, right: right)
		let stop = DispatchWorkItem { [weak self] in self?.input.feedback.rumble(left: 0, right: 0) }
		rumbleStop = stop
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: stop)
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
	}

	private func stopBuzz() {
		rumbleStop?.cancel()
		rumbleStop = nil
		hapticsTimer?.invalidate()
		hapticsTimer = nil
		input.feedback.rumble(left: 0, right: 0)
	}

	func setTriggers(_ preset: TriggerPreset) {
		input.feedback.setTriggerEffects(left: preset.effect, right: preset.effect)
	}

	func setLightbar(red: UInt8, green: UInt8, blue: UInt8) {
		input.feedback.padInfo(CK_PAD_INFO_LIGHTBAR, red, green, blue)
	}

	func setPlayer(_ number: Int) {
		input.feedback.padInfo(CK_PAD_INFO_PLAYER, UInt8(number), 0, 0)
	}
}

struct ControllerTestView: View {
	/// Set when opened during a stream: true on open so the stream lets go of the controller, false on close
	var onActiveChange: ((Bool) -> Void)?

	@Environment(SettingsStore.self) private var store
	@State private var tester = ControllerTester()
	@State private var triggerPreset = ControllerTester.TriggerPreset.off
	@State private var player = 1

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
		if tester.pad.l2 > 0 { names.append("L2") }
		if tester.pad.r2 > 0 { names.append("R2") }
		return names.isEmpty ? "None" : names.joined(separator: ", ")
	}

	var body: some View {
		Form {
			Section {
				ControllerDiagram(tester: tester)
					.padding(.vertical, 8)
				LabeledContent("Pressed", value: pressedText)
				LabeledContent("Left stick", value: Self.stick(tester.pad.left_x, tester.pad.left_y))
				LabeledContent("Right stick", value: Self.stick(tester.pad.right_x, tester.pad.right_y))
				LabeledContent("L2 / R2", value: "\(Self.percent(tester.pad.l2)) / \(Self.percent(tester.pad.r2))")
			} header: {
				Text(tester.controllerName ?? "No controller")
			} footer: {
				Text("Buttons show as the PS5 sees them, mapped by position (the bottom face button is Cross). Select shows as Create, or Touchpad if Select button is touchpad click is on.")
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
				Picker("Effect", selection: $triggerPreset) {
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
				Picker("Player", selection: $player) {
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
		.onChange(of: triggerPreset) { _, preset in tester.setTriggers(preset) }
		.onChange(of: player) { _, number in tester.setPlayer(number) }
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

/// A generic PlayStation-style controller with what's pressed lit up
private struct ControllerDiagram: View {
	let tester: ControllerTester

	private static let size = CGSize(width: 400, height: 250)
	private static let idle = Color(.systemGray3)
	private static let shell = Color(.systemGray5)

	var body: some View {
		GeometryReader { geo in
			drawing
				.frame(width: Self.size.width, height: Self.size.height)
				.scaleEffect(geo.size.width / Self.size.width, anchor: .topLeading)
		}
		.aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
		.accessibilityHidden(true)
	}

	private var pad: CKPadState { tester.pad }

	private var drawing: some View {
		ZStack {
			// Body
			Capsule().fill(Self.shell).frame(width: 95, height: 165).rotationEffect(.degrees(18)).position(x: 95, y: 150)
			Capsule().fill(Self.shell).frame(width: 95, height: 165).rotationEffect(.degrees(-18)).position(x: 305, y: 150)
			RoundedRectangle(cornerRadius: 48).fill(Self.shell).frame(width: 300, height: 125).position(x: 200, y: 105)

			// Shoulders
			trigger("L2", pad.l2).position(x: 100, y: 14)
			trigger("R2", pad.r2).position(x: 300, y: 14)
			labelled(Capsule(), "L1", tester.isPressed(CK_BUTTON_L1)).frame(width: 70, height: 12).position(x: 100, y: 36)
			labelled(Capsule(), "R1", tester.isPressed(CK_BUTTON_R1)).frame(width: 70, height: 12).position(x: 300, y: 36)

			// Middle
			touchpad.position(x: 200, y: 85)
			labelled(Capsule(), "", tester.isPressed(CK_BUTTON_SHARE)).frame(width: 10, height: 18).position(x: 132, y: 66)
			labelled(Capsule(), "", tester.isPressed(CK_BUTTON_OPTIONS)).frame(width: 10, height: 18).position(x: 268, y: 66)
			labelled(Circle(), "PS", tester.isPressed(CK_BUTTON_PS)).frame(width: 20, height: 20).position(x: 200, y: 146)

			// D-pad
			dpad(CK_BUTTON_DPAD_UP, "chevron.up").position(x: 95, y: 78)
			dpad(CK_BUTTON_DPAD_DOWN, "chevron.down").position(x: 95, y: 122)
			dpad(CK_BUTTON_DPAD_LEFT, "chevron.left").position(x: 73, y: 100)
			dpad(CK_BUTTON_DPAD_RIGHT, "chevron.right").position(x: 117, y: 100)

			// Face buttons
			face(CK_BUTTON_PYRAMID, "triangle", .green).position(x: 305, y: 76)
			face(CK_BUTTON_MOON, "circle", .red).position(x: 329, y: 100)
			face(CK_BUTTON_CROSS, "xmark", .blue).position(x: 305, y: 124)
			face(CK_BUTTON_BOX, "square", .pink).position(x: 281, y: 100)

			// Sticks
			stick(x: pad.left_x, y: pad.left_y, pressed: tester.isPressed(CK_BUTTON_L3)).position(x: 150, y: 152)
			stick(x: pad.right_x, y: pad.right_y, pressed: tester.isPressed(CK_BUTTON_R3)).position(x: 250, y: 152)
		}
	}

	private func labelled<S: Shape>(_ shape: S, _ label: String, _ on: Bool) -> some View {
		shape.fill(on ? Color.accentColor : Self.idle)
			.overlay(Text(label).font(.system(size: 8, weight: .bold)).foregroundStyle(on ? .white : .secondary))
	}

	private func trigger(_ label: String, _ value: UInt8) -> some View {
		ZStack(alignment: .bottom) {
			Self.idle
			Color.accentColor.frame(height: 22 * CGFloat(value) / 255)
		}
		.frame(width: 70, height: 22)
		.clipShape(RoundedRectangle(cornerRadius: 6))
		.overlay(Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(value > 128 ? .white : .secondary))
	}

	private var touchpad: some View {
		let w: CGFloat = 110
		let h: CGFloat = 58
		return ZStack(alignment: .topLeading) {
			RoundedRectangle(cornerRadius: 8).fill(tester.isPressed(CK_BUTTON_TOUCHPAD) ? Color.accentColor.opacity(0.6) : Self.idle)
			ForEach(0..<2, id: \.self) { slot in
				if let p = tester.touches[slot] {
					Circle().fill(Color.orange).frame(width: 10, height: 10).position(x: p.x * w, y: p.y * h)
				}
			}
		}
		.frame(width: w, height: h)
	}

	private func dpad(_ button: CKButton, _ symbol: String) -> some View {
		let on = tester.isPressed(button)
		return RoundedRectangle(cornerRadius: 4)
			.fill(on ? Color.accentColor : Self.idle)
			.overlay(Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(on ? .white : .secondary))
			.frame(width: 22, height: 22)
	}

	private func face(_ button: CKButton, _ symbol: String, _ color: Color) -> some View {
		let on = tester.isPressed(button)
		return Circle()
			.fill(on ? color : Self.idle)
			.overlay(Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(on ? .white : color))
			.frame(width: 22, height: 22)
	}

	private func stick(x: Int16, y: Int16, pressed: Bool) -> some View {
		ZStack {
			Circle().fill(Color(.systemGray4)).frame(width: 46, height: 46)
			Circle().fill(pressed ? Color.accentColor : Color(.systemGray))
				.frame(width: 28, height: 28)
				.offset(x: CGFloat(x) / 32767 * 12, y: CGFloat(y) / 32767 * 12)
		}
	}
}
