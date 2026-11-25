# Controllers

## Which controllers work

Any controller iOS supports: DualSense, DualShock 4, Xbox controllers, clip-ons like the Backbone, and the GameSir G8+ (see [iPhone Duo](iphone-duo.md#controller)). Pair it in iOS **Settings › Bluetooth** or plug it in.

- Buttons are mapped by position, so the bottom face button is always Cross, whatever it's labelled.
- The Select/View button acts as Create. Turn on **Select button is touchpad click** (Settings › Controller) to make it click the DualSense touchpad instead.
- Hold **Select + Start** for a second during a stream to open the stream menu.
- If you start a stream with no controller connected, iPlay5 waits and connects as soon as one turns up. You can also choose **Use virtual controls**, **Connect without controls**, or **Cancel**.
- The connecting, reconnecting and error screens respond to the controller: ✕ (or A) reconnects, ○ (or B) cancels or closes.
- On the console list, the d-pad or left stick picks a console and ✕ (or A) wakes or plays it.

One controller at a time. Local co-op with several controllers isn't supported.

## The PS button

- The controller's Home/logo button presses PS.
- **iOS 27:** iOS keeps the Home button for its Game Overlay until you let apps use it. The first time you stream with a controller, iPlay5 offers to open that setting (**Use Home as the PS button?** › **Open Settings**). You can find it again under **Settings › Controller › Home Button Settings**. Open it with your controller connected.
- For controllers whose Home button doesn't reach apps, tap the **top-left corner** of the stream to reveal an on-screen PS button.

## Vibration and feedback

Settings › Controller › Vibration. **Rumble** is the master switch for everything below (on by default). **Controller vibration** sets how strongly a controller's motors play rumble and haptics: Full (default), Medium or Light.

iOS can't play DualSense haptics through the DualSense's own haptic actuators, so iPlay5 turns them into rumble. Very faint haptic textures, which a DualSense on a PS5 barely plays, are ignored so they don't become a constant buzz.

**DualSense**
- Haptics play on the grips with the game's texture and pitch.
- Adaptive triggers get each effect's shape along the trigger's travel (resistance, weapon triggers that give way, vibration). They're released when the stream ends.
- The lightbar and player LEDs follow the game.
- The PS5's own vibration and trigger intensity settings apply.

**DualShock 4:** rumble, and the lightbar follows the game.

**Xbox controllers:** rumble, and the trigger motors play the game's trigger effects, as vibration or a click where a trigger would give way.

**Any other controller with motors** (including the GameSir G8+): rumble.

**On the phone:** with virtual controls, or a controller without motors (like a Backbone), rumble, DualSense haptics and trigger effects play on the phone instead. L2 and R2 (on screen or on the controller) get a click where a weapon trigger gives way, a bump where resistance starts, and vibration while held. **Phone haptics** sets the strength: Full (default), Light or Off. iPads have no vibration motor, so the setting isn't shown there.

## Motion

Settings › Controller › Motion.

- Controllers with a gyro (DualSense, DualShock 4, the GameSir G8+ in its iOS mode, and others iOS reads motion from) send their own motion to the game.
- **Phone gyro for motion controls** (on by default, **iPad gyro for motion controls** on iPad) uses the device's own gyro for virtual controls and controllers without motion sensors.
- When the PS5 asks to recentre motion, iPlay5 does.
- Every gyro reads a little even when it isn't moving, which shows as drift. Whenever the controller is held still for a moment (resting on a table, or steady in your hands), iPlay5 measures that reading and takes it off, for both motion controls and gyro aiming. If the camera drifts right after connecting a controller, hold it still for a second.

## Gyro aiming

Settings › Controller › Gyro aiming. Off by default.

Turns the controller's motion (or the phone's, if the controller has none) into right stick movement, on top of the stick itself. It works in games that don't support gyro. While it's on, motion isn't sent to the game.

| Setting                 | What it does                                                                                                                                         | Default       |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | ------------- |
| Gyro aiming             | Off, Always, While holding L2, While holding R1                                                                                                      | Off           |
| Look left/right by      | Turn and tilt, Turn, or Tilt (like a steering wheel). Tipping the top towards or away from you looks up and down.                                    | Turn and tilt |
| Gyro sensitivity        | 0.25× to 3×                                                                                                                                          | 1×            |
| Up/down speed           | Makes up/down faster than left/right, as most games turn slower vertically. 0.5× to 3×                                                               | 1.5×          |
| Invert gyro up/down     |                                                                                                                                                      | Off           |
| Game dead zone          | How much stick movement the game ignores, so small slow turns still move the camera. Raise it until they do, lower it if the camera creeps. 0 to 40% | 15%           |
| Dead zone per direction | Pushes left/right and up/down past the dead zone separately, so small diagonal corrections aren't lost                                               | Off           |
| Fine aim boost          | Undoes games slowing down small stick movements. Raise it if small corrections feel sluggish, lower it if they overshoot. 1 turns it off.            | 1.5           |

The settings are in the stream menu too, so you can tune them while you play.

## Controller Test

Settings › Controller › Controller Test, also in the stream menu.

- A 3D DualSense that turns as you turn your controller. Hold it the way you normally do and tap **Recentre** to make that front-on. It's remembered per controller.
- Buttons, sticks, triggers and shoulders light up as you press them. Touch the touchpad on screen to test touching the stream (drag to move a finger, tap to click). Fingers on the controller's own touchpad show in orange, the screen's in cyan.
- Live gyro and accelerometer readings. Held still and flat, the gyro should read near zero and Accel Y about +1 g.
- Buttons to try rumble (left, right, both), haptics, adaptive trigger effects (pull L2 or R2 to feel them), lightbar colours and player lights, all through the same path a stream uses.
- Opened from the stream menu, the PS5 sees nothing from your controller while the test is open, and the game's rumble, lights and trigger effects wait until you close it.
