# HackRGB

A tiny menu bar app for controlling RGB lighting on macOS / Hackintosh - no OpenRGB install, no Terminal skills needed.
It downloads and runs the official OpenRGB release privately in the background and gives you a simple menu: colors, effects, brightness, speed, per-device on/off, launch at login.

**Free, open source, unofficial. Not affiliated with OpenRGB or MSI.**
## Tested on...
My personal computer with an MSI B550M motherboard and Thermaltake fans. macOS Tahoe 26.7.1
## Install
1. Download `HackRGB.command`.
2. Open Terminal and run: `bash ~/Downloads/HackRGB.command`
   (Double-clicking works after you run `chmod +x ~/Downloads/HackRGB.command` once, then right-click > Open.)
3. First run installs everything (about 1-2 minutes, needs internet). A rainbow icon appears in your menu bar.
4. If it says "No devices", go to System Settings > Privacy & Security > Input Monitoring and enable Terminal (and OpenRGB if listed), then relaunch.

Requires macOS 10.15+ and Python 3.8+ (macOS will offer to install Command Line Tools if you don't have it).

## First-time fan setup (addressable fans)
RGB fan headers can't report what's plugged in, so HackRGB asks you once. Click the rainbow icon > **Fan Setup...**, then for each header (e.g. JRAINBOW1) type your LED count (`48`, or `3x16` for 3 fans with 16 LEDs each, `0` if empty), or type `find` and click when a travelling light disappears. Blue lights = LEDs in use, the red one should be the last LED on your last fan. HackRGB remembers it and re-applies it every launch.

If OpenRGB itself pops up a "Zone Initialization" window, you can click **Ignore**, tick "Do not show again", and use Fan Setup instead.

## What works
Anything OpenRGB supports on macOS over USB, which includes many RGB fan hubs and the **USB-connected motherboard RGB controllers on MSI boards**. macOS cannot use SMBus/I2C, so RAM and some ASUS/Gigabyte header controllers will not appear.

Tested on: MSI B550 board (Hackintosh) - *add your own results in the comments*.

## Safety - please read
- HackRGB only uses OpenRGB's **direct** mode (software-driven colors) and limits updates to 10 per second.
- MSI Mystic Light controllers have been **bricked** by other software sending bad commands. Support varies by board. Check your board's support at openrgb.org/devices_1.1.html. Use at your own risk, no warranty.
- 4-pin (12V) RGB headers are single color; 3-pin (5V ARGB) headers support per-LED effects. Never plug a fan into the wrong header type.

## Uninstall
`bash HackRGB.command --uninstall` removes everything (the app, its Python environment, the downloaded OpenRGB, and the login item).

## Credits & license
OpenRGB (GPL-2.0) is downloaded from the official release page and is not bundled. HackRGB's own code is free to use and modify.
