#!/bin/bash
# HackRGB - RGB control for macOS / Hackintosh. Self-installing launcher.
# Run: double-click, or in Terminal:  bash HackRGB.command
# Remove everything:                  bash HackRGB.command --uninstall
APP="$HOME/.hackrgb"
PLIST="$HOME/Library/LaunchAgents/com.hackrgb.menubar.plist"

if [ "$1" = "--uninstall" ]; then
  pkill -f "$APP/app.py" 2>/dev/null; pkill -f "$APP/openrgb" 2>/dev/null
  rm -f "$PLIST"; rm -rf "$APP"
  echo "HackRGB removed."; exit 0
fi

mkdir -p "$APP"
cat > "$APP/app.py" <<'PYEOF'
#!/usr/bin/env python3
"""HackRGB menu bar app. Talks to a private background copy of OpenRGB."""
import colorsys, glob, json, math, os, plistlib, socket, subprocess, sys, threading, time
import rumps
from AppKit import NSApplication, NSApplicationActivationPolicyAccessory
try:
    from openrgb import OpenRGBClient
    from openrgb.utils import RGBColor
except ImportError:
    OpenRGBClient = RGBColor = None

HOME = os.path.expanduser("~/.hackrgb")
CONFIG = HOME + "/settings.json"
PORT = 6742
LOGIN_PLIST = os.path.expanduser("~/Library/LaunchAgents/com.hackrgb.menubar.plist")
INTERVAL = 0.1   # max 10 updates/sec: gentle on motherboard RGB controllers
EFFECTS = ["Static", "Breathing", "Rainbow Wave", "Color Cycle", "Comet", "Strobe"]
PRESETS = {"Red": (255, 0, 0), "Orange": (255, 100, 0), "Yellow": (255, 220, 0),
           "Green": (0, 255, 60), "Cyan": (0, 220, 255), "Blue": (0, 70, 255),
           "Purple": (160, 0, 255), "Pink": (255, 0, 140), "White": (255, 255, 255)}


def frame(effect, t, n, base, speed, bright):
    out = []
    for i in range(n):
        if effect == "Static": c = base
        elif effect == "Breathing":
            k = (math.sin(t * speed * 2) + 1) / 2; c = tuple(v * k for v in base)
        elif effect == "Rainbow Wave":
            c = tuple(v * 255 for v in colorsys.hsv_to_rgb((t * speed * .1 + i / n) % 1, 1, 1))
        elif effect == "Color Cycle":
            c = tuple(v * 255 for v in colorsys.hsv_to_rgb((t * speed * .1) % 1, 1, 1))
        elif effect == "Comet":
            k = max(0, 1 - ((t * speed * 3) % n - i) % n / (n * .5)); c = tuple(v * k for v in base)
        else: c = base if int(t * speed * 2) % 2 == 0 else (0, 0, 0)
        out.append(tuple(int(max(0, min(255, v * bright))) for v in c))
    return out


def resizable(z):
    return getattr(z, "leds_max", 0) > getattr(z, "leds_min", 0)


def zkey(d, z):
    return f"{d.name}|{z.name}"


def parse_count(txt, mx):
    t = txt.strip().lower().replace("\u00d7", "x")
    try:
        n = int(t.split("x")[0]) * int(t.split("x")[1]) if "x" in t else int(t)
    except (ValueError, IndexError):
        return None
    return max(0, min(n, mx))


def port_open():
    with socket.socket() as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", PORT)) == 0


def find_binary():
    for p in glob.glob(HOME + "/openrgb/**/OpenRGB", recursive=True):
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p


