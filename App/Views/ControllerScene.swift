import CoreGraphics
import Foundation
import SceneKit
import simd

/// The 3D DualSense in the Controller Test: lights up and moves what's pressed, turns
/// with the controller and shows the feedback that's playing.
///
/// The model is App/Resources/DualSense.usdz, made by scripts/controller-model/export.py:
/// +X right, +Y towards the triggers, +Z out of the face, 2 units across. USD turns the
/// `-` in the original part names into `_`.
///
/// Only SceneKit and Core Graphics, so scripts/controller-model/preview.swift can render it on a Mac.
final class ControllerScene: NSObject, SCNSceneRendererDelegate {
	enum Control: Hashable, CaseIterable {
		case cross, circle, square, triangle, up, down, left, right
		case l1, r1, l3, r3, create, options, ps, touchpad
	}

	enum TriggerLook { case off, resistance, weapon, vibration }

	/// A finger on the touchpad, 0...1 across and down
	struct Touch {
		var x: Float
		var y: Float
		/// Touching the touchpad on screen rather than the controller's own
		var fromScreen: Bool
	}

	struct Buzz {
		var left: Float
		var right: Float
		var hz: Double
	}

	struct State {
		var pressed: Set<Control> = []
		/// -1...1, +y down, as the pad reports it
		var leftStick = SIMD2<Float>.zero
		var rightStick = SIMD2<Float>.zero
		var l2: Float = 0
		var r2: Float = 0
		/// How the controller has turned since it was last levelled, in the model's axes
		var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
		var touches: [Touch] = []
		var lightbar: CGColor?
		var player: Int?
		var triggerLook = TriggerLook.off
		var buzz: Buzz?
	}

	let scene = SCNScene()

	/// Set from any thread; applied every frame
	var state: State {
		get { lock.withLock { pending } }
		set { lock.withLock { pending = newValue } }
	}

	private let lock = NSLock()
	private var pending = State()

	/// Turned by the controller's orientation
	private let rig = SCNNode()
	/// Shaken by rumble and haptics
	private let shaker = SCNNode()
	private let model: SCNNode

	private struct Part {
		let nodes: [SCNNode]
		let rest: [simd_float4x4]
		/// Lit up when pressed
		let materials: [SCNMaterial]
	}

	private var controls: [Control: Part] = [:]
	private var sticks: [Part] = []
	private var stickPivots: [SIMD3<Float>] = []
	private var triggers: [Part] = []
	private var triggerHinges: [SIMD3<Float>] = []
	private var lightbar: [SCNMaterial] = []
	private var touchpadGeometry: SCNNode?
	private var fingers: [SCNNode] = []
	private var playerLights: [SCNNode] = []
	private var ripples: [SCNNode] = []
	/// Glows behind L1, R1, L2 and R2, which hide behind the controller when it faces you
	private var halos: [SCNNode] = []
	/// Glows on the touchpad where it's clicked
	private var clickSpots: [SCNNode] = []

	// MARK: - Colours

