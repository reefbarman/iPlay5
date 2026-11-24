# Changelog

Every iPlay5 release, written for players. The same notes are on each [GitHub release](https://github.com/reefbarman/iPlay5/releases). For how each feature works, see the [feature guides](docs/README.md).

## v0.14.1 (2026-11-25)

Fixes the picture not coming back after you switch to another app and return to your stream.

### Fixes
- After switching to another app and coming back, the stream could stay connected but every frame failed, so the picture never recovered. Now iPlay5 restarts its video decoding when you return and asks the PS5 for a fresh picture, so the stream comes back within about a second.

## v0.14.0 (2026-11-24)

Switch to another app mid-game without losing your stream. The game audio keeps playing while you're away, so you can check a guide in Safari or lock your phone and pick up right where you left off.

### New
- **Settings › Audio › Keep playing in the background:** on by default. The game audio keeps playing when you switch apps or lock the phone, and the stream stays connected for as long as you're away. The picture and controller pause, and the microphone is muted until you come back. Turn it off if you'd rather the game go quiet when you leave.

### Fixes
- Leaving the app for more than about 30 seconds could close iPlay5 completely, so you came back to the console list instead of your stream. Now iPlay5 disconnects cleanly just before iOS's time limit and reconnects when you return.

### Notes
- If another app starts playing audio (a video guide, for example), iOS takes over the sound and iPlay5 gets the usual 30 seconds or so before it disconnects. It reconnects when you come back.

## v0.13.1 (2026-11-24)

A small follow-up to v0.13.0 so the app can go through TestFlight and the App Store. Nothing changes in how the app works.

### Notes
- Behind-the-scenes fix to how the app declares controller support, needed for App Store builds. DualSense, Xbox and other controllers work exactly as before.

## v0.13.0 (2026-11-24)

iPlay5 now shows its licences and source code in the app, and this is the first build heading to TestFlight and the App Store. Sideloading keeps working exactly as before.

### New
- **Settings › About:** shows the app's version and build, with links to the **Source code** for the exact release you have installed, the **Licences** for iPlay5 and every component it bundles (each opens the full licence text), and the **Privacy policy**.
- **Privacy policy:** iPlay5 collects nothing, and the policy is now published at https://reefbarman.github.io/iPlay5/privacy.html.

### Notes
- **Frame generation** and **Takion v20 protocol** are no longer labelled experimental. They work the same as before.
- The PSN sign-in button is now called **Sign in to PSN**, and its Safari option is **Open PSN sign-in in Safari**.
- iPlay5 is coming to TestFlight and the App Store. Copies installed from different places don't share settings, so a store copy needs its consoles linked again.

## v0.12.1 (2026-11-23)

Fixes gyro drift, so the camera stays put when you hold your controller still, with gyro aiming and with games' own motion controls.

### Fixes
- With gyro aiming, the camera could slowly creep even when the controller was held still, and on some controllers it drifted quite a lot. Every gyro reads a little even at rest, and that reading was being treated as movement. Now, whenever the controller is held still for a moment (resting on a table, or steady in your hands), iPlay5 measures that reading and takes it off. It keeps adjusting as the controller warms up. Games that use the controller's motion themselves get the corrected reading too.

### Notes
- After connecting a controller, hold it still for about a second before aiming so iPlay5 can measure it. Switching controllers starts the measurement over.

## v0.12.0 (2026-11-23)

iPlay5 now runs as a proper iPad app, and the stream screen fits better on every iPhone, not just the iPhone Duo.

### New
- **iPad support:** iPlay5 runs full screen on iPad instead of in a small iPhone-sized window. It works in any orientation, and in Split View and Stage Manager windows. The stream plays in whatever shape the window is, with the picture fitted to it.
- On iPad, messages and settings talk about your iPad rather than your phone. The gyro setting is **iPad gyro for motion controls**, and screenshots and frame captures go to **Files › On My iPad › iPlay5**.

### Fixes
- The "Tap this corner" hints at the start of a stream could run off the edges of smaller iPhones. They now switch to short labels when the full wording doesn't fit.

### Notes
- **Phone haptics** is hidden on devices without a vibration motor, such as iPads. Controller rumble still works.
- On iPhone, the stream still plays in landscape, and on the iPhone Duo it still plays on the inner screen.

## v0.11.1 (2026-11-23)

Adds the iOS 27 Home button setting that was missing from v0.11.0, so your controller's Home button can open the PS5 menu.

### New
- On iOS 27, iOS keeps the controller's Home button for its Game Overlay until you let apps use it. The first time you stream with a controller while that's the case, iPlay5 offers to open the setting. After that, Home opens the PS5 menu. You can find it again under **Settings › Controller › Home Button Settings**.

## v0.11.0 (2026-11-23)

### New
- **Controller Test** (Settings › Controller, and the stream menu): a 3D DualSense that turns as you turn your controller, with every button, stick, trigger and touchpad touch shown live. Buttons try rumble, haptics, adaptive trigger effects, lightbar colours and player lights through the same path a stream uses. Opened from the stream menu, the PS5 sees nothing from your controller until you close it, and the game's rumble and lights come back afterwards.
- **The whole picture is the touchpad** when you play with a controller. With virtual controls showing, the upper half stays the touchpad.
- **Settings pages:** Settings is split into Display, Controller, Virtual controls, Audio, Network and Debug pages, each with a one-line summary of what's set.
- **Controller on the stream's pop-ups:** ✕ (or A) reconnects from the error screen and ○ (or B) cancels or closes the connecting, reconnecting and error screens. The button glyphs show when a controller is connected.

### Notes
- Home Button Settings for iOS 27 was missing from this build. It's in v0.11.1.

## v0.10.1 (2026-11-23)

### Fixes
- DualSense controllers didn't rumble at all, even though adaptive triggers worked. Rumble and haptics from PS5 and PS4 games now play on both grips, and stop when the game stops them.
- If a controller's vibration can't be played, the diagnostics report now says why.

## v0.10.0 (2026-11-23)

### New
- **Remote address** in each console's settings (swipe left on a console and tap Settings, or long-press it and tap Console settings). Enter your home's public IP or a dynamic DNS name. When the console isn't found on the local network, Play and Wake use this address instead, and the console list shows it with a globe icon.
- The console's Ready/Standby status is also checked over the remote address.

### Notes
- Playing away from home needs your router to forward TCP 9295 and UDP 9295, 9296, 9297 and 9302 to the PS5, and the PS5 should have a reserved local IP. IPv4 only.
- The per-console menu item is now called **Console settings**.
- Remote addresses are removed from shared diagnostics reports.

## v0.9.0 (2026-11-22)

### New
- **Gyro aiming** (Settings › Controller › Gyro aiming, off by default): turn the controller, or the phone if your controller has no motion sensors, to move the right stick, even in games without gyro support. Use it always, or only while holding L2 or R1. Tune look direction (turn, tilt or both), sensitivity, up/down speed, the game's dead zone, per-direction dead zone, fine aim boost and inverted up/down.
- **Microphone** (Settings › Audio, off by default): talk in game and party chat through the phone's mic. A mic button in the bottom-left corner of the stream, and the stream menu, mutes it. Echo cancellation only runs when the game plays from the phone's speaker.
- **Auto bitrate** (Settings, on by default): remembers the bitrate that works for each console on each Wi-Fi network, nudging it up after smooth sessions and down after ones that drop video. It never changes mid-game.
- **Optimise connection** in the stream menu: watches 20 seconds of play, then suggests a bitrate and network smoothing setting you can apply with one tap.
- **Settings per console:** give a console its own video and network settings, for example when one PS5 is on Ethernet and another on Wi-Fi.
- **Phone haptics** strength (Full, Light or Off) for virtual controls and controllers without motors.
- **Virtual controls** get Small, Medium and Large sizes, an opacity slider, and Fixed sticks.

### Fixes
- Settings changes now reach a running stream from anywhere in the app, not just the stream menu.
- With stats showing, the connection check countdown sits in the stats line instead of covering it, the result card is centred, and the stream menu can stop a check early.

### Notes
- Auto bitrate is on by default. Your Bitrate setting becomes the starting point on networks iPlay5 hasn't seen yet.
- The first time you turn on Microphone, iOS asks for mic access.

## v0.8.0 (2026-11-22)

### New
- **Full DualSense feedback:** haptics play on the grips with the game's texture and pitch, adaptive triggers get each effect's shape along the trigger's travel, and the lightbar and player LEDs follow the game. The PS5's vibration and trigger intensity settings apply.
- **Xbox trigger motors** play the game's trigger effects, as vibration or a click where a trigger would give way.
- **DualShock 4 lightbar** follows the game.
- **Haptics on the phone:** with virtual controls, or a controller without motors (clip-ons like the Backbone), rumble, haptics and trigger effects play on the phone.
- **Stats picker** (Off, Simple, Advanced) replaces the Show stats switch. Stats sit in the black bar above the picture when there is one.
- **Bitrates up to 200 Mbps.** The PS5 may still cap it lower.
- **Pick a console with your controller:** the d-pad or left stick moves between consoles and ✕ (or A) wakes or plays the selected one.
- **Quick app switches keep the stream.** If iOS ends the app's background time, the stream reconnects when you return instead of showing a frozen picture.

### Fixes
- Frame generation no longer causes occasional hitches in 60 fps games.

### Notes
- Show stats on becomes **Advanced**, off stays **Off**.
- Controls Guide has moved into the Controller section of Settings.
- Above 100 Mbps needs a strong connection, ideally the PS5 on Ethernet and 5 GHz or 6 GHz Wi-Fi.

## v0.7.0 (2026-11-22)

### New
- **Upscaling picker** (Settings › Display) replaces the Sharp upscaling switch: Sharp (the previous default), Bilinear, MetalFX Spatial and MetalFX 4K. MetalFX options only appear on devices that support them, and work with HDR as well as SDR.

### Fixes
- Frame generation no longer drops its quality when MetalFX 4K is on.

### Notes
- Sharp upscaling on becomes **Sharp**, off becomes **Bilinear**.

## v0.6.0 (2026-11-22)

### New
- **Virtual controls:** play without a controller. Sticks start wherever your thumb lands in the lower half, with fixed buttons on both sides. Auto (the default) shows them only when no controller is connected. Starting a stream with no controller asks whether to use virtual controls, connect without controls, or cancel.
- **Controls Guide** with a diagram of the virtual layout and stream shortcuts.
- **Smooth network hiccups** (Settings › Network, off by default): rides out Wi-Fi stutter by waiting a little longer for late video, keeping the picture moving instead of freezing when a frame is lost, and holding back a frame or two to even out uneven arrival. Advanced stats show what it's doing.
- **Screenshots:** Marketing screenshot mode and Save screenshot in the stream menu save a PNG of the stream to Files › On My iPhone › iPlay5.
- A hint in the bottom-right corner shows where to turn frame generation on and off.

### Fixes
- The touchpad is the upper part of the screen, so it doesn't clash with the virtual sticks.
- The PS button and settings corner shortcuts work alongside virtual controls, and Create and Options sit in the black bar below the picture when there's room.
- Share diagnostics shows progress while it prepares the report.

## v0.5.2 (2026-11-22)

### New
- **Takion v20 (experimental, off by default):** offers the PS5 the newer stream protocol that recent official apps use. The console decides, and the stream stays on the usual protocol if it says no. Advanced stats show which one is in use.

### Fixes
- Reconnect and automatic retries now dial the console's current IP address. Before, they kept trying the old one after the console moved, until you closed and reopened the stream.
- Reconnecting for new settings and retries wait 5 seconds first, because the PS5 takes a while to let go of the old connection. Several quick settings changes reconnect once.

## v0.5.1 (2026-11-22)

### Fixes
- Changing a setting that needs a new connection now keeps retrying until it connects (with a Cancel button), instead of dropping to the Disconnected screen.
- Putting the console in rest mode from the stream menu waits for it to close the connection, then returns to the console list.

## v0.5.0 (2026-11-22)

### New
- **Frame generation (experimental):** makes an in-between frame for each pair the PS5 sends, so 30 fps looks like 60 and 60 like 120, for half a frame of extra delay. Turn it on in Settings or with the FG button in the bottom-right corner of the stream. 60 fps needs a 120 Hz screen.
  - 30 fps games in a 60 fps stream are detected and generated from 30 to 60.
  - Map icons and labels stay put, fades blend instead of inventing motion, and it skips in-between frames across stream hitches.
  - It steps its quality down if the phone can't keep up, for example when it gets warm.
- **Frame capture** (Settings › Debug): a button that saves the last couple of seconds of real and generated frames, to help report frame generation problems.

## v0.4.0 (2026-11-21)

### New
- **120 Hz screen** (on by default on ProMotion iPhones): keeps the display at 120 Hz while streaming, so each frame reaches the screen sooner. Stats show the measured refresh rate.

### Fixes
- Adding a new setting in an update no longer resets your existing settings.

## v0.3.1 (2026-11-20)

### New
- **Share diagnostics** in Settings: a plain-text report with your phone, screen, controller and settings details and the app's logs, to attach to a GitHub issue. IP and MAC addresses, keys, account IDs and console names are removed.

### Fixes
- On the iPhone Duo with Display Zoom, the inner screen could be mistaken for the folded outer screen, leaving you stuck on "Open your phone to play". It now measures the screen correctly, and a **Play here anyway** button means a wrong guess can't block you.

## v0.3.0 (2026-11-20)

### New
- **Automatic reconnect:** if a working stream drops, iPlay5 shows "Connection lost. Reconnecting…" and tries up to three times.
- **Type with the iPhone keyboard** when the PS5 opens a text box.
- **Battery and temperature** in the stream menu, with a one-tap switch to 30 fps when the phone gets hot.
- Stats show ping and live packet loss.

### Fixes
- Game audio comes back after phone calls, Siri, and switching between AirPods and the speaker.

## v0.2.1 (2026-11-20)

### Notes
- Updated the bundled encryption (Mbed TLS 3.6 LTS) and audio (Opus 1.6.1) libraries to current supported versions. No visible changes.

## v0.2.0 (2026-11-20)

### New
- **On-screen PS button:** tap the top-left corner of the stream to show it. For controllers like the GameSir G8+ whose Home button doesn't reach the app.

## v0.1.1 (2026-11-20)

The first public release. (v0.1.0 was withdrawn because SideStore and AltStore rejected its bundle ID.)

### New
- **Remote Play over your local network** for any iPhone on iOS 17 or later, built on chiaki-ng.
- **Easy setup:** finds your PS5 on Wi-Fi automatically and follows it if its IP address changes. Sign in to PSN to fill in your account ID, with a Safari option for passkeys and password managers. Link with the PS5's PIN.
- **Console list** with each console's status (ready with the running game, rest mode, not found), Wake from rest mode, and automatic connect once it's awake.
- **Picture:** hardware H.265 and H.264 decoding drawn with Metal at the screen's native resolution, up to 1080p60 and 100 Mbps. Fit or Zoom to fill, and Sharp upscaling.
- **HDR:** 10-bit HDR10 straight to the display.
- **Controllers:** buttons mapped by position, the Home button acts as the PS button, rumble, and the phone's gyro for motion controls when the controller has none. A DualSense's touchpad, motion and adaptive triggers are passed through.
- **Touchscreen as touchpad:** swipe to move a finger, tap to click.
- **Stream menu:** hold Select + Start for a second, or tap the top-right corner, for settings, rest mode and disconnect. Changing video settings reconnects the stream.
- **iPhone Duo:** streams on the inner screen. On the outer screen you can browse, link and wake consoles, and Play connects as soon as you unfold. Folding mid-game pauses the stream.
- **Sideloading:** a SideStore/AltStore source for automatic updates.

### Fixes
- Release builds now use the bundle ID the sideload source advertises, so SideStore and AltStore accept them.
