import SceneKit
import SwiftUI

/// Shows `ControllerScene`, redrawn every frame so shaking and trigger buzz animate smoothly.
/// Touching the controller's touchpad on screen works like touching the stream: drag to move
/// a finger on the touchpad, tap to click it.
struct ControllerSceneView: UIViewRepresentable {
	let state: ControllerScene.State
	var onTouch: (ControllerInput.TouchEvent) -> Void = { _ in }
	var onTap: (Int) -> Void = { _ in }

	final class Coordinator {
		let controller = Bundle.main.url(forResource: "DualSense", withExtension: "usdz").flatMap(ControllerScene.init(url:))
	}

	func makeCoordinator() -> Coordinator { Coordinator() }

	func makeUIView(context: Context) -> TouchView {
		let view = TouchView()
		view.backgroundColor = .clear
		view.antialiasingMode = .multisampling4X
		view.preferredFramesPerSecond = 60
		view.isMultipleTouchEnabled = true
		if let controller = context.coordinator.controller {
			view.controller = controller
			view.scene = controller.scene
			view.pointOfView = controller.cameraNode
			view.delegate = controller
			view.rendersContinuously = true
			view.isPlaying = true
		}
		return view
	}

	func updateUIView(_ view: TouchView, context: Context) {
		context.coordinator.controller?.state = state
		view.onTouch = onTouch
		view.onTap = onTap
	}

	static func dismantleUIView(_ view: TouchView, coordinator: Coordinator) {
		view.isPlaying = false
		view.rendersContinuously = false
	}

	/// Tracks up to two fingers that start on the touchpad, the way the stream's touch handling does
	final class TouchView: SCNView {
		weak var controller: ControllerScene?
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

		/// On the touchpad, in the touchpad's 1920×1080 grid
		private func padPoint(_ p: CGPoint, starting: Bool) -> (UInt16, UInt16)? {
			guard let pad = controller?.touchpadPoint(p, in: self) else { return nil }
			// A finger has to land on the pad, give or take a little, but can slide off its edge
			if starting, pad.x < -0.06 || pad.x > 1.06 || pad.y < -0.1 || pad.y > 1.1 { return nil }
			let x = min(max(pad.x, 0), 1)
			let y = min(max(pad.y, 0), 1)
			return (UInt16((x * 1919).rounded()), UInt16((y * 1079).rounded()))
		}

		override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
			for touch in touches {
				let used = Set(tracked.values.map(\.slot))
				guard let slot = [10, 11].first(where: { !used.contains($0) }) else { continue }
				let p = touch.location(in: self)
				guard let (x, y) = padPoint(p, starting: true) else { continue }
				tracked[ObjectIdentifier(touch)] = Tracked(slot: slot, start: p, time: touch.timestamp)
				onTouch?(.down(slot: slot, x: x, y: y))
			}
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
				guard let (x, y) = padPoint(p, starting: false) else { continue }
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
		}
	}
}
