// Renders the Controller Test's 3D controller to PNGs on a Mac, to check the model and
// materials without a phone:
//
//     swiftc -O App/Views/ControllerScene.swift scripts/controller-model/preview/main.swift -o /tmp/controller-preview
//     /tmp/controller-preview App/Resources/DualSense.usdz /tmp/controller-preview-out
import AppKit
import Metal
import SceneKit
import simd

let args = CommandLine.arguments
guard args.count == 3, let controller = ControllerScene(url: URL(fileURLWithPath: args[1])) else {
	print("usage: controller-preview DualSense.usdz out-dir")
	exit(1)
}
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func dump(_ node: SCNNode, depth: Int = 0) {
	guard depth < 3 else { return }
	let (lo, hi) = node.boundingBox
	print(String(repeating: "  ", count: depth) + (node.name ?? "-"), node.geometry != nil ? "geo" : "",
		String(format: "pos %.3f %.3f %.3f  box %.3f..%.3f %.3f..%.3f %.3f..%.3f", node.position.x, node.position.y, node.position.z,
			lo.x, hi.x, lo.y, hi.y, lo.z, hi.z))
	node.childNodes.forEach { dump($0, depth: depth + 1) }
}
dump(controller.scene.rootNode)

// Like the app in dark mode
controller.scene.background.contents = NSColor(white: 0, alpha: 1)
let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
renderer.scene = controller.scene
renderer.pointOfView = controller.cameraNode

func save(_ name: String, _ state: ControllerScene.State, time: TimeInterval = 0) {
	controller.apply(state, time: time)
	let image = renderer.snapshot(atTime: time, with: CGSize(width: 900, height: 600), antialiasingMode: .multisampling4X)
	guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
		let png = rep.representation(using: .png, properties: [:]) else { return }
	try? png.write(to: out.appendingPathComponent(name + ".png"))
	print("wrote", name)
}

var rest = ControllerScene.State()
save("rest", rest)

var pressed = ControllerScene.State()
pressed.pressed = [.cross, .up, .l1, .r1, .ps, .touchpad, .r3]
pressed.leftStick = SIMD2(0.8, -0.6)
pressed.l2 = 1
pressed.lightbar = CGColor(srgbRed: 0.2, green: 0.4, blue: 1, alpha: 1)
pressed.player = 3
pressed.touches = [.init(x: 0.25, y: 0.4, fromScreen: true), .init(x: 0.75, y: 0.7, fromScreen: false)]
pressed.triggerLook = .resistance
save("pressed", pressed)

// A finger swiping across the pad on screen, and one on the controller's pad, then a snapshot of the trail
var swipe = ControllerScene.State()
for frame in 0...45 {
	let f = Float(frame) / 45
	swipe.touches = [
		.init(x: 0.1 + 0.8 * f, y: 0.5 + 0.3 * sin(f * 6), fromScreen: true),
		.init(x: 0.8 - 0.5 * f, y: 0.2 + 0.1 * f, fromScreen: false),
	]
	controller.apply(swipe, time: 10 + Double(frame) / 60)
}
save("swipe", swipe, time: 10.75)

var turned = pressed
turned.orientation = simd_quatf(angle: 0.5, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: -0.6, axis: SIMD3(0, 1, 0))
turned.buzz = .init(left: 1, right: 1, hz: 16)
save("turned", turned, time: 0.13)
