import ChiakiKit
import SwiftUI

/// A white DualSense-style controller that tilts with the gyro, lights up what's
/// pressed and shows the feedback that's playing: shaking for rumble and haptics,
/// trigger effect zones, the lightbar and the player lights.
///
/// Drawn in a fixed 400×270 space and scaled to fit.
struct ControllerRender: View {
	let tester: ControllerTester

	private static let size = CGSize(width: 400, height: 270)

	/// Something is moving on its own, so redraw every frame
	private var animating: Bool {
		tester.buzz != nil || (tester.triggerPreset == .vibration && (tester.pad.l2 > 0 || tester.pad.r2 > 0))
	}

	var body: some View {
		GeometryReader { geo in
			TimelineView(.animation(paused: !animating)) { timeline in
				scene(time: timeline.date.timeIntervalSinceReferenceDate)
			}
			.frame(width: Self.size.width, height: Self.size.height)
			.scaleEffect(geo.size.width / Self.size.width, anchor: .topLeading)
		}
		.aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
		.accessibilityHidden(true)
	}

	private func scene(time: TimeInterval) -> some View {
		let tilt = tester.tilt
		let pitch = max(-0.9, min(0.9, tilt.pitch))
		let roll = max(-1.2, min(1.2, tilt.roll))
		let yaw = max(-0.9, min(0.9, tilt.yaw))
		var shake = CGSize.zero
		if let buzz = tester.buzz {
			let amount = CGFloat(max(buzz.left, buzz.right)) * (buzz.shakeHz < 20 ? 2.4 : 1.1)
			let phase = time * 2 * .pi * buzz.shakeHz
			shake = CGSize(width: sin(phase) * amount, height: cos(phase * 1.3) * amount * 0.4)
		}
		return ZStack {
			// Shadow on the "table", which stays put while the controller moves
			Ellipse()
				.fill(Color.black.opacity(0.16))
				.frame(width: 280 - abs(roll) * 40, height: 22)
				.blur(radius: 8)
				.position(x: 200 + roll * 18, y: 256)

			ControllerBody(tester: tester, time: time)
				.frame(width: Self.size.width, height: Self.size.height)
				.drawingGroup()
				.rotation3DEffect(.radians(-pitch), axis: (x: 1, y: 0, z: 0), perspective: 0.55)
				.rotation3DEffect(.radians(-yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
				.rotationEffect(.radians(roll))
				.offset(shake)
		}
	}
}

// MARK: - The controller

private enum Palette {
	static let shellTop = Color(red: 0.98, green: 0.98, blue: 0.99)
	static let shellBottom = Color(red: 0.83, green: 0.84, blue: 0.87)
	static let edge = Color.black.opacity(0.14)
	static let panelTop = Color(red: 0.18, green: 0.19, blue: 0.21)
	static let panelBottom = Color(red: 0.07, green: 0.075, blue: 0.09)
	static let key = Color(red: 0.22, green: 0.23, blue: 0.26)
	static let keyText = Color(white: 0.78)
	static let touchpadTop = Color(red: 0.95, green: 0.95, blue: 0.96)
	static let touchpadBottom = Color(red: 0.86, green: 0.87, blue: 0.89)
	static let pressed = Color.accentColor
	static let triangle = Color(red: 0.25, green: 0.8, blue: 0.7)
	static let circle = Color(red: 1, green: 0.36, blue: 0.4)
	static let cross = Color(red: 0.45, green: 0.6, blue: 1)
	static let square = Color(red: 0.95, green: 0.5, blue: 0.85)
}

private struct ControllerBody: View {
	let tester: ControllerTester
	let time: TimeInterval

	private var pad: CKPadState { tester.pad }

	var body: some View {
		ZStack {
			// Shoulders peek out from behind the top edge
			trigger("L2", value: pad.l2).position(x: 92, y: 30)
			trigger("R2", value: pad.r2).position(x: 308, y: 30)
			shoulder("L1", tester.isPressed(CK_BUTTON_L1)).position(x: 92, y: 49)
			shoulder("R1", tester.isPressed(CK_BUTTON_R1)).position(x: 308, y: 49)

			// Shell, with the black centre and a soft sheen on top
			DualSenseShell()
				.fill(LinearGradient(colors: [Palette.shellTop, Palette.shellBottom], startPoint: .top, endPoint: .bottom))
				.shadow(color: .black.opacity(0.2), radius: 6, y: 5)
			CentrePanel()
				.fill(LinearGradient(colors: [Palette.panelTop, Palette.panelBottom], startPoint: .top, endPoint: .bottom))
				.mask(DualSenseShell())
			DualSenseShell()
				.fill(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center))
			DualSenseShell().stroke(Palette.edge, lineWidth: 1)

			rumbleRipples

			touchpad
			lightbar
			playerLights

			// Create and Options
			small(tester.isPressed(CK_BUTTON_SHARE)).rotationEffect(.degrees(-25)).position(x: 125, y: 64)
			small(tester.isPressed(CK_BUTTON_OPTIONS)).rotationEffect(.degrees(25)).position(x: 275, y: 64)

			psButton.position(x: 200, y: 150)
			Capsule().fill(Color(white: 0.3)).frame(width: 12, height: 4).position(x: 200, y: 166)

			// D-pad
			dpad(CK_BUTTON_DPAD_UP, "arrowtriangle.up.fill", vertical: true).position(x: 82, y: 84)
			dpad(CK_BUTTON_DPAD_DOWN, "arrowtriangle.down.fill", vertical: true).position(x: 82, y: 124)
			dpad(CK_BUTTON_DPAD_LEFT, "arrowtriangle.left.fill", vertical: false).position(x: 62, y: 104)
			dpad(CK_BUTTON_DPAD_RIGHT, "arrowtriangle.right.fill", vertical: false).position(x: 102, y: 104)

			// Face buttons
			face(CK_BUTTON_PYRAMID, "triangle", Palette.triangle).position(x: 318, y: 82)
			face(CK_BUTTON_MOON, "circle", Palette.circle).position(x: 340, y: 104)
			face(CK_BUTTON_CROSS, "xmark", Palette.cross).position(x: 318, y: 126)
			face(CK_BUTTON_BOX, "square", Palette.square).position(x: 296, y: 104)

			// Sticks
			stick(x: pad.left_x, y: pad.left_y, pressed: tester.isPressed(CK_BUTTON_L3)).position(x: 157, y: 146)
			stick(x: pad.right_x, y: pad.right_y, pressed: tester.isPressed(CK_BUTTON_R3)).position(x: 243, y: 146)
		}
	}

	// MARK: Shoulders

	private func shoulder(_ label: String, _ on: Bool) -> some View {
		Capsule()
			.fill(on ? AnyShapeStyle(Palette.pressed) : AnyShapeStyle(LinearGradient(colors: [Palette.shellTop, Palette.shellBottom], startPoint: .top, endPoint: .bottom)))
			.overlay(Capsule().stroke(Palette.edge, lineWidth: 0.75))
			.overlay(alignment: .top) {
				Text(label).font(.system(size: 6, weight: .heavy)).foregroundStyle(on ? .white : .secondary).padding(.top, 1)
			}
			.frame(width: 74, height: 14)
			.offset(y: on ? 1.5 : 0)
	}

	/// The trigger fills as it's pulled; the active effect is drawn over its travel
	private func trigger(_ label: String, value: UInt8) -> some View {
		let v = CGFloat(value) / 255
		let w: CGFloat = 62
		let h: CGFloat = 26
		var jitter: CGFloat = 0
		if tester.triggerPreset == .vibration, value > 0 {
			jitter = sin(time * 2 * .pi * 22) * 1.3
		}
		return ZStack(alignment: .top) {
			LinearGradient(colors: [Palette.shellTop, Palette.shellBottom], startPoint: .top, endPoint: .bottom)
			effectZones(height: h)
			Palette.pressed.opacity(0.85).frame(height: h * v)
		}
		.frame(width: w, height: h)
		.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.edge, lineWidth: 0.75))
		.overlay(alignment: .top) {
			Text(label).font(.system(size: 7, weight: .heavy)).foregroundStyle(v > 0.3 ? .white : .secondary).padding(.top, 3)
		}
		.offset(x: jitter, y: v * 3)
	}

	/// Where the trigger pushes back, gives way or buzzes, top (at rest) to bottom (fully pulled)
	@ViewBuilder
	private func effectZones(height h: CGFloat) -> some View {
		switch tester.triggerPreset {
		case .off:
			EmptyView()
		case .resistance:
			VStack(spacing: 0) {
				Color.clear.frame(height: h * 0.3)
				LinearGradient(colors: [.orange.opacity(0.25), .orange.opacity(0.55)], startPoint: .top, endPoint: .bottom)
			}
		case .weapon:
			VStack(spacing: 0) {
				Color.clear.frame(height: h * 0.2)
				Color.orange.opacity(0.4)
					.frame(height: h * 0.4)
					.overlay(alignment: .bottom) { Rectangle().fill(Color.orange).frame(height: 1.5) }
				Color.clear
			}
		case .vibration:
			Color.purple.opacity(0.3)
		}
	}

	// MARK: Rumble

	/// Rings spreading from the grips while rumble or haptics play
	@ViewBuilder
	private var rumbleRipples: some View {
		if let buzz = tester.buzz {
			ForEach(Array([(buzz.left, CGFloat(62)), (buzz.right, CGFloat(338))].enumerated()), id: \.offset) { _, side in
				if side.0 > 0 {
					ForEach(0..<2, id: \.self) { ring in
						let phase = (time * 2.2 + Double(ring) * 0.5).truncatingRemainder(dividingBy: 1)
						Circle()
							.stroke(Palette.pressed.opacity((1 - phase) * 0.55 * Double(side.0)), lineWidth: 2)
							.frame(width: 16 + phase * 70, height: 16 + phase * 70)
							.position(x: side.1, y: 196)
					}
				}
			}
		}
	}

	// MARK: Touchpad and lights

	private var touchpad: some View {
		let fingers: [(CGPoint, Color)] = tester.touches.compactMap { $0.map { ($0, Color.orange) } }
			+ tester.screenTouches.sorted { $0.key < $1.key }.map { ($0.value, Color.cyan) }
		return ZStack {
			TouchpadShape()
				.fill(LinearGradient(colors: [Palette.touchpadTop, Palette.touchpadBottom], startPoint: .top, endPoint: .bottom))
			if tester.touchpadClicked {
				TouchpadShape().fill(Palette.pressed.opacity(0.35))
			}
			TouchpadShape().stroke(Palette.edge, lineWidth: 0.75)
			ForEach(Array(fingers.enumerated()), id: \.offset) { _, finger in
				Circle()
					.fill(finger.1)
					.frame(width: 9, height: 9)
					.shadow(color: finger.1, radius: 4)
					.position(x: TouchpadShape.rect.minX + finger.0.x * TouchpadShape.rect.width,
						y: TouchpadShape.rect.minY + finger.0.y * TouchpadShape.rect.height)
			}
		}
		.scaleEffect(tester.touchpadClicked ? 0.985 : 1, anchor: UnitPoint(x: 0.5, y: 87.0 / 270))
	}

	private var lightbar: some View {
		ZStack {
			if let color = tester.lightbar {
				LightbarShape().stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round)).blur(radius: 5).opacity(0.8)
				TouchpadShape().stroke(color.opacity(0.35), lineWidth: 3).blur(radius: 3)
				LightbarShape().stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
				LightbarShape().stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
			} else {
				LightbarShape().stroke(Color(white: 0.55).opacity(0.5), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
			}
		}
	}

	/// The DualSense's five dots: 1 is the middle, 2 the inner pair, 3 the middle and outer pair, 4 all but the middle
	private var playerLights: some View {
		let lit: Set<Int> = switch tester.player {
		case 1: [2]
		case 2: [1, 3]
		case 3: [0, 2, 4]
		case 4: [0, 1, 3, 4]
		default: []
		}
		return HStack(spacing: 4) {
			ForEach(0..<5, id: \.self) { i in
				Circle()
					.fill(lit.contains(i) ? Color.white : Color(white: 0.35))
					.frame(width: 3.5, height: 3.5)
					.shadow(color: lit.contains(i) ? .white : .clear, radius: 2.5)
			}
		}
		.position(x: 200, y: 125)
	}

	// MARK: Buttons

	private func small(_ on: Bool) -> some View {
		Capsule()
			.fill(on ? Palette.pressed : Palette.key)
			.frame(width: 5, height: 13)
			.shadow(color: on ? Palette.pressed : .clear, radius: 3)
	}

	private var psButton: some View {
		let on = tester.isPressed(CK_BUTTON_PS)
		return Circle()
			.fill(on ? AnyShapeStyle(Palette.pressed) : AnyShapeStyle(RadialGradient(colors: [Color(white: 0.3), Color(white: 0.12)], center: .topLeading, startRadius: 0, endRadius: 16)))
			.overlay(Image(systemName: "playstation.logo").font(.system(size: 7, weight: .bold)).foregroundStyle(.white.opacity(on ? 1 : 0.8)))
			.frame(width: 16, height: 16)
			.shadow(color: on ? Palette.pressed : .clear, radius: 4)
	}

	private func dpad(_ button: CKButton, _ symbol: String, vertical: Bool) -> some View {
		let on = tester.isPressed(button)
		return RoundedRectangle(cornerRadius: 4, style: .continuous)
			.fill(on ? AnyShapeStyle(Palette.pressed) : AnyShapeStyle(LinearGradient(colors: [Color(white: 0.32), Palette.key], startPoint: .top, endPoint: .bottom)))
			.overlay(Image(systemName: symbol).font(.system(size: 6)).foregroundStyle(on ? .white : Palette.keyText))
			.frame(width: vertical ? 16 : 19, height: vertical ? 19 : 16)
			.shadow(color: on ? Palette.pressed.opacity(0.8) : .black.opacity(0.25), radius: on ? 4 : 1, y: on ? 0 : 1)
			.scaleEffect(on ? 0.92 : 1)
	}

	private func face(_ button: CKButton, _ symbol: String, _ color: Color) -> some View {
		let on = tester.isPressed(button)
		return Circle()
			.fill(on ? AnyShapeStyle(color) : AnyShapeStyle(RadialGradient(colors: [Color(white: 0.34), Palette.key], center: .topLeading, startRadius: 0, endRadius: 22)))
			.overlay(Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(on ? .white : color))
			.frame(width: 21, height: 21)
			.shadow(color: on ? color : .black.opacity(0.3), radius: on ? 5 : 1, y: on ? 0 : 1)
			.scaleEffect(on ? 0.92 : 1)
	}

	private func stick(x: Int16, y: Int16, pressed: Bool) -> some View {
		let dx = CGFloat(x) / 32767 * 8
		let dy = CGFloat(y) / 32767 * 8
		return ZStack {
			Circle()
				.fill(RadialGradient(colors: [Color(white: 0.02), Color(white: 0.1)], center: .center, startRadius: 8, endRadius: 20))
				.frame(width: 40, height: 40)
			Circle()
				.fill(RadialGradient(colors: [Color(white: 0.38), Color(white: 0.16)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 18))
				.overlay(Circle().stroke(pressed ? Palette.pressed : .white.opacity(0.1), lineWidth: pressed ? 2.5 : 1))
				.overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1).padding(5))
				.frame(width: 28, height: 28)
				.shadow(color: pressed ? Palette.pressed : .black.opacity(0.5), radius: pressed ? 5 : 2, x: dx * 0.3, y: 1 + dy * 0.3)
				.scaleEffect(pressed ? 0.92 : 1)
				.offset(x: dx, y: dy)
		}
	}
}

