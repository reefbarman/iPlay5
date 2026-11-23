# Physical controller latency probe

This developer build measures a physical Cross press or release from GameController to the first UDP packet containing that change. Cross is the bottom face button (A on an Xbox controller). It does not measure stick input, when the PS5 receives the button, or when the player sees a response. GameController’s reported event age may exclude controller hardware and Bluetooth or USB transit.

## Run on an iPhone

- [ ] Set up the normal [source build](../README.md#build-from-source), including submodules and local signing. Use Xcode with the iOS 27 SDK or later.
- [ ] Run `bash scripts/build-input-latency-probe.sh` on the Mac. Open `build/input-latency/iPlay5InputLatencyProbe.xcodeproj`, select the physical iPhone and run the `iPlay5InputLatencyProbe` scheme. **iPlay5 Probe** installs alongside the normal app with separate settings, so link the console in the probe app first. Use the same controller and connection type for all runs.
- [ ] Show the device logs in Xcode or macOS Console, filtered to category `input-latency`. Connect to the PS5, let the stream settle, then tap and release Cross 100 times in a repeatable, harmless scene. Do not use Controller Test or pause the app. Disconnect to print the summary before starting the next run.
- [ ] Repeat with **Settings › Display › Stats › Advanced** enabled and reveal the stream controls by touch while tapping Cross. Repeat the quiet run as a drift check. Keep frame rate, bitrate and other stream settings the same. A warm-up that uses Cross should be a separate stream, not part of the measured run.

**First-device check:** Before the comparison runs, try ten isolated taps and disconnect. Look for ten matched downs and ten matched ups. If they are mostly invalid, stop: the callback and the per-button timestamp may not agree on that controller. A Cross edge first observed in a callback for a different control is deliberately excluded, so avoid moving the sticks during this check.

## Read the results

Each clean 100-tap run should have 100 matched downs and 100 matched ups. Watch invalid, masked, unmatched, overflow and recovery counts: if a run loses a substantial share, do not treat its percentiles as representative. The in-memory limit is 512 eligible edges per run. A recovery is a first successful send in a later history packet or a tail resend. It counts as matched, but is not included in the primary-packet percentiles. An idle controller with motion enabled must not produce Cross samples.

| Metric in the log           | Meaning                                                                                                                           |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `event age at entry`        | GameController's age for this button edge, adjusted to the start of the app callback. Not a pure main-queue wait measurement.     |
| `callback duration`         | Wall time in the app callback, including synchronous work it calls.                                                               |
| `entry to socket`           | Callback entry until the local UDP socket accepts the first packet carrying the edge. Not acknowledgement or over-the-air timing. |
| `estimated event to socket` | Event age plus entry-to-socket time. Do **not** add callback duration: the sender can run before the callback returns.            |

Compare p50 (typical) and p95 (slow end) in milliseconds. If only event age grows during UI work, test an alternate input queue next. If entry-to-socket grows, look at pad submission and sender scheduling instead. These measurements alone cannot establish end-to-end latency.

No input payloads are logged. The normal app and release build do not collect these measurements.