class HackRGB(rumps.App):
    def __init__(self):
        super().__init__("🌈", quit_button=None)
        self.s = dict(color=[0, 150, 255], effect="Static", speed=1.0, bright=1.0, zones={})
        try: self.s.update(json.load(open(CONFIG)))
        except Exception: pass
        self.devs, self.all_devs, self.enabled, self.proc = [], [], {}, None
        self.paused = False
        self.ready = self.shown = False
        self.msg = "Starting…"
        self.status = rumps.MenuItem(self.msg)
        self.login_item = rumps.MenuItem("Launch at Login", callback=self.toggle_login)
        self.login_item.state = int(os.path.exists(LOGIN_PLIST))
        self.dev_menu = rumps.MenuItem("Devices")
        self.dev_menu.add(rumps.MenuItem("(none yet)"))
        self.menu = [
            self.status, None, rumps.MenuItem("Fan Setup…", callback=self.fan_setup), self.dev_menu,
            ["Effect", [rumps.MenuItem(e, callback=self.pick_effect) for e in EFFECTS]],
            ["Color", [rumps.MenuItem(n, callback=self.pick_preset) for n in PRESETS]
                      + [None, rumps.MenuItem("Custom…", callback=self.pick_custom)]],
            ["Brightness", [rumps.MenuItem(f"{p}%", callback=self.pick_bright) for p in (100, 75, 50, 25, 0)]],
            ["Speed", [rumps.MenuItem(n, callback=self.pick_speed) for n in ("Slow", "Medium", "Fast")]],
            None, self.login_item, rumps.MenuItem("Quit", callback=self.quit),
        ]
        self.running = True
        threading.Thread(target=self.connect_loop, daemon=True).start()
        threading.Thread(target=self.engine, daemon=True).start()

    # ---- OpenRGB backend ----
    def connect_loop(self):
        if OpenRGBClient is None:
            self.msg = "openrgb-python missing"; return
        binary = find_binary()
        if not binary:
            self.msg = "OpenRGB files missing - rerun HackRGB.command"; return
        if not port_open():
            log = open(HOME + "/openrgb.log", "w")
            self.proc = subprocess.Popen([binary, "--server", "--startminimized"],
                                         stdout=log, stderr=log)
        client = None
        for _ in range(40):
            try:
                client = OpenRGBClient(address="127.0.0.1", port=PORT, name="HackRGB"); break
            except Exception:
                time.sleep(1)
        if not client:
            self.msg = "Could not reach OpenRGB (see ~/.hackrgb/openrgb.log)"; return
        self.client = client
        self.load_devices(client)
        self.apply_saved_sizes()
        for d in self.devs:
            self.enabled.setdefault(d.name, True)
        todo = [z for d in self.all_devs for z in d.zones
                if resizable(z) and zkey(d, z) not in self.s["zones"] and len(z.leds) == 0]
        if todo:
            self.msg = "Click Fan Setup… to configure your fans"
        elif self.devs:
            self.msg = f"{len(self.devs)} device(s) found"
        else:
            self.msg = "No devices - allow Input Monitoring (see README)"
        self.ready = True

    def load_devices(self, client):
        self.all_devs = list(client.devices)
        self.devs = [d for d in self.all_devs if len(d.leds) > 0]
        for d in self.devs:
            try: d.set_mode("direct")   # direct only; never hardware effect modes
            except Exception: pass

    def reconnect(self):
        try: self.client.disconnect()
        except Exception: pass
        self.client = OpenRGBClient(address="127.0.0.1", port=PORT, name="HackRGB")
        self.load_devices(self.client)

    def apply_saved_sizes(self):
        changed = False
        for d in self.all_devs:
            for z in d.zones:
                n = self.s["zones"].get(zkey(d, z))
                if n is not None and resizable(z) and len(z.leds) != n:
                    try: z.resize(n); changed = True
                    except Exception: pass
        if changed:
            self.reconnect()

    def get_zone(self, key):
        for d in self.all_devs:
            for z in d.zones:
                if zkey(d, z) == key: return z

    # ---- guided fan setup ----
    def fan_setup(self, _):
        if not self.ready:
            rumps.alert("HackRGB", "Still connecting - try again in a few seconds."); return
        zones = [(zkey(d, z), z.name) for d in self.all_devs for z in d.zones if resizable(z)]
        if not zones:
            rumps.alert("HackRGB", "No addressable (3-pin ARGB) fan headers were found on your devices."); return
        self.paused = True
        try:
            for key, name in zones:
                self.setup_zone(key, name)
        except Exception as e:
            rumps.alert("Fan Setup error", str(e))
        finally:
            for d in self.devs: self.enabled.setdefault(d.name, True)
            self.shown = False   # rebuild the Devices submenu
            self.paused = False
        self.msg = f"{len(self.devs)} device(s) found"

    def setup_zone(self, key, name):
        z = self.get_zone(key); mx = min(getattr(z, "leds_max", 200), 200)
        w = rumps.Window(
            message=(f"How many LEDs are on header {name}?\n\n"
                     "Type a number (48), fans x LEDs each (3x16), 0 if nothing is plugged in, "
                     "or  find  to measure with a light test."),
            title="HackRGB Fan Setup", default_text=str(self.s["zones"].get(key, "")),
            ok="Next", cancel="Skip", dimensions=(280, 24))
        r = w.run()
        if not r.clicked: return
        txt = r.text.strip().lower()
        n = self.find_count(key, mx) if txt == "find" else parse_count(txt, mx)
        while n is None:
            r = rumps.Window("Please enter a number like 48 or 3x16.", "HackRGB Fan Setup",
                             ok="Next", cancel="Skip", dimensions=(280, 24)).run()
            if not r.clicked: return
            n = parse_count(r.text, mx)
        while True:
            self.set_size(key, n)
            self.show_pattern(key, n)
            if n == 0 or rumps.alert(
                    f"Check {name}",
                    f"{n} LEDs set. Blue = LEDs in use. The RED light should be the last LED on your last fan.\n\n"
                    "Red too early = enter a higher number. Red missing = enter a lower number.",
                    ok="Looks right", cancel="Adjust") == 1:
                break
            r = rumps.Window("New LED count:", "Adjust", default_text=str(n),
                             ok="Apply", cancel="Keep", dimensions=(280, 24)).run()
            if not r.clicked: break
            m = parse_count(r.text, mx)
            if m is not None: n = m
        self.s["zones"][key] = n; self.save()

    def set_size(self, key, n):
        z = self.get_zone(key)
        if len(z.leds) != n:
            z.resize(n)
            self.reconnect()

    def show_pattern(self, key, n):
        z = self.get_zone(key)
        if n == 0: return
        cols = [RGBColor(0, 0, 255)] * n
        cols[-1] = RGBColor(255, 0, 0)
        z.set_colors(cols)

    def find_count(self, key, mx):
        z = self.get_zone(key)
        z.resize(mx); self.reconnect(); z = self.get_zone(key)
        st = {"i": 0, "stop": False}
        def sweep():
            while not st["stop"]:
                for i in range(mx):
                    if st["stop"]: return
                    cols = [RGBColor(0, 0, 0)] * mx
                    cols[i] = RGBColor(255, 255, 255)
                    try: z.set_colors(cols)
                    except Exception: pass
                    st["i"] = i; time.sleep(0.15)
        threading.Thread(target=sweep, daemon=True).start()
        rumps.alert("Find LED count",
                    "Watch your fans: a single white light will run down the chain.\n\n"
                    "Click the button as soon as the light DISAPPEARS (it has passed the last LED).",
                    ok="It disappeared")
        st["stop"] = True
        return max(1, st["i"] - 4)   # allow ~0.6s reaction time; next screen lets you fine-tune

    # ---- effects ----
    def engine(self):
        t0, last = time.time(), {}
        while self.running:
            time.sleep(INTERVAL)
            if not self.ready or self.paused: continue
            t, s = time.time() - t0, dict(self.s)
            for d in self.devs:
                if not self.enabled.get(d.name): continue
                key = (s["effect"], tuple(s["color"]), s["bright"])
                if s["effect"] == "Static" and last.get(d.name) == key: continue
                last[d.name] = key if s["effect"] == "Static" else None
                try:
                    cols = frame(s["effect"], t, len(d.leds), tuple(s["color"]), s["speed"], s["bright"])
                    d.set_colors([RGBColor(*c) for c in cols])
                except Exception: pass

    @rumps.timer(1)
    def tick(self, _):
        self.status.title = self.msg
        if self.ready and not self.shown:
            self.shown = True
            for k in list(self.dev_menu.keys()): del self.dev_menu[k]
            for d in self.devs:
                it = rumps.MenuItem(d.name, callback=self.toggle_dev); it.state = 1
                self.dev_menu.add(it)

    def toggle_dev(self, item):
        item.state = not item.state; self.enabled[item.title] = bool(item.state)

    # ---- menu callbacks ----
    def save(self): json.dump(self.s, open(CONFIG, "w"))
    def pick_effect(self, i): self.s["effect"] = i.title; self.save()
    def pick_preset(self, i): self.s["color"] = list(PRESETS[i.title]); self.save()
    def pick_bright(self, i): self.s["bright"] = int(i.title[:-1]) / 100; self.save()
    def pick_speed(self, i): self.s["speed"] = {"Slow": .4, "Medium": 1.0, "Fast": 3.0}[i.title]; self.save()

    def pick_custom(self, _):
        r = subprocess.run(["osascript", "-e", "choose color"], capture_output=True, text=True)
        try:
            self.s["color"] = [int(int(v) / 257) for v in r.stdout.strip("{}\n ").split(",")]; self.save()
        except Exception: pass

    def toggle_login(self, item):
        if os.path.exists(LOGIN_PLIST):
            os.remove(LOGIN_PLIST); item.state = 0
        else:
            os.makedirs(os.path.dirname(LOGIN_PLIST), exist_ok=True)
            with open(LOGIN_PLIST, "wb") as f:
                plistlib.dump({"Label": "com.hackrgb.menubar", "RunAtLoad": True,
                               "ProgramArguments": [sys.executable, HOME + "/app.py"]}, f)
            item.state = 1

    def quit(self, _):
        self.running = False
        if self.proc:
            self.proc.terminate()
        rumps.quit_application()


