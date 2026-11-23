import AVFoundation
import AVKit
import CoreMedia

/// Picture in Picture for a running stream. Prototype: the stream menu only offers
/// it in debug builds, for H.264 SDR with the mic off.
///
/// Play stays on the Metal renderer. When PiP is requested, the compressed frames
/// also go to an AVSampleBufferDisplayLayer, which AVFoundation decodes itself (our
/// own VideoToolbox session can't decode in the background). Once the layer has a
/// keyframe and AVKit says PiP is possible, it starts. While it's up, Metal gets no
/// frames. When it ends, frames go back to Metal from the next keyframe.
///
/// Main thread, except `route()` and `enqueue(_:keyframe:)`, which the video thread calls.
final class StreamPictureInPicture: NSObject {
	enum Phase: Equatable { case off, preparing, active }

	static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
	/// How long to wait for a first frame and AVKit's go-ahead before giving up
	private static let startTimeout: Double = 4

	/// Hosted behind the Metal layer by the stream view, so AVKit has a source to animate from
	let layer = AVSampleBufferDisplayLayer()
	private(set) var phase: Phase = .off

	/// PiP is taking over: input and mic should let go, Metal stops getting frames
	var onStart: (() -> Void)?
	/// It ended. restored: the user expanded it back into the app.
	var onStop: ((_ restored: Bool) -> Void)?
	/// It couldn't start, with a short message for the user
	var onFail: ((String) -> Void)?
	/// The window's play/pause button. Local picture and sound only, the console keeps going.
	var onPlayingChanged: ((Bool) -> Void)?
	/// Ask the console for a keyframe
	var requestKeyframe: (() -> Void)?

	private let renderer: AVSampleBufferVideoRenderer
	private var timebase: CMTimebase?
	private var controller: AVPictureInPictureController?
	private var possibleObservation: NSKeyValueObservation?
	private var timeout: DispatchWorkItem?
	private var startRequested = false
	private var restoreRequested = false
	private var playing = true

	// Read by the video thread, under `lock`
	private let lock = NSLock()
	private var feeding = false
	private var drawsInline = true
	private var needsKeyframe = true
	private var sending = true
	private var hasFrame = false

	override init() {
		renderer = layer.sampleBufferRenderer
		super.init()
		layer.videoGravity = .resizeAspect
		layer.backgroundColor = UIColor.black.cgColor
		var timebase: CMTimebase?
		CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
		self.timebase = timebase
		layer.controlTimebase = timebase
		resetTimebase(running: true)
	}

	deinit {
		timeout?.cancel()
		possibleObservation?.invalidate()
	}

	// MARK: - Main thread

