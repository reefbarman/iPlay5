import ChiakiKit
import UIKit

/// An occupied stick (even at its centre) owns that axis until its finger lifts.
struct VirtualPadState: Equatable {
	var buttons: UInt32 = 0
	var l2: UInt8 = 0
	var r2: UInt8 = 0
	var leftStick: SIMD2<Int16>?
	var rightStick: SIMD2<Int16>?
}

/// Drawn above Metal. StreamMetalView owns the UIKit touches so that fixed controls,
/// floating sticks, the touchpad and the stream menu all agree on who gets each finger.
final class VirtualControlsOverlay: UIView {
	private enum Action {
		case button(UInt32), trigger(left: Bool), dpad(UInt32)
	}

	private struct Control {
		let label: String
		let rect: CGRect
		let action: Action
		let rounded: Bool

		init(_ label: String, _ rect: CGRect, _ action: Action, rounded: Bool = false) {
			self.label = label
			self.rect = rect
			self.action = action
			self.rounded = rounded
		}
	}

	private enum Finger {
		case button(UInt32), trigger(left: Bool), dpad(UInt32)
		case stick(left: Bool, origin: CGPoint, location: CGPoint)
	}

	private var fingers: [ObjectIdentifier: Finger] = [:]
	private var controls: [Control] = []
	private var dpadCentre = CGPoint.zero
	private var dpadRect = CGRect.zero
	private(set) var touchpadRect = CGRect.zero
	private var touchpadPressed = false
	private var area = CGRect.null
	private var pad = VirtualPadState()
	private static let stickRadius: CGFloat = 42

	override init(frame: CGRect) {
		super.init(frame: frame)
		isOpaque = false
		isUserInteractionEnabled = false
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	func setLayout(in safeArea: CGRect) {
		guard area != safeArea else { return }
		area = safeArea
		let x = safeArea.minX + 68, right = safeArea.maxX - 68
		let row = safeArea.maxY - 111
		let shoulders = max(safeArea.minY + 32, bounds.minY + 76)
		let bottom = safeArea.maxY - 26
		let middle = safeArea.midX
		func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 44, _ h: CGFloat = 44) -> CGRect {
			CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
		}
		func button(_ label: String, _ x: CGFloat, _ y: CGFloat, _ bit: CKButton) -> Control {
			Control(label, rect(x, y), .button(bit.rawValue))
		}
		dpadCentre = CGPoint(x: x, y: row)
		dpadRect = rect(x, row, 116, 116)
		controls = [
			Control("L2", rect(x - 32, shoulders, 56, 44), .trigger(left: true), rounded: true),
			Control("L1", rect(x + 32, shoulders, 56, 44), .button(CK_BUTTON_L1.rawValue), rounded: true),
			Control("R1", rect(right - 32, shoulders, 56, 44), .button(CK_BUTTON_R1.rawValue), rounded: true),
			Control("R2", rect(right + 32, shoulders, 56, 44), .trigger(left: false), rounded: true),
			Control("▲", rect(x, row - 36, 36, 36), .dpad(CK_BUTTON_DPAD_UP.rawValue), rounded: true),
			Control("◀", rect(x - 36, row, 36, 36), .dpad(CK_BUTTON_DPAD_LEFT.rawValue), rounded: true),
			Control("▶", rect(x + 36, row, 36, 36), .dpad(CK_BUTTON_DPAD_RIGHT.rawValue), rounded: true),
			Control("▼", rect(x, row + 36, 36, 36), .dpad(CK_BUTTON_DPAD_DOWN.rawValue), rounded: true),
			button("△", right, row - 36, CK_BUTTON_PYRAMID),
			button("□", right - 36, row, CK_BUTTON_BOX),
			button("○", right + 36, row, CK_BUTTON_MOON),
			button("×", right, row + 36, CK_BUTTON_CROSS),
			button("L3", x, bottom, CK_BUTTON_L3),
			button("R3", right, bottom, CK_BUTTON_R3),
			Control("Create", rect(middle - 65, bottom - 59, 56, 44), .button(CK_BUTTON_SHARE.rawValue), rounded: true),
			Control("PS", rect(middle, bottom - 59, 46, 44), .button(CK_BUTTON_PS.rawValue), rounded: true),
			Control("Options", rect(middle + 65, bottom - 59, 64, 44), .button(CK_BUTTON_OPTIONS.rawValue), rounded: true),
		]
		touchpadRect = rect(middle, bottom - 4, 176, 54)
		setNeedsDisplay()
	}

	func setTouchpadPressed(_ pressed: Bool) {
		guard pressed != touchpadPressed else { return }
		touchpadPressed = pressed
		setNeedsDisplay()
	}

	func reset() {
		fingers.removeAll()
		pad = VirtualPadState()
		touchpadPressed = false
		setNeedsDisplay()
	}