if __name__ == "__main__":
    os.makedirs(HOME, exist_ok=True)
    NSApplication.sharedApplication().setActivationPolicy_(NSApplicationActivationPolicyAccessory)
    HackRGB().run()
PYEOF

fail() { echo; echo "ERROR: $1"; echo "(Details: $APP/install.log)"; read -n 1 -s -r -p "Press any key to close"; exit 1; }

# 1. Python 3
PY="$(command -v python3)"
if [ -z "$PY" ] || ! "$PY" -c "import sys; assert sys.version_info >= (3, 8)" 2>/dev/null; then
  xcode-select --install 2>/dev/null
  fail "Python 3.8+ is required. Accept the 'Command Line Developer Tools' popup, wait for it to finish, then run this again."
fi

# 2. Python packages (verified every launch, repaired automatically)
check_pkgs() { "$APP/venv/bin/python" -c "import rumps, openrgb, AppKit" 2>/dev/null; }
if ! check_pkgs; then
  echo "Installing Python packages (about a minute)..."
  rm -rf "$APP/venv"
  "$PY" -m venv "$APP/venv" > "$APP/install.log" 2>&1 || fail "Could not create the Python environment."
  "$APP/venv/bin/python" -m pip install --upgrade pip >> "$APP/install.log" 2>&1
  "$APP/venv/bin/python" -m pip install rumps openrgb-python >> "$APP/install.log" 2>&1 \
    || fail "Package install failed. Check your internet connection and try again."
  check_pkgs || fail "Packages installed but could not be loaded."
