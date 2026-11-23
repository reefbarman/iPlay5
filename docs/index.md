---
layout: default
title: PS5 Remote Play for iPhone and iPad
---

<div class="hero">
  <img class="hero-icon" src="{{ '/images/app-icon.png' | relative_url }}" alt="iPlay5, a PS5 Remote Play app for iPhone and iPad">
  <h1>PS5 Remote Play for iPhone and iPad</h1>
  <p class="hero-lead">iPlay5 is a free, open-source Remote Play app for your PlayStation 5, with DualSense haptics, gyro aiming, HDR and up to 1080p60. Tuned for the iPhone Duo, and works on any iPhone or iPad running iOS 17 or later.</p>
  <div class="hero-actions">
    <a class="btn btn-primary fs-5" href="#install">Install iPlay5</a>
    <a class="btn fs-5" href="https://github.com/reefbarman/iPlay5">View on GitHub</a>
  </div>
</div>

<div class="hero-shot">
  <img src="{{ '/images/iphone-duo-hero.webp' | relative_url }}" alt="A PS5 game streaming to the iPlay5 Remote Play app on the iPhone Duo with virtual controls visible">
</div>

## Features

<div class="feature-grid">
  <a class="feature-card" href="{{ '/picture.html' | relative_url }}">
    <span class="feature-title">Sharp, low-latency picture</span>
    <p>Hardware H.265/H.264 decoding at native resolution, up to 1080p60 and 200 Mbps, with HDR10, MetalFX and 120 Hz.</p>
  </a>
  <a class="feature-card" href="{{ '/controllers.html' | relative_url }}">
    <span class="feature-title">Full DualSense support</span>
    <p>Touchpad, motion, haptics, adaptive triggers and the lightbar all follow the game. Xbox controllers and Backbone work too.</p>
  </a>
  <a class="feature-card" href="{{ '/controllers.html#gyro-aiming' | relative_url }}">
    <span class="feature-title">Gyro aiming</span>
    <p>Turn the controller or the phone to aim, even in games without gyro support.</p>
  </a>
  <a class="feature-card" href="{{ '/touch-and-virtual-controls.html' | relative_url }}">
    <span class="feature-title">Virtual controls</span>
    <p>On-screen sticks and buttons when you don't have a controller, and the touchscreen works as the touchpad.</p>
  </a>
  <a class="feature-card" href="{{ '/connection.html' | relative_url }}">
    <span class="feature-title">A connection that looks after itself</span>
    <p>Auto bitrate, one-tap Optimise connection, network smoothing and automatic reconnecting.</p>
  </a>
  <a class="feature-card" href="{{ '/audio.html' | relative_url }}">
    <span class="feature-title">Microphone</span>
    <p>Game and party chat through the phone's mic, with a mute button on the stream.</p>
  </a>
  <a class="feature-card" href="{{ '/consoles-and-setup.html#playing-away-from-home' | relative_url }}">
    <span class="feature-title">Play away from home</span>
    <p>Connect over the internet with a remote address and port forwarding.</p>
  </a>
  <a class="feature-card" href="{{ '/iphone-duo.html' | relative_url }}">
    <span class="feature-title">Made for the iPhone Duo</span>
    <p>Streams on the inner screen, sets up on the outer one, and folding pauses the stream.</p>
  </a>
</div>

## Recommended iPhone Duo setup

<div class="setup-panel">
  <p><strong>Controller: the <a href="https://www.gamesir.hk/">GameSir G8+</a> Bluetooth version</strong> clips onto the Duo well. Avoid the Apple-specific (USB-C) G8, because it doesn't work with the Duo. Pair the G8+ in its iOS mode (blue Home light), where it shows up as "DUOLSHOK 4 Wireless Controller", and iPlay5 uses its built-in gyro for motion controls and gyro aiming.</p>
  <p><strong>Shim:</strong> the G8+'s grip can press the Duo's side button and trigger Siri mid-game. I made a free 3D-printable shim that stops it.</p>
  <div class="setup-actions">
    <a class="btn btn-primary" href="https://makerworld.com/en/models/3648382-iphone-duo-shim-for-gamesir-g8-no-siri-presses">Get the shim on MakerWorld</a>
    <a class="btn" href="https://www.gamesir.hk/">GameSir G8+</a>
    <a class="btn" href="{{ '/iphone-duo.html' | relative_url }}">iPhone Duo guide</a>
  </div>
</div>

## Install

iPlay5 isn't on the App Store. You sideload it with your own Apple ID, and a free Apple ID is enough.

**SideStore or AltStore (recommended, gets updates):** add this source, then install iPlay5 from it:

```
https://raw.githubusercontent.com/reefbarman/iPlay5/main/altstore-source.json
```

**Sideloadly or another signer:** download `iPlay5.ipa` from the [latest release](https://github.com/reefbarman/iPlay5/releases/latest) and install it as you would any other IPA.

Then follow [Consoles and setup](consoles-and-setup.md) to link your PS5. Every feature and setting is covered in the guides in the sidebar.

## Help

Found a bug? [Open an issue](https://github.com/reefbarman/iPlay5/issues/new) with the file from **Settings › Share diagnostics**, and see [Help and troubleshooting](troubleshooting.md) for tips. The [changelog](https://github.com/reefbarman/iPlay5/blob/main/CHANGELOG.md) lists what changed in each release.
