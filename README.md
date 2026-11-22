<p align="center"><img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" alt="iPlay5 icon"></p>

# iPlay5

PS5 Remote Play for iPhone over your local network, built on [chiaki-ng](https://github.com/streetpea/chiaki-ng)'s core. Tuned for the iPhone Duo's near-square inner screen, and works on any iPhone running iOS 17 or later.

> [!IMPORTANT]
> **You need a game controller.** There's no on-screen virtual controller. Any controller iOS supports works: DualSense, DualShock 4, Xbox, Backbone, GameSir, Razer Kishi and so on. The touchscreen acts as the DualSense touchpad.
>
> **iPhone Duo recommendation:** the [GameSir G8+](https://www.gamesir.hk/) **Bluetooth** version works well clipped onto the Duo. Avoid the Apple-specific (USB-C) G8 version, because it doesn't work with the Duo. The G8+ has no gyro, so iPlay5 uses the phone's gyro for motion controls.
>
> **3D-printable shim:** the G8+'s grip can press the Duo's side button and trigger Siri mid-game. I made a free [iPhone Duo shim for the GameSir G8+](https://makerworld.com/en/models/3648382-iphone-duo-shim-for-gamesir-g8-no-siri-presses) on MakerWorld that stops it.

Not affiliated with or endorsed by Sony Interactive Entertainment. "PlayStation" and "PS5" are trademarks of Sony Interactive Entertainment Inc.

## Features

- **Picture:** hardware HEVC/H.264 decode drawn with Metal at the panel's native resolution, up to 1080p60 (the PS5's Remote Play limit) and the highest bitrate the console allows. Sharper Catmull-Rom upscaling.
- **HDR:** 10-bit HDR10 straight to the display with EDR. Toggle it per stream.
- **Fit or Zoom to fill:** see the whole picture with black bars, or fill the screen and crop the overflow.
- **Controllers:** the controller's home/logo button acts as the PS button, and there's an on-screen PS button for controllers that don't have one (or whose button iOS doesn't pass through, like the GameSir G8+). Phone gyro is used for motion controls when your controller has none. Rumble works, and DualSense touchpad, motion and adaptive triggers are passed through (approximate).
- **Touchscreen as touchpad:** swipe to move a finger (up to two), quick tap to click.
- **Easy setup:** finds your PS5 on Wi-Fi automatically and follows it if its IP address changes. Sign in to PSN to fill in your account ID (passkeys and password managers work through the Safari option). Wake from rest mode.
- **Frame generation (experimental):** makes an in-between frame for each pair the PS5 sends, so 30 fps looks like 60 and 60 like 120, for half a frame of extra delay. Tap the bottom-right corner while streaming to turn it on and off and compare.
- **Takion v20 (experimental, off by default):** offers the PS5 the newer stream protocol that recent official apps use. The console decides, and the stream stays on the usual protocol if it says no. There's no measured latency difference yet, so treat it as something to compare rather than a speed-up. Settings › Network.
- **iPhone Duo:** streams on the inner screen, and the stream stays landscape once it's sideways. On the outer screen you can browse, link and wake consoles. Tap Play there and it connects as soon as you unfold. Folding mid-game pauses the stream.

Local network only. PSN internet play isn't included.

## Install

iPlay5 isn't on the App Store. You install the `.ipa` from [Releases](https://github.com/reefbarman/iPlay5/releases) yourself with a sideloading tool, signed with your own Apple ID. A free Apple ID is enough because the app needs no special permissions. Free-account apps expire after 7 days unless they're refreshed, which SideStore and AltStore do in the background.

**SideStore or AltStore (recommended, gets updates):** add this source, then install iPlay5 from it:

```
https://raw.githubusercontent.com/reefbarman/iPlay5/main/altstore-source.json
```

**Sideloadly or another signer:** download `iPlay5.ipa` from the latest release and install it as you would any other IPA.

**Developer account:** if you have a paid Apple Developer account, you can build from source (below) and the app lasts a year.

## First run

1. Put the PS5 and phone on the same network. On the PS5, enable **Settings › System › Remote Play › Enable Remote Play**. To wake it from rest mode, also turn on **Settings › System › Power Saving › Features Available in Rest Mode › Stay Connected to the Internet** and **Enable Turning On PS5 from Network**.
2. Open iPlay5 and allow **Local Network** access when asked. Tap **+**.
3. Your PS5 should appear under Console. If it doesn't, use **Enter IP address manually**.
4. Tap **Sign in with PlayStation** to fill in your account ID. If your passkey or password manager doesn't work in the sign-in window, use the **Safari** option and paste the URL you end up on.
5. On the PS5, open **Settings › System › Remote Play › Link Device**, enter the PIN in the app and tap **Link**.
6. Connect your controller and tap **Play**.

While streaming: tap the top-right corner, then the gear, to open settings. Or hold **Select + Start** for a second. Tap the top-left corner, then the PlayStation logo, to press the PS button.

Start at 1080p60 with H.265. HDR needs H.265 and HDR enabled on the PS5. For the most reliable stream, use 5 GHz Wi-Fi with the PS5 wired to the router.

## Reporting a problem

Right after the problem happens (without closing the app), open **Settings › Share diagnostics** and attach the file to a [GitHub issue](https://github.com/reefbarman/iPlay5/issues/new). It has your phone model, screen details, settings and the app's logs since it was opened. IP addresses, keys, account IDs and console names are removed. It's plain text, so you can check it before sending.

## Build from source

Needs a Mac with Xcode 16 or later and Homebrew.

```sh
brew install cmake ninja xcodegen
git clone --recursive https://github.com/reefbarman/iPlay5.git
cd iPlay5
scripts/build-chiaki.sh                                 # -> Frameworks/ChiakiKit.xcframework
cp Config/Local.xcconfig.example Config/Local.xcconfig  # set your team ID and a bundle ID
xcodegen generate                                       # -> iPlay5.xcodeproj
open iPlay5.xcodeproj                                   # run on your phone
```

To build the same unsigned IPA the releases use, run `scripts/package-ipa.sh`, which writes `build/iPlay5.ipa`. To publish a release, push a `v*` tag. The release workflow builds the IPA, attaches it to a GitHub release and adds it to `altstore-source.json`.

### Layout

| Path             | What                                                                                                                |
| ---------------- | ------------------------------------------------------------------------------------------------------------------- |
| `ChiakiKit/`     | iOS CMake build of chiaki-ng's lib (mbedTLS, Opus, no PSN internet play), plus `ck_bridge`, a small C API for Swift |
| `App/Chiaki/`    | Console discovery (unicast subnet sweep, so no multicast entitlement), wake, registration and PSN sign-in           |
| `App/Streaming/` | Session, VideoToolbox decoder, Metal renderer and shaders, audio, controller and touch input                        |
| `App/Views/`     | SwiftUI screens                                                                                                     |
| `Config/`        | Signing settings. Your team and bundle ID go in the git-ignored `Local.xcconfig`                                    |

`ChiakiKit/generated/takion.pb.*` are pre-generated from chiaki-ng's `lib/protobuf/takion.proto` with nanopb. Regenerate them after bumping chiaki-ng if the proto has changed.

`ChiakiKit/patches/*.patch` are applied to a copy of chiaki-ng's `lib` in the build directory, so the submodule stays untouched. If a chiaki-ng bump makes a patch fail, the CMake configure step stops with the rejected hunks.

## Credits and license

- [chiaki-ng](https://github.com/streetpea/chiaki-ng) and the original [Chiaki](https://git.sr.ht/~thestr4ng3r/chiaki) did the hard work of the Remote Play protocol. PSN sign-in follows chiaki-ng's flow.
- The experimental Takion v20 support is ported from [P5M](https://github.com/beecrepaldi-afk/P5M-mac) (AGPL-3.0), the first open-source client to work out the v20 changes.
- Also bundled: [Mbed TLS](https://github.com/Mbed-TLS/mbedtls) (Apache-2.0), [Opus](https://opus-codec.org) (BSD), and nanopb and jerasure through chiaki-ng.

iPlay5 is licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0-only), the same as chiaki-ng. If you distribute a modified build, you must make its source available under the same license.