	/// From the user's tap: `onStart` or `onFail` follows
	func start() {
		guard phase == .off else { return }
		guard Self.isSupported else {
			onFail?("Picture in Picture isn't available on this device.")
			return
		}
		guard layer.superlayer != nil else {
			onFail?("Picture in Picture couldn't start.")
			return
		}
		phase = .preparing
		startRequested = false
		restoreRequested = false
		playing = true
		resetTimebase(running: true)
		renderer.flush(removingDisplayedImage: true, completionHandler: nil)
		lock.withLock {
			feeding = true
			drawsInline = true
			needsKeyframe = true
			sending = true
			hasFrame = false
		}

		let controller = AVPictureInPictureController(
			contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self))
		controller.delegate = self
		controller.requiresLinearPlayback = true
		self.controller = controller
		possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
			DispatchQueue.main.async { self?.startIfReady() }
		}
		let work = DispatchWorkItem { [weak self] in
			guard let self, self.phase == .preparing else { return }
			log.error("Picture in Picture: timed out waiting to start")
			self.fail("Picture in Picture didn't start. Try again.")
		}
		timeout = work
		DispatchQueue.main.asyncAfter(deadline: .now() + Self.startTimeout, execute: work)
		log.notice("Picture in Picture: preparing")
		requestKeyframe?()
	}

	/// Ends PiP (or a start that's on its way). An active window reports `onStop` once it's gone.
	func stop() {
		switch phase {
		case .off: break
		case .preparing:
			reset()
			phase = .off
		case .active:
			controller?.stopPictureInPicture()
		}
	}

	private func startIfReady() {
		guard phase == .preparing, !startRequested, let controller,
			controller.isPictureInPicturePossible, lock.withLock({ hasFrame })
		else { return }
		startRequested = true
		log.notice("Picture in Picture: starting")
		controller.startPictureInPicture()
	}

	private func fail(_ message: String) {
		reset()
		phase = .off
		onFail?(message)
	}

	/// Back to Metal only
	private func reset() {
		timeout?.cancel()
		timeout = nil
		possibleObservation?.invalidate()
		possibleObservation = nil
		controller?.delegate = nil
		controller = nil
		lock.withLock {
			feeding = false
			drawsInline = true
			needsKeyframe = true
			hasFrame = false
		}
		renderer.flush(removingDisplayedImage: true, completionHandler: nil)
	}

	private func resetTimebase(running: Bool) {
		guard let timebase else { return }
		CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
		CMTimebaseSetRate(timebase, rate: running ? 1 : 0)
	}

	// MARK: - Video thread

	/// Where the next frame goes: the PiP layer, Metal, or both while PiP starts
	func route() -> (pictureInPicture: Bool, draw: Bool) {
		lock.withLock { (feeding, drawsInline) }
	}

	/// Returns false to ask for a keyframe
	func enqueue(_ sample: CMSampleBuffer, keyframe: Bool) -> Bool {
		lock.lock()
		guard feeding, sending else {
			lock.unlock()
			return true
		}
		if needsKeyframe {
			// Already asked for one: start from it, not mid-way through a group of frames
			guard keyframe else {
				lock.unlock()
				return true
			}
			needsKeyframe = false
		}
		lock.unlock()

		if renderer.status == .failed || renderer.requiresFlushToResumeDecoding || !renderer.isReadyForMoreMediaData {
			// Behind or broken: drop what's queued and pick up from a keyframe, not a backlog
			renderer.flush()
			if !keyframe {
				lock.withLock { needsKeyframe = true }
				return false
			}
		}
		if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
			CFArrayGetCount(attachments) > 0
		{
			let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
			CFDictionarySetValue(
				dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
				Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
		}
		renderer.enqueue(sample)

		let first = lock.withLock {
			defer { hasFrame = true }
			return !hasFrame
		}
		if first {
			DispatchQueue.main.async { [weak self] in self?.startIfReady() }
		}
		return true
	}
}

// MARK: - AVKit

extension StreamPictureInPicture: AVPictureInPictureControllerDelegate {
	func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
		guard controller === self.controller else { return }
		timeout?.cancel()
		timeout = nil
		phase = .active
		lock.withLock { drawsInline = false }
		log.notice("Picture in Picture: started")
		onStart?()
	}

	func pictureInPictureController(
		_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error
	) {
		guard controller === self.controller else { return }
		log.error("Picture in Picture failed to start: \(error.localizedDescription, privacy: .public)")
		fail("Picture in Picture couldn't start.")
	}

	func pictureInPictureController(
		_ controller: AVPictureInPictureController,
		restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
	) {
		// The stream screen never went away, so there's nothing to rebuild
		restoreRequested = true
		completionHandler(true)
	}

	func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
		guard controller === self.controller else { return }
		let restored = restoreRequested
		reset()
		phase = .off
		log.notice("Picture in Picture: stopped (\(restored ? "expanded" : "closed", privacy: .public))")
		onStop?(restored)
	}
}

extension StreamPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
	func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
		guard playing != self.playing else { return }
		self.playing = playing
		resetTimebase(running: playing)
		lock.withLock {
			sending = playing
			// Resume at the live edge: nothing queued from before the pause
			if playing { needsKeyframe = true }
		}
		if playing {
			renderer.flush()
			requestKeyframe?()
		}
		onPlayingChanged?(playing)
		controller.invalidatePlaybackState()
	}

	func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
		// Live: no timeline, no seeking
		CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
	}

	func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
		!playing
	}

	func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

	func pictureInPictureController(
		_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void
	) {
		completionHandler()
	}
}
