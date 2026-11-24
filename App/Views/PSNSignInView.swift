import SwiftUI
import WebKit

/// Sony's sign-in page in a web view. When it redirects back with a code we
/// swap it for the account ID and hand that back. Nothing else is stored.
///
/// Passkeys and third-party password managers (Dashlane etc.) don't work inside
/// an app's web view unless the app owns the website's domain, so there's also
/// a Safari route: sign in there, then paste the URL Sony redirects to.
struct PSNSignInView: View {
	let onAccountID: (String) -> Void
	@Environment(\.dismiss) private var dismiss
	@Environment(\.openURL) private var openURL
	@AppStorage("psnSignInUseSafari") private var useSafari = false
	@State private var pasted = ""
	@State private var working = false
	@State private var error: String?

	var body: some View {
		NavigationStack {
			ZStack {
				if useSafari {
					safariFlow
				} else {
					VStack(spacing: 0) {
						PSNWebView { code in Task { await finish(code: code) } }
						Button {
							useSafari = true
						} label: {
							Label("Passkey or password manager not working? Use Safari", systemImage: "safari")
								.font(.callout)
								.frame(maxWidth: .infinity)
						}
						.padding(12)
						.background(.bar)
					}
				}
				if working {
					Color.black.opacity(0.4).ignoresSafeArea()
					ProgressView("Getting your account ID…")
						.padding()
						.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
				}
			}
			.navigationTitle("Sign in to PSN")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
			}
			.alert("Couldn't get account ID", isPresented: .constant(error != nil)) {
				// In the paste flow, stay put so the URL can be fixed or re-pasted
				Button("OK") { error = nil; if !useSafari { dismiss() } }
			} message: {
				Text(error ?? "")
			}
		}
	}

	private var safariFlow: some View {
		Form {
			Section {
				Button {
					openURL(PSNAuth.loginURL)
				} label: {
					Label("Open PSN sign-in in Safari", systemImage: "safari")
				}
			} footer: {
				Text("Sign in with your passkey or password manager as usual. You'll end up on a blank or error page on remoteplay.dl.playstation.net. That's expected: tap the address bar, copy the whole URL and come back here.")
			}

			Section {
				PasteButton(payloadType: String.self) { strings in
					guard let first = strings.first else { return }
					Task { @MainActor in
						pasted = first
						await submitPasted()
					}
				}
				TextField("https://remoteplay.dl.playstation.net/…?code=…", text: $pasted, axis: .vertical)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.keyboardType(.URL)
					.font(.callout.monospaced())
					.lineLimit(1...4)
				Button("Continue") { Task { await submitPasted() } }
					.disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
			} header: {
				Text("Paste the redirect URL")
			} footer: {
				Text("The code in the URL only works once and expires after a few minutes, so paste it soon after signing in.")
			}

			Section {
				Button("Sign in inside the app instead") { useSafari = false }
					.font(.callout)
			}
		}
	}

	@MainActor
	private func submitPasted() async {
		guard let code = PSNAuth.code(fromPasted: pasted) else {
			error = "That doesn't look like the redirect URL. It should start with \(PSNAuth.redirectPrefix) and contain code=…"
			return
		}
		await finish(code: code)
	}

	@MainActor
	private func finish(code: String?) async {
		guard !working else { return }
		guard let code else {
			error = PSNAuth.Failure.noCode.localizedDescription
			return
		}
		working = true
		do {
			let id = try await PSNAuth.accountID(forCode: code)
			onAccountID(id)
			dismiss()
		} catch {
			self.error = error.localizedDescription
		}
		working = false
	}
}

private struct PSNWebView: UIViewRepresentable {
	let onRedirect: (String?) -> Void

	func makeCoordinator() -> Coordinator { Coordinator(onRedirect: onRedirect) }

	func makeUIView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		// Fresh session every time; we only want the account ID
		config.websiteDataStore = .nonPersistent()
		let web = WKWebView(frame: .zero, configuration: config)
		web.navigationDelegate = context.coordinator
		web.load(URLRequest(url: PSNAuth.loginURL))
		return web
	}

	func updateUIView(_ uiView: WKWebView, context: Context) {}

	final class Coordinator: NSObject, WKNavigationDelegate {
		let onRedirect: (String?) -> Void
		private var done = false

		init(onRedirect: @escaping (String?) -> Void) { self.onRedirect = onRedirect }

		func webView(
			_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
			decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
		) {
			guard let url = action.request.url, url.absoluteString.hasPrefix(PSNAuth.redirectPrefix) else {
				decisionHandler(.allow)
				return
			}
			decisionHandler(.cancel)
			guard !done else { return }
			done = true
			onRedirect(PSNAuth.code(fromRedirect: url))
		}
	}
}