	func begin(_ id: ObjectIdentifier, at point: CGPoint) -> VirtualPadState? {
		if let control = controls.first(where: { $0.rect.contains(point) }) {
			switch control.action {
			case .button(let bit): fingers[id] = .button(bit)
			case .trigger(let left): fingers[id] = .trigger(left: left)
			case .dpad: fingers[id] = .dpad(direction(at: point))
			}
		} else if dpadRect.contains(point) {
			fingers[id] = .dpad(direction(at: point))
		} else {
			let left = point.x < bounds.midX
			guard !fingers.values.contains(where: {
				if case .stick(let side, _, _) = $0 { return side == left }
				return false
			}) else { return nil }
			fingers[id] = .stick(left: left, origin: point, location: point)
		}
		return publish()
	}

	func move(_ id: ObjectIdentifier, to point: CGPoint) -> VirtualPadState? {
		switch fingers[id] {
		case .stick(let left, let origin, _): fingers[id] = .stick(left: left, origin: origin, location: point)
		case .dpad: fingers[id] = .dpad(direction(at: point))
		default: return nil
		}
		return publish()
	}

	func end(_ id: ObjectIdentifier) -> VirtualPadState? {
		guard fingers.removeValue(forKey: id) != nil else { return nil }
		return publish()
	}

	private func direction(at point: CGPoint) -> UInt32 {
		let dx = point.x - dpadCentre.x, dy = point.y - dpadCentre.y
		let distance = max(abs(dx), abs(dy))
		guard distance > 9 else { return 0 }
		let threshold = distance * 0.42
		var bits: UInt32 = 0
		if dx < -threshold { bits |= CK_BUTTON_DPAD_LEFT.rawValue }
		if dx > threshold { bits |= CK_BUTTON_DPAD_RIGHT.rawValue }
		if dy < -threshold { bits |= CK_BUTTON_DPAD_UP.rawValue }
		if dy > threshold { bits |= CK_BUTTON_DPAD_DOWN.rawValue }
		return bits
	}

	private func publish() -> VirtualPadState? {
		var next = VirtualPadState()
		for finger in fingers.values {
			switch finger {
			case .button(let bit), .dpad(let bit): next.buttons |= bit
			case .trigger(let left):
				if left { next.l2 = 255 } else { next.r2 = 255 }
			case .stick(let left, let origin, let location):
				let dx = location.x - origin.x, dy = location.y - origin.y
				let distance = hypot(dx, dy)
				let deadZone: CGFloat = 5
				let scale = distance > deadZone ? 32767 * min(1, (distance - deadZone) / (Self.stickRadius - deadZone)) / distance : 0
				let axis = SIMD2(Int16(clamping: Int((dx * scale).rounded())), Int16(clamping: Int((dy * scale).rounded())))
				if left { next.leftStick = axis } else { next.rightStick = axis }
			}
		}
		setNeedsDisplay()
		guard next != pad else { return nil }
		pad = next
		return next
	}

	override func draw(_ rect: CGRect) {
		for control in controls {
			let pressed: Bool
			switch control.action {
			case .button(let bit), .dpad(let bit): pressed = pad.buttons & bit != 0
			case .trigger(let left): pressed = (left ? pad.l2 : pad.r2) != 0
			}
			drawControl(control.rect, radius: control.rounded ? 10 : control.rect.height / 2, pressed: pressed, label: control.label)
		}
		drawControl(touchpadRect, radius: 12, pressed: touchpadPressed, label: "Touchpad")
		let radius = Self.stickRadius
		for case .stick(_, let origin, let location) in fingers.values {
			let dx = location.x - origin.x, dy = location.y - origin.y
			let scale = radius / max(radius, hypot(dx, dy))
			let knob = CGPoint(x: origin.x + dx * scale, y: origin.y + dy * scale)
			drawControl(CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2), radius: radius, pressed: false)
			drawControl(CGRect(x: knob.x - 18, y: knob.y - 18, width: 36, height: 36), radius: 18, pressed: true)
		}
	}

	private func drawControl(_ rect: CGRect, radius: CGFloat, pressed: Bool, label: String? = nil) {
		let path = UIBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: radius)
		(pressed ? UIColor.white.withAlphaComponent(0.42) : UIColor.black.withAlphaComponent(0.36)).setFill()
		path.fill()
		UIColor.white.withAlphaComponent(pressed ? 0.85 : 0.36).setStroke()
		path.lineWidth = 1
		path.stroke()
		guard let label else { return }
		let attributes: [NSAttributedString.Key: Any] = [
			.font: UIFont.systemFont(ofSize: label.count == 1 ? 23 : 12, weight: .semibold),
			.foregroundColor: UIColor.white.withAlphaComponent(0.9),
		]
		let size = label.size(withAttributes: attributes)
		label.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
	}
}