	private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
		CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
	}

	private static let shell = rgb(0.92, 0.92, 0.94)
	private static let black = rgb(0.05, 0.055, 0.065)
	private static let key = rgb(0.14, 0.145, 0.16)
	private static let stick = rgb(0.11, 0.115, 0.125)
	private static let symbol = rgb(0.72, 0.73, 0.77)
	private static let lightbarOff = rgb(0.55, 0.57, 0.62)
	static let accent = rgb(0.2, 0.5, 1)
	/// Pressed and pulled on the white parts, where a glow barely shows
	private static let shellPressed = rgb(0.1, 0.42, 1)
	private static let faceColours: [Control: CGColor] = [
		.triangle: rgb(0.2, 0.85, 0.7), .circle: rgb(1, 0.3, 0.35),
		.cross: rgb(0.4, 0.6, 1), .square: rgb(0.95, 0.45, 0.85),
	]
	private static let effectColours: [TriggerLook: CGColor] = [
		.resistance: rgb(1, 0.55, 0.1), .weapon: rgb(1, 0.35, 0.1), .vibration: rgb(0.65, 0.3, 1),
	]

	private static func mix(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
		let space = CGColorSpace(name: CGColorSpace.sRGB)!
		guard let ca = a.converted(to: space, intent: .defaultIntent, options: nil)?.components,
			  let cb = b.converted(to: space, intent: .defaultIntent, options: nil)?.components,
			  ca.count >= 3, cb.count >= 3
		else { return t < 0.5 ? a : b }
		let t = min(max(t, 0), 1)
		return rgb(ca[0] + (cb[0] - ca[0]) * t, ca[1] + (cb[1] - ca[1]) * t, ca[2] + (cb[2] - ca[2]) * t)
	}

	private static func material(_ colour: CGColor, roughness: CGFloat, metalness: CGFloat = 0) -> SCNMaterial {
		let m = SCNMaterial()
		m.lightingModel = .physicallyBased
		m.diffuse.contents = colour
		m.roughness.contents = roughness
		m.metalness.contents = metalness
		m.emission.contents = CGColor(gray: 0, alpha: 1)
		return m
	}

	// MARK: - Setup

	init?(url: URL) {
		guard let source = try? SCNScene(url: url, options: nil) else { return nil }
		model = SCNNode()
		for child in source.rootNode.childNodes { model.addChildNode(child) }
		super.init()

		scene.rootNode.addChildNode(rig)
		rig.addChildNode(shaker)
		shaker.addChildNode(model)
		setUpLighting()
		setUpMaterials()
		setUpControls()
		setUpOverlays()
	}

	private func node(_ name: String) -> SCNNode? {
		model.childNode(withName: name, recursively: true)
	}

	/// The nodes under `name` that have geometry
	private func geometryNodes(_ name: String) -> [SCNNode] {
		guard let root = node(name) else { return [] }
		var found: [SCNNode] = []
		root.enumerateHierarchy { n, _ in if n.geometry != nil { found.append(n) } }
		return found
	}

	@discardableResult
	private func paint(_ names: [String], _ make: @autoclosure () -> SCNMaterial) -> [SCNMaterial] {
		var made: [SCNMaterial] = []
		for name in names {
			for n in geometryNodes(name) {
				let m = make()
				n.geometry?.materials = [m]
				made.append(m)
			}
		}
		return made
	}

	private func setUpMaterials() {
		paint(["MainBody", "MainBodyBack", "Touchpad", "LeftShoulder", "RightShoulder",
			"Shoulder_Left_Trigger", "Shoulder_Right_Trigger"], Self.material(Self.shell, roughness: 0.45))
		paint(["MainBodyFront", "Joystick_Left_Ring", "Joystick_Right_Ring", "B1", "B2", "B3", "B4",
			"AudioJack", "Charger", "USBPort", "LED3"], Self.material(Self.black, roughness: 0.55))
		paint(["LeftThumb", "RightThumb"], Self.material(Self.stick, roughness: 0.75))
		paint(["Special"], Self.material(Self.black, roughness: 0.2, metalness: 0.3))
		paint(["B1Button", "B2Button", "B3Button", "B4Button", "DPadUp", "DPadDown", "DPadLeft", "DPadRight",
			"DPadUpCover", "DPadDownCover", "DPadLeftCover", "DPadRightCover", "Back", "Start"],
			Self.material(Self.key, roughness: 0.3))
		paint(["B1ButtonSymbol", "B2ButtonSymbol", "B3ButtonSymbol", "B4ButtonSymbol", "DPadUpArrow", "DPadDownArrow",
			"DPadLeftArrow", "DPadRightArrow", "ShareSymbol", "MenuSymbol"], Self.material(Self.symbol, roughness: 0.4))
		lightbar = paint(["LED1", "LED2"], Self.material(Self.lightbarOff, roughness: 0.25))
	}

	private func part(_ names: [String]) -> Part {
		let nodes = names.compactMap(node)
		var materials: [SCNMaterial] = []
		for name in names {
			for n in geometryNodes(name) { materials += n.geometry?.materials ?? [] }
		}
		return Part(nodes: nodes, rest: nodes.map(\.simdTransform), materials: materials)
	}

	private func setUpControls() {
		controls = [
			.cross: part(["B1Button", "B1ButtonSymbol"]),
			.circle: part(["B2Button", "B2ButtonSymbol"]),
			.square: part(["B3Button", "B3ButtonSymbol"]),
			.triangle: part(["B4Button", "B4ButtonSymbol"]),
			.up: part(["DPadUp", "DPadUpCover", "DPadUpArrow"]),
			.down: part(["DPadDown", "DPadDownCover", "DPadDownArrow"]),
			.left: part(["DPadLeft", "DPadLeftCover", "DPadLeftArrow"]),
			.right: part(["DPadRight", "DPadRightCover", "DPadRightArrow"]),
			.l1: part(["LeftShoulder"]),
			.r1: part(["RightShoulder"]),
			.create: part(["Back", "ShareSymbol"]),
			.options: part(["Start", "MenuSymbol"]),
			.ps: part(["Special"]),
			.touchpad: part(["Touchpad"]),
		]
		// Sticks tip over from their base, cap and all
		for (name, cap) in [("LeftThumb", "Joystick_Left_Ring"), ("RightThumb", "Joystick_Right_Ring")] {
			let p = part([name, cap])
			sticks.append(p)
			let (lo, _) = p.nodes.first?.boundingBox ?? (SCNVector3Zero, SCNVector3Zero)
			let base = p.nodes.first.map { $0.simdPosition + SIMD3(0, 0, Float(lo.z)) } ?? .zero
			stickPivots.append(base)
		}
		// Triggers swing from the top of the trigger, towards the face
		for name in ["Shoulder_Left_Trigger", "Shoulder_Right_Trigger"] {
			let p = part([name])
			triggers.append(p)
			let (_, hi) = p.nodes.first?.boundingBox ?? (SCNVector3Zero, SCNVector3Zero)
			let hinge = p.nodes.first.map { $0.simdPosition + SIMD3(0, Float(hi.y), 0) } ?? .zero
			triggerHinges.append(hinge)
		}
		touchpadGeometry = geometryNodes("Touchpad").first
	}

	/// Fingers on the touchpad, the player lights and rumble ripples
	private func setUpOverlays() {
		for _ in 0..<4 {
			let dot = SCNNode(geometry: SCNSphere(radius: 0.022))
			dot.geometry?.materials = [Self.material(Self.accent, roughness: 0.3)]
			dot.scale = SCNVector3(1, 1, 0.35)
			dot.isHidden = true
			model.addChildNode(dot)
			fingers.append(dot)
		}
		// The top row of dots under the touchpad
		let front = geometryNodes("MainBodyFront")
		for i in 0..<5 {
			let x = Float(i - 2) * 0.041
			let y: Float = 0.15
			var z: Float = 0.28
			for n in front {
				let from = model.convertPosition(SCNVector3(x, y, 1), to: n)
				let to = model.convertPosition(SCNVector3(x, y, -1), to: n)
				if let hit = n.hitTestWithSegment(from: from, to: to, options: nil).first {
					z = Float(model.convertPosition(hit.localCoordinates, from: n).z)
					break
				}
			}
			let light = SCNNode(geometry: SCNSphere(radius: 0.009))
			let m = Self.material(CGColor(gray: 1, alpha: 1), roughness: 0.2)
			m.emission.contents = CGColor(gray: 1, alpha: 1)
			m.emission.intensity = 2
			light.geometry?.materials = [m]
			light.simdPosition = SIMD3(x, y, z + 0.002)
			light.scale = SCNVector3(1, 1, 0.4)
			light.isHidden = true
			model.addChildNode(light)
			playerLights.append(light)
		}
		for _ in 0..<2 {
			let plane = SCNPlane(width: 0.3, height: 0.3)
			let m = SCNMaterial()
			m.lightingModel = .constant
			// Laid over the white pad, where adding light would barely show: solid blue, faded out by the glow's alpha
			m.diffuse.contents = Self.shellPressed
			m.transparent.contents = Self.glowImage
			m.transparencyMode = .aOne
			m.blendMode = .alpha
			m.writesToDepthBuffer = false
			plane.materials = [m]
			let spot = SCNNode(geometry: plane)
			spot.renderingOrder = 10
			spot.isHidden = true
			model.addChildNode(spot)
			clickSpots.append(spot)
		}
		// Behind and above each shoulder button and trigger, so the glow shows over the top edge
		for (name, back, size) in [("LeftShoulder", Float(0.05), CGFloat(0.75)), ("RightShoulder", 0.05, 0.75),
								   ("Shoulder_Left_Trigger", 0.2, 0.9), ("Shoulder_Right_Trigger", 0.2, 0.9)] {
			let plane = SCNPlane(width: size, height: size)
			let m = SCNMaterial()
			m.lightingModel = .constant
			m.diffuse.contents = Self.glowImage
			m.multiply.contents = Self.shellPressed
			m.blendMode = .add
			m.writesToDepthBuffer = false
			m.isDoubleSided = true
			plane.materials = [m]
			let halo = SCNNode(geometry: plane)
			halo.simdPosition = (node(name)?.simdPosition ?? .zero) + SIMD3(0, 0.06, -back)
			halo.constraints = [SCNBillboardConstraint()]
			halo.renderingOrder = 10
			halo.opacity = 0
			model.addChildNode(halo)
			halos.append(halo)
		}
		for x: Float in [-0.62, 0.62] {
			for _ in 0..<2 {
				let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.1, pipeRadius: 0.006))
				let m = Self.material(Self.accent, roughness: 0.3)
				m.emission.contents = Self.accent
				m.emission.intensity = 1.5
				ring.geometry?.materials = [m]
				ring.simdPosition = SIMD3(x, -0.22, 0.4)
				ring.eulerAngles.x = .pi / 2
				ring.isHidden = true
				shaker.addChildNode(ring)
				ripples.append(ring)
			}
		}
	}

	private func setUpLighting() {
		scene.lightingEnvironment.contents = Self.studio()
		scene.lightingEnvironment.intensity = 1.3

		let key = SCNNode()
		key.light = SCNLight()
		key.light?.type = .directional
		key.light?.intensity = 650
		key.light?.color = CGColor(gray: 1, alpha: 1)
		key.eulerAngles = SCNVector3(-0.7, -0.5, 0)
		scene.rootNode.addChildNode(key)

		let camera = SCNCamera()
		camera.fieldOfView = 26
		camera.zNear = 0.1
		camera.zFar = 20
		camera.wantsHDR = true
		// Only emissive parts are bright enough to bloom
		camera.bloomIntensity = 0.8
		camera.bloomThreshold = 1.05
		camera.bloomBlurRadius = 8
		camera.wantsExposureAdaptation = false
		let cameraNode = SCNNode()
		cameraNode.camera = camera
		cameraNode.position = SCNVector3(0, 0.05, 3.9)
		cameraNode.look(at: SCNVector3(0, 0.03, 0))
		cameraNode.name = "camera"
		scene.rootNode.addChildNode(cameraNode)
	}

	var cameraNode: SCNNode? { scene.rootNode.childNode(withName: "camera", recursively: false) }

	/// A soft round glow, fading to nothing at the edge (black as well as clear, for adding)
	private static let glowImage: CGImage? = {
		let size = 128
		guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
			let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
				colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.35), CGColor(gray: 0, alpha: 0)] as CFArray,
				locations: [0, 0.35, 1])
		else { return nil }
		let c = CGPoint(x: size / 2, y: size / 2)
		ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size) / 2, options: [])
		return ctx.makeImage()
	}()

	/// A soft studio for reflections: bright overhead, a couple of softboxes, dark floor
	private static func studio() -> CGImage? {
		let w = 512
		let h = 256
		guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
		else { return nil }
		let colours = [rgb(0.95, 0.96, 1), rgb(0.5, 0.52, 0.56), rgb(0.12, 0.12, 0.13)] as CFArray
		if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours, locations: [0, 0.5, 1]) {
			// Core Graphics' origin is at the bottom
			ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
		}
		ctx.setFillColor(CGColor(gray: 1, alpha: 1))
		ctx.fill(CGRect(x: 60, y: 170, width: 90, height: 50))
		ctx.fill(CGRect(x: 300, y: 180, width: 140, height: 40))
		ctx.setFillColor(CGColor(gray: 0.8, alpha: 1))
		ctx.fill(CGRect(x: 200, y: 140, width: 60, height: 30))
		return ctx.makeImage()
	}

	// MARK: - Each frame

	func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
		apply(state, time: time)
	}

	func apply(_ s: State, time: TimeInterval) {
		rig.simdOrientation = s.orientation

		// Buttons sink in and glow
		for (control, part) in controls {
			let on = s.pressed.contains(control)
			let push: SIMD3<Float> = switch control {
			case .l1, .r1: SIMD3(0, -0.014, 0)
			// The touchpad was cut out of the shell: moving it opens gaps
			case .touchpad: .zero
			case .ps, .create, .options: SIMD3(0, 0, -0.008)
			default: SIMD3(0, 0, -0.012)
			}
			for (n, rest) in zip(part.nodes, part.rest) {
				n.simdTransform = on ? Self.translation(push) * rest : rest
			}
			switch control {
			case .touchpad:
				// Shown by glows where it's clicked (placeFingers): the pad was cut out of the shell
				// with a ragged top edge, which tinting the whole pad shows up
				break
			case .l1, .r1:
				// White parts turn blue: a glow on white hardly shows
				for m in part.materials {
					m.diffuse.contents = on ? Self.shellPressed : Self.shell
					m.emission.contents = Self.shellPressed
					m.emission.intensity = on ? 0.5 : 0
				}
			default:
				let glow = Self.faceColours[control] ?? Self.accent
				for m in part.materials {
					m.emission.contents = on ? glow : CGColor(gray: 0, alpha: 1)
					m.emission.intensity = on ? 1.4 : 0
				}
			}
		}

		// Sticks tip towards where they're pushed, glowing more the further they go, and sink when clicked
		for (i, part) in sticks.enumerated() {
			let v = i == 0 ? s.leftStick : s.rightStick
			let clicked = s.pressed.contains(i == 0 ? .l3 : .r3)
			let tip = simd_quatf(angle: v.y * 0.4, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: v.x * 0.4, axis: SIMD3(0, 1, 0))
			let pivot = stickPivots[i]
			let move = Self.translation(pivot + SIMD3(0, 0, clicked ? -0.015 : 0)) * simd_float4x4(tip) * Self.translation(-pivot)
			for (n, rest) in zip(part.nodes, part.rest) { n.simdTransform = move * rest }
			let pushed = min(1, simd_length(v))
			for m in part.materials {
				m.emission.contents = Self.accent
				m.emission.intensity = clicked ? 1.4 : (pushed > 0.08 ? CGFloat(0.2 + pushed * 0.7) : 0)
			}
		}

		// Triggers swing in as they're pulled, tinted by the effect on them
		for (i, part) in triggers.enumerated() {
			let pull = i == 0 ? s.l2 : s.r2
			var jitter: Float = 0
			if s.triggerLook == .vibration, pull > 0 { jitter = Float(sin(time * 2 * .pi * 24)) * 0.006 }
			let hinge = triggerHinges[i]
			let swing = Self.translation(hinge + SIMD3(jitter, 0, 0))
				* simd_float4x4(simd_quatf(angle: -0.45 * pull, axis: SIMD3(1, 0, 0))) * Self.translation(-hinge)
			for (n, rest) in zip(part.nodes, part.rest) { n.simdTransform = swing * rest }
			// White, so colour the trigger itself: bluer the further it's pulled, or the effect's colour
			let tint = Self.effectColours[s.triggerLook]
			let base = tint.map { Self.mix(Self.shell, $0, 0.5) } ?? Self.shell
			for m in part.materials {
				if pull > 0.02 {
					m.diffuse.contents = Self.mix(base, Self.shellPressed, CGFloat(0.35 + pull * 0.65))
					m.emission.contents = Self.shellPressed
					m.emission.intensity = CGFloat(0.15 + pull * 0.4)
				} else {
					m.diffuse.contents = base
					m.emission.contents = tint ?? Self.shellPressed
					m.emission.intensity = tint == nil ? 0 : 0.25
				}
			}
		}

		// Glows behind the shoulders and triggers: pressed, pulled, or faintly in the trigger effect's colour
		let effect = Self.effectColours[s.triggerLook]
		for (i, halo) in halos.enumerated() {
			let m = halo.geometry?.firstMaterial
			let amount: Float
			switch i {
			case 0, 1:
				amount = s.pressed.contains(i == 0 ? .l1 : .r1) ? 0.9 : 0
				m?.multiply.contents = Self.shellPressed
			default:
				let pull = i == 2 ? s.l2 : s.r2
				if pull > 0.02 {
					amount = 0.3 + pull * 0.7
					m?.multiply.contents = Self.shellPressed
				} else if let effect {
					amount = 0.3
					m?.multiply.contents = effect
				} else {
					amount = 0
				}
			}
			halo.opacity = CGFloat(amount)
			halo.isHidden = amount == 0
		}

		// Lightbar
		for m in lightbar {
			if let colour = s.lightbar {
				m.diffuse.contents = colour
				m.emission.contents = colour
				m.emission.intensity = 2.2
			} else {
				m.diffuse.contents = Self.lightbarOff
				m.emission.intensity = 0
			}
		}

		// Player lights, in the DualSense's patterns
		let lit: Set<Int> = switch s.player {
		case 1: [2]
		case 2: [1, 3]
		case 3: [0, 2, 4]
		case 4: [0, 1, 3, 4]
		default: []
		}
		for (i, light) in playerLights.enumerated() { light.isHidden = !lit.contains(i) }

		placeFingers(s.touches, clicked: s.pressed.contains(.touchpad))
		shake(s.buzz, time: time)
	}

	/// The touchpad's surface at x, y (0...1 across and down), in the model's coordinates
	private func padSurface(_ pad: SCNNode, x tx: Float, y ty: Float) -> SCNVector3 {
		let (lo, hi) = pad.boundingBox
		let x = Float(lo.x) + tx * Float(hi.x - lo.x)
		let y = Float(hi.y) - ty * Float(hi.y - lo.y)
		let from = SCNVector3(x, y, Float(hi.z) + 1)
		let to = SCNVector3(x, y, Float(lo.z) - 1)
		let surface = pad.hitTestWithSegment(from: from, to: to, options: nil).first?.localCoordinates
			?? SCNVector3(x, y, Float(hi.z))
		return model.convertPosition(surface, from: pad)
	}

	private func placeFingers(_ touches: [Touch], clicked: Bool) {
		guard let pad = touchpadGeometry else { return }
		// Clicked: glow under each finger, or the middle when there are none
		let spots = !clicked ? [] : touches.isEmpty ? [(Float(0.5), Float(0.5))] : touches.map { ($0.x, $0.y) }
		for (i, spot) in clickSpots.enumerated() {
			guard i < spots.count else {
				spot.isHidden = true
				continue
			}
			var p = padSurface(pad, x: spots[i].0, y: spots[i].1)
			p.z += 0.004
			spot.position = p
			spot.isHidden = false
		}
		for (i, dot) in fingers.enumerated() {
			guard i < touches.count else {
				dot.isHidden = true
				continue
			}
			let t = touches[i]
			dot.position = padSurface(pad, x: t.x, y: t.y)
			dot.isHidden = false
			let colour = t.fromScreen ? Self.rgb(0.2, 0.85, 1) : Self.rgb(1, 0.6, 0.15)
			if let m = dot.geometry?.firstMaterial {
				m.diffuse.contents = colour
				m.emission.contents = colour
				m.emission.intensity = 1.5
			}
		}
	}

	/// Where a point on screen lands on the touchpad, 0...1 across and down (outside that range
	/// when it's off the pad), following the controller however it's turned
	func touchpadPoint(_ point: CGPoint, in view: SCNSceneRenderer) -> SIMD2<Float>? {
		guard let pad = touchpadGeometry else { return nil }
		let near = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
		let far = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
		let a = SIMD3<Float>(pad.presentation.convertPosition(near, from: nil))
		let b = SIMD3<Float>(pad.presentation.convertPosition(far, from: nil))
		let (lo, hi) = pad.boundingBox
		// The pad's top surface, as a flat plane
		let surface = Float(hi.z)
		guard abs(b.z - a.z) > 1e-6 else { return nil }
		let t = (surface - a.z) / (b.z - a.z)
		guard t > 0 else { return nil }
		let p = a + (b - a) * t
		return SIMD2((p.x - Float(lo.x)) / Float(hi.x - lo.x), (Float(hi.y) - p.y) / Float(hi.y - lo.y))
	}

	private func shake(_ buzz: Buzz?, time: TimeInterval) {
		guard let buzz else {
			shaker.simdTransform = matrix_identity_float4x4
			ripples.forEach { $0.isHidden = true }
			return
		}
		let amount = max(buzz.left, buzz.right) * (buzz.hz < 20 ? 0.018 : 0.008)
		let phase = time * 2 * .pi * buzz.hz
		shaker.simdPosition = SIMD3(Float(sin(phase)) * amount, Float(cos(phase * 1.3)) * amount * 0.5, 0)
		shaker.simdOrientation = simd_quatf(angle: Float(sin(phase * 0.7)) * amount * 0.6, axis: SIMD3(0, 0, 1))
		for (i, ring) in ripples.enumerated() {
			let side = i / 2
			let level = side == 0 ? buzz.left : buzz.right
			ring.isHidden = level <= 0
			let p = Float((time * 2.2 + Double(i % 2) * 0.5).truncatingRemainder(dividingBy: 1))
			let scale = 0.4 + p * 1.6
			ring.scale = SCNVector3(scale, scale, scale)
			ring.opacity = CGFloat((1 - p) * level * 0.8)
		}
	}

	private static func translation(_ v: SIMD3<Float>) -> simd_float4x4 {
		var m = matrix_identity_float4x4
		m.columns.3 = SIMD4(v, 1)
		return m
	}
}
