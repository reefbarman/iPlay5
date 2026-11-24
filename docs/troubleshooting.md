# Help and troubleshooting

## Reporting a problem

Right after the problem happens, without closing the app, open **Settings › Share diagnostics** and attach the file to a [GitHub issue](https://github.com/reefbarman/iPlay5/issues/new). **Report a problem on GitHub** in the same section opens a new issue.

The report is plain text, so you can check it before sending. It has the app version, your phone model, screen details, connected controllers, settings and the app's logs since it was opened. IP and MAC addresses, keys, account IDs, console names and remote addresses are removed.

## Controller problems

Open **Settings › Controller › Controller Test** to see exactly what iPlay5 reads from your controller and to try its rumble, haptics, trigger effects and lights. See [Controller Test](controllers.md#controller-test).

On iOS 27, if the Home button opens the Game Overlay instead of the PS5 menu, see [The PS button](controllers.md#the-ps-button).

## Stutter or lost video

- Turn on **Stats** (Settings › Display) to see bitrate, ping and loss.
- Run **Optimise connection** from the stream menu while playing something busy.
- Try **Smooth network hiccups** (Settings › Network).
- Use 5 GHz or 6 GHz Wi-Fi with the PS5 on Ethernet, especially above 100 Mbps.

See [Connection](connection.md) for details.

## Frame capture

Settings › Debug › Frame capture button. Off by default.

Adds a button in the bottom-left corner of the stream that saves the last couple of seconds of frames, real and generated, to **Files › On My iPhone › iPlay5 › Frame captures** (**On My iPad** on iPad). It's for reporting [frame generation](picture.md#frame-generation) problems. It uses up to about 800 MB of memory while on, so leave it off otherwise.

## Known limitations

- **Up to 1080p60.** That's the PS5's Remote Play limit.
- **No PSN internet play.** Away from home, use a [remote address](consoles-and-setup.md#playing-away-from-home) with port forwarding. IPv4 only.
- **One controller.** Local co-op with several controllers isn't supported.
- **Stereo audio.** PlayStation 3D Audio isn't available to Remote Play apps.

- **Not on the App Store.** Free Apple ID installs need refreshing every 7 days, which SideStore and AltStore do in the background.