fi

# 3. OpenRGB backend (official release, downloaded - not bundled)
find_bin() { find "$APP/openrgb" -name OpenRGB -type f 2>/dev/null | head -1; }
if [ -z "$(find_bin)" ]; then
  echo "Downloading OpenRGB 1.1 (about 20 MB)..."
  BASE="https://codeberg.org/OpenRGB/OpenRGB/releases/download/release_1.1"
  if [ "$(uname -m)" = "arm64" ]; then FILE="OpenRGB_1.1_MacOS_ARM64_8e16de2.zip"; else FILE="OpenRGB_1.1_MacOS_Intel_8e16de2.zip"; fi
  rm -rf "$APP/openrgb"; mkdir -p "$APP/openrgb"
  curl -L -f -o "$APP/openrgb.zip" "$BASE/$FILE" >> "$APP/install.log" 2>&1 || fail "OpenRGB download failed ($BASE/$FILE)."
  unzip -q -o "$APP/openrgb.zip" -d "$APP/openrgb" >> "$APP/install.log" 2>&1 || fail "Could not unzip OpenRGB."
  rm -f "$APP/openrgb.zip"
  xattr -cr "$APP/openrgb" 2>/dev/null
  [ -z "$(find_bin)" ] && fail "OpenRGB program not found inside the download."
  chmod +x "$(find_bin)"
fi

# 4. Launch
pkill -f "$APP/app.py" 2>/dev/null
nohup "$APP/venv/bin/python" "$APP/app.py" > "$APP/log.txt" 2>&1 &
disown
sleep 3
if pgrep -f "$APP/app.py" > /dev/null; then
  echo "HackRGB is running - look for the rainbow icon in your menu bar."
  osascript -e 'tell application "Terminal" to close front window' >/dev/null 2>&1 &
else
  echo "HackRGB failed to start:"; cat "$APP/log.txt"
  read -n 1 -s -r -p "Press any key to close"
fi
exit 0