// MARK: - Shapes (400×270 space)

/// Maps the 400×270 design space into a shape's rect
private struct Space {
	let rect: CGRect
	func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
		CGPoint(x: rect.minX + x / 400 * rect.width, y: rect.minY + y / 270 * rect.height)
	}
}

private struct DualSenseShell: Shape {
	func path(in rect: CGRect) -> Path {
		let s = Space(rect: rect)
		var path = Path()
		path.move(to: s.p(200, 48))
		// Right half, clockwise
		path.addQuadCurve(to: s.p(318, 52), control: s.p(260, 44))
		path.addCurve(to: s.p(372, 120), control1: s.p(350, 56), control2: s.p(366, 86))
		path.addCurve(to: s.p(374, 222), control1: s.p(382, 160), control2: s.p(392, 205))
		path.addCurve(to: s.p(322, 226), control1: s.p(360, 242), control2: s.p(334, 240))
		path.addCurve(to: s.p(272, 168), control1: s.p(305, 205), control2: s.p(292, 172))
		path.addQuadCurve(to: s.p(200, 172), control: s.p(236, 166))
		// Left half, mirrored
		path.addQuadCurve(to: s.p(128, 168), control: s.p(164, 166))
		path.addCurve(to: s.p(78, 226), control1: s.p(108, 172), control2: s.p(95, 205))
		path.addCurve(to: s.p(26, 222), control1: s.p(66, 240), control2: s.p(40, 242))
		path.addCurve(to: s.p(28, 120), control1: s.p(8, 205), control2: s.p(18, 160))
		path.addCurve(to: s.p(82, 52), control1: s.p(34, 86), control2: s.p(50, 56))
		path.addQuadCurve(to: s.p(200, 48), control: s.p(140, 44))
		path.closeSubpath()
		return path
	}
}

