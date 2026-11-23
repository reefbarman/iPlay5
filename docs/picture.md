# Picture

## Video settings

Settings › Video (also in the stream menu, and per console in [console settings](consoles-and-setup.md#per-console-settings)).

| Setting    | Options             | Default                                                                            |
| ---------- | ------------------- | ---------------------------------------------------------------------------------- |
| Resolution | 720p, 1080p         | 1080p                                                                              |
| Frame rate | 30, 60 fps          | 60 fps                                                                             |
| Bitrate    | 5 to 200 Mbps       | 30 Mbps (the starting point when [Auto bitrate](connection.md#auto-bitrate) is on) |
| Codec      | H.265 (HEVC), H.264 | H.265                                                                              |
| HDR        | On, Off             | Off                                                                                |

- 1080p60 is the PS5's Remote Play limit.
- The PS5 may send less than the bitrate you ask for. Stats show what you're actually getting.
- Above 100 Mbps needs a strong connection, ideally the PS5 on Ethernet and 5 GHz or 6 GHz Wi-Fi, or you may see stutter.
- Changing these reconnects the stream.

Video is decoded by the phone's hardware and drawn with Metal at the screen's native resolution, with each frame going to the screen as soon as it's decoded.

## HDR

HDR sends 10-bit HDR10 straight to the display, and iOS handles the tone mapping. It needs H.265 (the codec picker locks to it) and HDR turned on in the PS5's video output settings. If the stream and the setting don't match, the picture is converted rather than shown with the wrong colours.

## Display

Settings › Display.

- **Picture:** **Fit** shows the whole picture, with black bars where the screen isn't 16:9. **Zoom to fill** fills the screen and crops the overflow.
- **Upscaling:**
  - **Sharp** (default): Catmull-Rom, crisper than a plain resize.
  - **Bilinear:** a plain resize.
  - **MetalFX Spatial:** Apple's upscaler, enlarging the picture to the screen's resolution.
  - **MetalFX 4K:** enlarges to 3840×2160, then scales down to the screen. Can look smoother, but uses more GPU and battery.
  - MetalFX options only appear on devices that support them, and work in SDR and HDR, Fit and Zoom.
- **120 Hz screen** (on by default, ProMotion iPhones only): keeps the display at 120 Hz while streaming, so each frame waits at most about 8 ms for the next refresh instead of about 17 ms. Costs a little battery.

## Frame generation (experimental)

Settings › Display › Frame generation, or the **FG** button in the bottom-right corner of the stream (tap the corner to reveal it, tap again to toggle). Off by default.

- Makes an in-between frame for each pair the PS5 sends, so 30 fps looks like 60 and 60 like 120. It costs half a frame of extra delay.
- 60 fps streams need the 120 Hz screen.
- 30 fps games in a 60 fps stream send each frame twice. iPlay5 spots a steady repeat pattern and generates from 30 to 60 instead.
- It skips the in-between frame across stream hitches, blends on fades instead of inventing motion, and keeps map icons and labels steady.
- If the phone can't keep up (for example when it gets warm), it steps its quality down and back up when there's room.
- Advanced stats show what it's doing.

To report a frame generation problem, see [frame capture](troubleshooting.md#frame-capture).

## Stats

Settings › Display › Stats. Off by default.

- **Simple:** resolution, fps, bitrate, ping and loss on one line.
- **Advanced:** adds codec, decode time, screen refresh rate, lost frames, Takion version, frame generation and network smoothing detail, and the connected controller.

Stats sit in the black bar above the picture when there is one, or float over the top of it. They stay clear of the corner shortcuts and appear once the corner hints fade.
