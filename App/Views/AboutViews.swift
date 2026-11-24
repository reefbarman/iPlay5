import SwiftUI

/// Version, source link and licences. iPlay5 is AGPL-3.0, so every build links to
/// the exact source it was built from (the release tag, or main for local builds).
enum AppInfo {
	private static let info = Bundle.main.infoDictionary

	static var version: String {
		let short = info?["CFBundleShortVersionString"] as? String ?? "?"
		let build = info?["CFBundleVersion"] as? String ?? "?"
		return "\(short) (\(build))"
	}

	static let repository = URL(string: "https://github.com/reefbarman/iPlay5")!
	/// docs/privacy.md on the GitHub Pages site
	static let privacyPolicy = URL(string: "https://reefbarman.github.io/iPlay5/privacy.html")!

	static var sourceURL: URL {
		let ref = (info?["IPlay5SourceRef"] as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 } ?? "main"
		return repository.appending(path: "tree/\(ref)")
	}
}

/// Something bundled into iPlay5, with its licence text in Resources/Licenses
struct OpenSourceComponent: Identifiable {
	let name: String
	let license: String
	let notice: String
	let url: URL
	/// File name (without .txt) in App/Resources/Licenses, written by scripts/update-licenses.sh
	let file: String
	var id: String { name }

	static let all: [OpenSourceComponent] = [
		.init(
			name: "iPlay5", license: "AGPL-3.0-only",
			notice: "Copyright reefbarman and iPlay5 contributors.",
			url: AppInfo.repository, file: "iPlay5"),
		.init(
			name: "chiaki-ng", license: "AGPL-3.0-only",
			notice: "Copyright Florian Märkl and the Chiaki contributors, and streetpea and the chiaki-ng contributors. iPlay5 is built on chiaki-ng's Remote Play library.",
			url: URL(string: "https://github.com/streetpea/chiaki-ng")!, file: "chiaki-ng"),
		.init(
			name: "P5M", license: "AGPL-3.0",
			notice: "Copyright the P5M contributors. iPlay5's Takion v20 support is ported from P5M.",
			url: URL(string: "https://github.com/beecrepaldi-afk/P5M-mac")!, file: "AGPL-3.0"),
		.init(
			name: "Mbed TLS", license: "Apache-2.0",
			notice: "Copyright The Mbed TLS Contributors. iPlay5 uses Mbed TLS under the Apache License 2.0.",
			url: URL(string: "https://github.com/Mbed-TLS/mbedtls")!, file: "MbedTLS"),
		.init(
			name: "Opus", license: "BSD-3-Clause",
			notice: "Copyright Xiph.Org, Skype Limited, Octasic, Jean-Marc Valin, Timothy B. Terriberry, CSIRO, Gregory Maxwell, Mark Borgerding, Erik de Castro Lopo, Mozilla and Amazon.",
			url: URL(string: "https://opus-codec.org")!, file: "Opus"),
		.init(
			name: "nanopb", license: "Zlib",
			notice: "Copyright Petteri Aimonen. Included through chiaki-ng.",
			url: URL(string: "https://github.com/nanopb/nanopb")!, file: "nanopb"),
		.init(
			name: "Jerasure", license: "BSD-3-Clause",
			notice: "Copyright James S. Plank and Kevin Greenan. Included through chiaki-ng.",
			url: URL(string: "https://github.com/streetpea/chiaki-ng/tree/main/third-party/jerasure")!, file: "jerasure"),
		.init(
			name: "GF-Complete", license: "BSD-3-Clause",
			notice: "Copyright James S. Plank, Ethan L. Miller, Kevin M. Greenan, Benjamin A. Arnold, John A. Burnum, Adam W. Disney and Allen C. McBride. Included through chiaki-ng.",
			url: URL(string: "https://github.com/streetpea/chiaki-ng/tree/main/third-party/gf-complete")!, file: "gf-complete"),
	]
}

/// Settings › About
struct AboutSection: View {
	var body: some View {
		Section {
			LabeledContent("Version", value: AppInfo.version)
			Link(destination: AppInfo.sourceURL) {
				Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
			}
			NavigationLink { LicensesView() } label: {
				Label("Licences", systemImage: "doc.text")
			}
			Link(destination: AppInfo.privacyPolicy) {
				Label("Privacy policy", systemImage: "hand.raised")
			}
		} header: {
			Text("About")
		} footer: {
			Text("iPlay5 is free software under the GNU Affero General Public License v3. You can get its source, change it and share it under the same licence. Not affiliated with or endorsed by Sony Interactive Entertainment.")
		}
	}
}

struct LicensesView: View {
	var body: some View {
		List(OpenSourceComponent.all) { component in
			NavigationLink { LicenseTextView(component: component) } label: {
				VStack(alignment: .leading) {
					Text(component.name)
					Text(component.license).font(.caption).foregroundStyle(.secondary)
				}
			}
		}
		.navigationTitle("Licences")
		.navigationBarTitleDisplayMode(.inline)
	}
}

private struct LicenseTextView: View {
	let component: OpenSourceComponent

	private var text: String {
		Bundle.main.url(forResource: component.file, withExtension: "txt")
			.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
			?? "The licence text is missing from this build. See \(component.url.absoluteString)."
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				Text(component.notice)
				Link(component.url.absoluteString, destination: component.url)
				Divider()
				Text(text)
					.font(.footnote.monospaced())
					.textSelection(.enabled)
			}
			.padding()
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.navigationTitle(component.name)
		.navigationBarTitleDisplayMode(.inline)
	}
}
