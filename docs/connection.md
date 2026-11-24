# Connection

For the most reliable stream, use 5 GHz (or 6 GHz) Wi-Fi with the PS5 wired to the router.

## Auto bitrate

Settings, below Video. On by default.

Remembers the bitrate that works for each console on each Wi-Fi network, so you don't have to keep tuning it.

- A network iPlay5 hasn't seen starts at your **Starting bitrate** (the Bitrate slider).
- After 3 minutes or more of smooth play, the next session starts about a fifth higher, up to 100 Mbps (or your starting bitrate if that's higher).
- After a session of 60 seconds or more that dropped video, the next one starts a quarter lower, and that becomes a ceiling. Three clean sessions just under a ceiling clear it.
- It never changes the bitrate mid-game.
- Moving the bitrate slider while you play, or applying an Optimise connection suggestion, sets the bitrate for that network. In the stream menu the slider is labelled **Bitrate on this network**.
- **Forget learned bitrates** clears everything it has learned.

Networks are told apart by the phone's Wi-Fi subnet, so iPlay5 doesn't need location access to read the network name.

## Optimise connection

Stream menu › Connection › Optimise connection. It only runs when you ask.

It watches the next 20 seconds of the stream for packet loss and lost frames, then suggests a bitrate (and network smoothing, if it would help) that you can apply with one tap, or **Keep current**. Play something with plenty of movement while it checks, because the PS5 sends much less on menus and quiet scenes. With stats showing, the countdown sits in the stats line, and the stream menu can stop the check early.

## Smooth network hiccups

Settings › Network. Off by default. For Wi-Fi that stutters.

- Waits a little longer (up to 40 ms) for video that arrives late.
- Keeps the picture moving, briefly smeared, instead of freezing when a frame is lost.
- Evens out uneven frames by holding one or two back. That costs about 17 ms per frame held, only while the network is acting up. After 10 seconds of calm it goes back to normal.

Advanced stats show what it's doing. Changing it reconnects the stream.

## Takion v20

Settings › Network. Off by default.

Offers the PS5 the newer stream protocol that recent official apps use. The console decides, and the stream stays on the usual protocol if it says no. There's no measured latency gain yet, so treat it as something to compare. Advanced stats show which protocol is in use. Changing it reconnects the stream.

## Reconnecting

- **When a working stream drops,** iPlay5 shows **Connection lost. Reconnecting…** and tries up to three times.
- **When you change a setting that needs a new connection** (resolution, frame rate, bitrate, codec, HDR, network smoothing, Takion v20), it waits 5 seconds, because the PS5 needs time to let go of the old connection, then keeps retrying until it connects or you tap **Cancel**. Several quick changes reconnect once.
- Reconnecting always uses the console's current address, even if it moved since you started.
- If it can't reconnect, the **Disconnected** screen offers **Reconnect** and **Close**.

## Switching apps

The stream stays connected while you're in another app. The picture and controller input pause while you're away.

- With **Settings › Audio › Keep playing in the background** on (the default), the game audio keeps playing and the stream stays connected for as long as you're away. See [Audio](audio.md#keep-playing-in-the-background).
- With it off, or if another app starts playing audio, iOS gives iPlay5 about 30 seconds (sometimes less). Just before that runs out, iPlay5 disconnects cleanly and reconnects when you come back, instead of showing a frozen picture.
