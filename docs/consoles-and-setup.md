# Consoles and setup

## Before you start

On the PS5:

- **Settings › System › Remote Play › Enable Remote Play.**
- To wake it from rest mode, also turn on **Settings › System › Power Saving › Features Available in Rest Mode › Stay Connected to the Internet** and **Enable Turning On PS5 from Network**.

Put the phone and PS5 on the same network. Allow **Local Network** access when iPlay5 asks for it.

## Adding a console

Tap **+** on the console list.

1. **Console:** iPlay5 looks for PS5s on your Wi-Fi and lists them. It searches each address on your subnet directly, so it doesn't need Apple's multicast permission. If yours doesn't appear, use **Enter IP address manually**.
2. **PSN account:** tap **Sign in with PlayStation** to fill in your account ID. Signing in only looks up the ID the PS5 needs for linking. Your password and login aren't stored.
   - If your passkey or password manager doesn't work in the sign-in window, use **Passkey or password manager not working? Use Safari**. Sign in there, copy the URL of the blank or error page you land on, and paste it back into iPlay5. The code in that URL only works once and expires after a few minutes.
3. **Link code:** on the PS5, open **Settings › System › Remote Play › Link Device** and enter the PIN it shows. Tap **Link**.

Linking the same console again replaces its old keys.

## The console list

Each console shows its status:

- **Ready**, or the name of the game that's running.
- **Rest mode** (orange moon). Tap **Wake**, and iPlay5 connects as soon as the console is up.
- **Not found** when it isn't answering. While waking, it shows **Waking…**.

iPlay5 follows a console if its IP address changes on your network, and reconnecting always uses its current address.

**With a controller:** the d-pad or left stick moves between consoles, and ✕ (or A) wakes or plays the selected one. The Play and Wake buttons show which button to press.

Swipe left on a console for **Settings** and **Remove**, or long-press it for the same options.

## Per-console settings

Open a console's settings (swipe left › **Settings**, or long-press › **Console settings**) and turn on **Custom settings** to give it its own video and network settings: resolution, frame rate, bitrate, codec, HDR, network smoothing and Takion v20. This helps when one PS5 is on Ethernet and another on Wi-Fi.

- Custom settings start as a copy of your shared settings, so turning them on changes nothing until you edit them.
- Display and controller settings are always shared.
- While you play that console, changes to video and network settings in the stream menu are saved to it.

## Playing away from home

iPlay5 doesn't use PSN's internet play. Instead, each console can have a **Remote address** in its console settings: your home's public IP or a dynamic DNS name.

- When the console isn't found on the local network, Play and Wake use the remote address. The console list shows it with a globe icon, and the console's Ready/Standby status is checked over it too.
- Your router must forward **TCP 9295** and **UDP 9295, 9296, 9297 and 9302** to the PS5. Give the PS5 a reserved local IP so the forwarding keeps pointing at it.
- IPv4 only.
- Remote addresses are removed from shared diagnostics reports.

Away from home your connection is usually slower and less steady, so a lower bitrate, [Auto bitrate](connection.md#auto-bitrate) and [network smoothing](connection.md#smooth-network-hiccups) help.
