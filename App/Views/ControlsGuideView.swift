import SwiftUI
import UIKit

struct ControlsGuideView: View {
	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				if let diagram = UIImage(named: "VirtualControlsGuide") {
					Image(uiImage: diagram)
						.resizable()
						.scaledToFit()
						.clipShape(RoundedRectangle(cornerRadius: 12))
						.accessibilityLabel("Virtual controls layout on a compact iPhone and the Duo inner screen")
				}

				VStack(alignment: .leading, spacing: 12) {
					Text("Touchpad and sticks").font(.headline)
					Text("Tap the upper half to click the PS5 touchpad, or drag to swipe. When virtual controls are visible, touch open space on either side of the lower half to start a floating stick. L3 and R3 sit diagonally inward from the D-pad and face buttons.")
					Text("Stream shortcuts").font(.headline)
					Text("Tap the top-left corner to reveal the PS button, or the top-right for Settings. Create and Options sit in the lower black bar if there’s room, otherwise at the bottom centre. Tap the bottom-right corner to reveal Frame Generation, then tap again to toggle it. Capture is in the bottom-left corner when enabled.")
				}
			}
			.frame(maxWidth: 680)
			.padding()
			.frame(maxWidth: .infinity)
		}
		.navigationTitle("Controls Guide")
		.navigationBarTitleDisplayMode(.inline)
	}
}
