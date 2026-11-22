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
					Text("Tap the top-left corner to reveal the PS button, or the top-right for Settings. Create and Options sit at the bottom centre. Frame Generation is on the right, and Capture is on the left when enabled.")
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