/// The black middle, around the touchpad and sticks
private struct CentrePanel: Shape {
	func path(in rect: CGRect) -> Path {
		let s = Space(rect: rect)
		var path = Path()
		path.move(to: s.p(122, 66))
		path.addLine(to: s.p(278, 66))
		path.addCurve(to: s.p(290, 150), control1: s.p(294, 90), control2: s.p(294, 130))
		path.addCurve(to: s.p(264, 170), control1: s.p(287, 162), control2: s.p(276, 168))
		path.addQuadCurve(to: s.p(136, 170), control: s.p(200, 176))
		path.addCurve(to: s.p(110, 150), control1: s.p(124, 168), control2: s.p(113, 162))
		path.addCurve(to: s.p(122, 66), control1: s.p(106, 130), control2: s.p(106, 90))
		path.closeSubpath()
		return path
	}
}

/// Slightly narrower at the bottom, like the real one
private struct TouchpadShape: Shape {
	/// Where fingers are drawn, in design space
	static let rect = CGRect(x: 140, y: 56, width: 120, height: 62)

	func path(in rect: CGRect) -> Path {
		let s = Space(rect: rect)
		var path = Path()
		path.move(to: s.p(147, 56))
		path.addLine(to: s.p(253, 56))
		path.addQuadCurve(to: s.p(260, 63), control: s.p(260, 56))
		path.addLine(to: s.p(253, 111))
		path.addQuadCurve(to: s.p(246, 118), control: s.p(252, 118))
		path.addLine(to: s.p(154, 118))
		path.addQuadCurve(to: s.p(147, 111), control: s.p(148, 118))
		path.addLine(to: s.p(140, 63))
		path.addQuadCurve(to: s.p(147, 56), control: s.p(140, 56))
		path.closeSubpath()
		return path
	}
}

/// The two light strips down either side of the touchpad
private struct LightbarShape: Shape {
	func path(in rect: CGRect) -> Path {
		let s = Space(rect: rect)
		var path = Path()
		path.move(to: s.p(135, 64))
		path.addLine(to: s.p(143, 114))
		path.move(to: s.p(265, 64))
		path.addLine(to: s.p(257, 114))
		return path
	}
}
