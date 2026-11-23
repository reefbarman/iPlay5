import SceneKit
import SwiftUI

/// Shows `ControllerScene`, redrawn every frame so shaking and trigger buzz animate smoothly
struct ControllerSceneView: UIViewRepresentable {
	let state: ControllerScene.State

	final class Coordinator {
		let controller = Bundle.main.url(forResource: "DualSense", withExtension: "usdz").flatMap(ControllerScene.init(url:))
	}

	func makeCoordinator() -> Coordinator { Coordinator() }

	func makeUIView(context: Context) -> SCNView {
		let view = SCNView()
		view.backgroundColor = .clear
		view.antialiasingMode = .multisampling4X
		view.preferredFramesPerSecond = 60
		if let controller = context.coordinator.controller {
			view.scene = controller.scene
			view.pointOfView = controller.cameraNode
			view.delegate = controller
			view.rendersContinuously = true
			view.isPlaying = true
		}
		return view
	}

	func updateUIView(_ view: SCNView, context: Context) {
		context.coordinator.controller?.state = state
	}

	static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
		view.isPlaying = false
		view.rendersContinuously = false
	}
}
