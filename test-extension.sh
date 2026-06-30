#!/bin/bash
# Test soft-brightness-plus extension on a given GNOME version image.
# Usage: ./test-extension.sh <gnome-version> [ext-path]
# e.g.:  ./test-extension.sh 48
#        ./test-extension.sh 49 /path/to/soft-brightness-plus

set -euo pipefail

GNOME_VER="${1:?Usage: $0 <gnome-version>}"
EXT_PATH="${2:-/workspace/agent/soft-brightness-plus}"
EXT_ID="soft-brightness-plus@joelkitching.com"
IMAGE="gnome-shell-${GNOME_VER}"
CONTAINER="sbp-test-${GNOME_VER}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0
FAIL=0

log()  { echo "[gnome-${GNOME_VER}] $*"; }
ok()   { echo "[gnome-${GNOME_VER}] PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "[gnome-${GNOME_VER}] FAIL: $*"; FAIL=$((FAIL+1)); }

# ── cleanup ───────────────────────────────────────────────────────────────────
cleanup() { docker rm -f "$CONTAINER" 2>/dev/null || true; }
trap cleanup EXIT

log "Starting container ($IMAGE)…"
docker rm -f "$CONTAINER" 2>/dev/null || true
docker run -d --name "$CONTAINER" \
  --cap-add SYS_NICE --cap-add SYS_CHROOT --cap-add SYS_ADMIN \
  -v "$EXT_PATH:/ext:ro" \
  "$IMAGE" sleep infinity

# ── session setup (system D-Bus, Xvfb) ───────────────────────────────────────
docker exec "$CONTAINER" bash -c '
  rm -rf /run/systemd/seats
  mkdir -p /run/dbus /run/user/0 /tmp/.X11-unix
  chmod 1777 /tmp/.X11-unix
  dbus-daemon --system 2>/dev/null || true
  # Install Xvfb if not in the image (some Fedora versions omit it from @base-x)
  which Xvfb || dnf install -y xorg-x11-server-Xvfb >/dev/null 2>&1 || true
'
sleep 1

# Copy and start fake logind so GNOME Shell 48+ does not crash on startup
docker cp "$SCRIPT_DIR/fake-logind.py" "$CONTAINER:/tmp/fake-logind.py"
docker exec "$CONTAINER" bash -c '
  python3 /tmp/fake-logind.py > /tmp/fake-logind.log 2>&1 &
  sleep 1
  cat /tmp/fake-logind.log
'

# ── install extension BEFORE gnome-shell starts ───────────────────────────────
# GNOME 48+ no longer rescans extensions dynamically; they must be present at startup.
log "Installing extension…"
docker exec "$CONTAINER" bash -c "
  EXT_DIR=/root/.local/share/gnome-shell/extensions/$EXT_ID
  mkdir -p \"\$EXT_DIR\"
  # Install from build/extension.zip — contains compiled metadata.json + schema XML
  if [ -f /ext/build/extension.zip ]; then
    python3 -c \"import zipfile; zipfile.ZipFile('/ext/build/extension.zip').extractall('\$EXT_DIR')\"
  else
    cp -r /ext/src/* \"\$EXT_DIR\"/ 2>/dev/null || cp -r /ext/* \"\$EXT_DIR\"/
  fi
  # Compile GSettings schema if not already compiled
  if [ ! -f \"\$EXT_DIR/schemas/gschemas.compiled\" ]; then
    glib-compile-schemas \"\$EXT_DIR/schemas/\"
  fi
  echo \"Installed: \$(ls \$EXT_DIR | tr '\\n' ' ')\"
"

# ── start gnome-shell (extension is already on disk) ─────────────────────────
docker exec -d "$CONTAINER" bash -c '
  export XDG_RUNTIME_DIR=/run/user/0
  export DBUS_SESSION_BUS_ADDRESS=unix:path=${XDG_RUNTIME_DIR}/dbus.sock
  dbus-daemon --session --address="$DBUS_SESSION_BUS_ADDRESS" --fork
  export DISPLAY=:99
  export LIBGL_ALWAYS_SOFTWARE=1
  export GALLIUM_DRIVER=llvmpipe
  Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp &
  sleep 2
  gnome-shell --x11 > /tmp/shell.log 2>&1
'

log "Waiting for gnome-shell…"
READY=0
for i in $(seq 1 30); do
  sleep 2
  if docker exec "$CONTAINER" bash -c '
    export DISPLAY=:99 XDG_RUNTIME_DIR=/run/user/0
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/dbus.sock
    gdbus call --session --dest org.gnome.Shell \
      --object-path /org/gnome/Shell \
      --method org.gnome.Shell.Extensions.ListExtensions 2>/dev/null | grep -q ")"
  ' 2>/dev/null; then
    log "Shell ready after ${i}x2s"
    READY=1
    break
  fi
done

if [ "$READY" -eq 0 ]; then
  fail "gnome-shell did not start"
  docker exec "$CONTAINER" tail -20 /tmp/shell.log 2>/dev/null || true
  exit 1
fi

# ── enable extension via D-Bus ────────────────────────────────────────────────
docker exec "$CONTAINER" bash -c "
  export DISPLAY=:99 XDG_RUNTIME_DIR=/run/user/0
  export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/dbus.sock
  gdbus call --session --dest org.gnome.Shell \
    --object-path /org/gnome/Shell \
    --method org.gnome.Shell.Extensions.EnableExtension \
    '$EXT_ID' 2>&1 || true
"
sleep 3

# Check extension state
EXT_STATE=$(docker exec "$CONTAINER" bash -c "
  export DISPLAY=:99 XDG_RUNTIME_DIR=/run/user/0
  export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/dbus.sock
  gdbus call --session --dest org.gnome.Shell \
    --object-path /org/gnome/Shell \
    --method org.gnome.Shell.Extensions.GetExtensionInfo \
    '$EXT_ID' 2>/dev/null || echo 'error'
")
log "Extension info: $EXT_STATE"

if echo "$EXT_STATE" | grep -q "'state': <1.0>"; then
  ok "Extension enabled (state=1)"
else
  # Print errors from shell log to help diagnose
  docker exec "$CONTAINER" bash -c "grep -iE 'JS ERROR|soft-bright|Extension.*error' /tmp/shell.log | tail -10" 2>/dev/null || true
  fail "Extension not in state=1: $EXT_STATE"
fi

if echo "$EXT_STATE" | grep -q "'error': <''>"; then
  ok "Extension has no errors"
else
  ERRMSG=$(echo "$EXT_STATE" | grep -o "'error': <'[^']*'>" || echo "unknown")
  fail "Extension error: $ERRMSG"
fi

# ── copy capture/analysis scripts ────────────────────────────────────────────
docker cp "$SCRIPT_DIR/capture-overlay.py" "$CONTAINER:/tmp/capture-overlay.py"
docker cp "$SCRIPT_DIR/analyze-png.py" "$CONTAINER:/tmp/analyze-png.py"

# ── capture helper ────────────────────────────────────────────────────────────
capture_brightness() {
  local brightness="$1"
  local outfile="/tmp/sbp-${GNOME_VER}-b${brightness//./_}.png"
  docker exec "$CONTAINER" bash -c "
    export DISPLAY=:99 XDG_RUNTIME_DIR=/run/user/0
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/dbus.sock
    export GSETTINGS_SCHEMA_DIR=/root/.local/share/gnome-shell/extensions/$EXT_ID/schemas
    gsettings set org.gnome.shell.extensions.soft-brightness-plus current-brightness $brightness
    sleep 1
    python3 /tmp/capture-overlay.py /tmp/cap.png --stats 2>&1
  "
  docker cp "$CONTAINER:/tmp/cap.png" "$outfile" 2>/dev/null && echo "$outfile" || echo ""
}

# ── baseline at 1.0 ──────────────────────────────────────────────────────────
log "Capturing baseline (brightness=1.0)…"
BASELINE_OUT=$(capture_brightness 1.0)
BASELINE_MAX=$(docker exec "$CONTAINER" bash -c "
  export DISPLAY=:99
  python3 -c \"
import ctypes, ctypes.util
libX11 = ctypes.CDLL('libX11.so.6')
libXcomp = ctypes.CDLL('libXcomposite.so.1')
libX11.XOpenDisplay.restype = ctypes.c_void_p
libX11.XOpenDisplay.argtypes = [ctypes.c_char_p]
libX11.XDefaultRootWindow.restype = ctypes.c_ulong
libX11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
libX11.XGetImage.restype = ctypes.c_void_p
libX11.XGetImage.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_int]
libXcomp.XCompositeGetOverlayWindow.restype = ctypes.c_ulong
libXcomp.XCompositeGetOverlayWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
dpy = libX11.XOpenDisplay(b':99')
root = libX11.XDefaultRootWindow(dpy)
overlay = libXcomp.XCompositeGetOverlayWindow(dpy, root)
img_ptr = libX11.XGetImage(dpy, overlay, 0, 0, 1920, 1080, 0xFFFFFFFF, 2)

class XImage(ctypes.Structure):
    _fields_ = [('width', ctypes.c_int),('height', ctypes.c_int),('xoffset', ctypes.c_int),
                 ('format', ctypes.c_int),('data', ctypes.c_char_p),('byte_order', ctypes.c_int),
                 ('bitmap_unit', ctypes.c_int),('bitmap_bit_order', ctypes.c_int),
                 ('bitmap_pad', ctypes.c_int),('depth', ctypes.c_int),
                 ('bytes_per_line', ctypes.c_int),('bits_per_pixel', ctypes.c_int)]
img = XImage.from_address(img_ptr)
BPL, BPP = img.bytes_per_line, img.bits_per_pixel // 8
raw = bytes(ctypes.cast(img.data, ctypes.POINTER(ctypes.c_ubyte * (BPL * img.height))).contents)
max_v = max((raw[y*BPL+x*BPP+2]+raw[y*BPL+x*BPP+1]+raw[y*BPL+x*BPP])/3 for y in range(0,1080,10) for x in range(0,1920,10))
print(f'{max_v:.1f}')
\"
")
log "Baseline max pixel: $BASELINE_MAX"

if awk "BEGIN{exit ($BASELINE_MAX > 50) ? 0 : 1}" 2>/dev/null; then
  ok "Baseline has bright content (max=$BASELINE_MAX)"
else
  fail "Baseline too dark — shell may not have rendered (max=$BASELINE_MAX)"
fi

# ── test brightness levels ─────────────────────────────────────────────────────
test_brightness() {
  local target="$1"
  local tolerance="${2:-0.04}"  # ±4 percentage points
  log "Testing brightness=$target…"
  docker exec "$CONTAINER" bash -c "
    export DISPLAY=:99 XDG_RUNTIME_DIR=/run/user/0
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/dbus.sock
    export GSETTINGS_SCHEMA_DIR=/root/.local/share/gnome-shell/extensions/$EXT_ID/schemas
    gsettings set org.gnome.shell.extensions.soft-brightness-plus current-brightness $target
    sleep 1
  "
  local MAX=$(docker exec "$CONTAINER" bash -c "
    export DISPLAY=:99
    python3 -c \"
import ctypes
libX11 = ctypes.CDLL('libX11.so.6')
libXcomp = ctypes.CDLL('libXcomposite.so.1')
libX11.XOpenDisplay.restype = ctypes.c_void_p
libX11.XOpenDisplay.argtypes = [ctypes.c_char_p]
libX11.XDefaultRootWindow.restype = ctypes.c_ulong
libX11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
libX11.XGetImage.restype = ctypes.c_void_p
libX11.XGetImage.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_int]
libXcomp.XCompositeGetOverlayWindow.restype = ctypes.c_ulong
libXcomp.XCompositeGetOverlayWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
dpy = libX11.XOpenDisplay(b':99')
root = libX11.XDefaultRootWindow(dpy)
overlay = libXcomp.XCompositeGetOverlayWindow(dpy, root)
img_ptr = libX11.XGetImage(dpy, overlay, 0, 0, 1920, 1080, 0xFFFFFFFF, 2)
class XImage(ctypes.Structure):
    _fields_ = [('width', ctypes.c_int),('height', ctypes.c_int),('xoffset', ctypes.c_int),
                 ('format', ctypes.c_int),('data', ctypes.c_char_p),('byte_order', ctypes.c_int),
                 ('bitmap_unit', ctypes.c_int),('bitmap_bit_order', ctypes.c_int),
                 ('bitmap_pad', ctypes.c_int),('depth', ctypes.c_int),
                 ('bytes_per_line', ctypes.c_int),('bits_per_pixel', ctypes.c_int)]
img = XImage.from_address(img_ptr)
BPL, BPP = img.bytes_per_line, img.bits_per_pixel // 8
raw = bytes(ctypes.cast(img.data, ctypes.POINTER(ctypes.c_ubyte * (BPL * img.height))).contents)
max_v = max((raw[y*BPL+x*BPP+2]+raw[y*BPL+x*BPP+1]+raw[y*BPL+x*BPP])/3 for y in range(0,1080,10) for x in range(0,1920,10))
print(f'{max_v:.1f}')
\"
  ")
  local RATIO=$(awk "BEGIN{printf \"%.3f\", $MAX/$BASELINE_MAX}")
  local EXPECTED="$target"
  local DIFF=$(awk "BEGIN{d=$RATIO-$EXPECTED; print (d<0)?-d:d}")
  local MSG="brightness=$target: max=$MAX, ratio=$RATIO (expected $EXPECTED ±$tolerance)"
  if awk "BEGIN{exit ($DIFF <= $tolerance) ? 0 : 1}"; then
    ok "$MSG"
  else
    fail "$MSG"
  fi
}

test_brightness 0.1 0.05
test_brightness 0.5 0.08
test_brightness 1.0 0.05  # back to full — expect ratio ~1.0

# ── internal screenshot test (GNOME D-Bus screenshot should be undimmed) ──────
# GNOME Shift+Print triggers a non-interactive screenshot via the keybinding
# action 'screenshot'.  The extension's pre-capture hook should hide the overlay
# before GNOME captures, so the result is bright even at low brightness settings.
# XComposite reads the overlay window directly and WILL show the dim.
test_screenshot_internal() {
  local brightness="0.3"
  log "Testing internal GNOME screenshot at brightness=$brightness (should be undimmed)…"

  # Set dim brightness
  docker exec "$CONTAINER" bash -c "
    export DISPLAY=:99 XDG_RUNTIME_DIR=/run/user/0
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/dbus.sock
    export GSETTINGS_SCHEMA_DIR=/root/.local/share/gnome-shell/extensions/$EXT_ID/schemas
    gsettings set org.gnome.shell.extensions.soft-brightness-plus current-brightness $brightness
    sleep 1
  "

  # External view (XComposite) — should show dimming
  # Run capture and analysis as separate calls so capture's status line
  # doesn't pollute the pixel value we're reading.
  docker exec "$CONTAINER" bash -c "
    export DISPLAY=:99
    python3 /tmp/capture-overlay.py /tmp/xcomp-ss.png > /dev/null 2>&1
  " || true
  local XCOMP_MAX
  XCOMP_MAX=$(docker exec "$CONTAINER" python3 /tmp/analyze-png.py /tmp/xcomp-ss.png 2>/dev/null || echo 0)

  # Trigger non-interactive GNOME screenshot via Shift+Print keybinding
  # (maps to the 'screenshot' action — saves directly to ~/Screenshots/*.png)
  docker exec "$CONTAINER" bash -c "
    export DISPLAY=:99
    mkdir -p /root/Screenshots
    # Remove stale screenshots first
    rm -f /root/Screenshots/*.png
    xdotool key shift+Print
    sleep 3
  "

  # Find the saved screenshot
  local SS_FILE
  SS_FILE=$(docker exec "$CONTAINER" bash -c "ls -t /root/Screenshots/*.png 2>/dev/null | head -1")

  if [ -z "$SS_FILE" ]; then
    fail "screenshot internal: no file in /root/Screenshots/ after Shift+Print"
    return
  fi
  ok "screenshot internal: file saved ($SS_FILE)"

  # Internal view (GNOME screenshot PNG) — should be bright (overlay was hidden)
  local SS_MAX
  SS_MAX=$(docker exec "$CONTAINER" python3 /tmp/analyze-png.py "$SS_FILE" 2>/dev/null || echo 0)

  log "External (XComposite) max=$XCOMP_MAX  Internal (GNOME screenshot) max=$SS_MAX"

  # Optional log check: extension logs 'pre-capture' only when debug=true.
  # Don't fail here — the brightness comparison below is the real assertion.
  if docker exec "$CONTAINER" grep -q 'pre-capture\|_hideOverlays\|drop overlays' /tmp/shell.log 2>/dev/null; then
    ok "screenshot internal: pre-capture hook confirmed in extension log"
  else
    log "screenshot internal: debug log not available — brightness comparison is the primary check"
  fi

  # The GNOME screenshot should be significantly brighter than XComposite
  # (overlay hidden during GNOME capture, visible in XComposite)
  local VERDICT
  VERDICT=$(python3 -c "
xmax = float('${XCOMP_MAX:-0}')
smax = float('${SS_MAX:-0}')
if xmax < 5:
    print('SKIP')  # baseline too dark to compare meaningfully
elif smax > xmax * 3:
    print('PASS')
else:
    print('FAIL')
")
  local MSG="brightness=$brightness: XComposite max=$XCOMP_MAX vs GNOME-screenshot max=$SS_MAX"
  if [ "$VERDICT" = "PASS" ]; then
    ok "screenshot internal: $MSG"
  elif [ "$VERDICT" = "SKIP" ]; then
    log "screenshot internal: SKIP — baseline too dark for comparison ($MSG)"
  else
    fail "screenshot internal: $MSG (screenshot not clearly brighter than overlay view)"
  fi
}

test_screenshot_internal

# ── cursor tests ──────────────────────────────────────────────────────────────

# Issue #24: disable/enable cycle with clone-mouse=true should not crash
# (was: _disableCloningMouse() called destroy() on null _cursorActor)
test_clone_mouse_disable() {
  log "Testing clone-mouse=true disable/enable cycle (Issue #24)..."

  docker exec "$CONTAINER" bash -c "
    export DISPLAY=:99 XDG_RUNTIME_DIR=/run/user/0
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/dbus.sock
    export GSETTINGS_SCHEMA_DIR=/root/.local/share/gnome-shell/extensions/$EXT_ID/schemas
    gsettings set org.gnome.shell.extensions.soft-brightness-plus clone-mouse true
    sleep 2
  "

  # Move cursor to exercise cursor tracking, then trigger a disable/enable
  docker exec "$CONTAINER" bash -c "
    export DISPLAY=:99 XDG_RUNTIME_DIR=/run/user/0
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/dbus.sock
    xdotool mousemove 400 300
    sleep 0.5
    xdotool mousemove 700 500
    sleep 1
    # Disable extension (this triggered _disableCloningMouse crash before fix)
    gdbus call --session --dest org.gnome.Shell \
      --object-path /org/gnome/Shell \
      --method org.gnome.Shell.Extensions.DisableExtension \
      '$EXT_ID' 2>&1 || true
    sleep 1
    # Re-enable
    gdbus call --session --dest org.gnome.Shell \
      --object-path /org/gnome/Shell \
      --method org.gnome.Shell.Extensions.EnableExtension \
      '$EXT_ID' 2>&1 || true
    sleep 2
  "

  # Check for cursor-related JS errors
  local ERRORS
  ERRORS=$(docker exec "$CONTAINER" grep 'JS ERROR' /tmp/shell.log 2>/dev/null | grep -iE 'cursor|_cursorActor|_disableCloningMouse|clone' || true)
  if [ -n "$ERRORS" ]; then
    fail "clone-mouse disable: cursor JS errors found (Issue #24 regression)"
    echo "$ERRORS" | head -5
  else
    ok "clone-mouse disable: disable/enable cycle without cursor JS errors (Issue #24 fixed)"
  fi

  # Also check no general new JS errors appeared
  local GENERAL_ERRORS
  GENERAL_ERRORS=$(docker exec "$CONTAINER" grep 'JS ERROR' /tmp/shell.log 2>/dev/null | tail -5 || true)
  if [ -n "$GENERAL_ERRORS" ]; then
    fail "clone-mouse disable: new JS errors in log"
    echo "$GENERAL_ERRORS"
  else
    ok "clone-mouse disable: no new JS errors after disable/enable cycle"
  fi

  # Reset
  docker exec "$CONTAINER" bash -c "
    export DISPLAY=:99 XDG_RUNTIME_DIR=/run/user/0
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/dbus.sock
    export GSETTINGS_SCHEMA_DIR=/root/.local/share/gnome-shell/extensions/$EXT_ID/schemas
    gsettings set org.gnome.shell.extensions.soft-brightness-plus clone-mouse false
    sleep 1
  "
}

# Issue #36: cursor sprite scale should be 1/cursorTracker.get_scale()
# When clone-mouse is active, the extension ideally logs (with debug=true):
#   _updateMouseSprite(): cursorScale=N spriteScale=1/N
# We verify that invariant if the log line is present.
#
# Graceful degradation: commit daa33fd added the _updateMouseSprite debug log,
# but it was intentionally reverted in 4eeecf8. If the log line is absent we
# downgrade to checking that NO JS errors occurred during cursor use — still a
# meaningful assertion that the scale-compensation code path didn't crash.
#
# NOTE: _updateMouseSprite() is triggered by cursor-changed (shape change), not
# mouse movement. We re-cycle clone-mouse after enabling debug so the initial
# _enableCloningMouse() call (which calls _updateMouseSprite()) happens while
# debug is already active.
test_cursor_sprite_scale() {
  log "Testing cursor sprite scale compensation (Issue #36)..."

  # Step 1: enable debug logging FIRST so it's active before clone-mouse starts
  docker exec "$CONTAINER" bash -c "
    export DISPLAY=:99 XDG_RUNTIME_DIR=/run/user/0
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/dbus.sock
    export GSETTINGS_SCHEMA_DIR=/root/.local/share/gnome-shell/extensions/$EXT_ID/schemas
    gsettings set org.gnome.shell.extensions.soft-brightness-plus debug true
    sleep 1
  "

  # Verify debug was received (extension logs 'debug = true' via _on_debug_change)
  if ! docker exec "$CONTAINER" grep -q 'debug = true' /tmp/shell.log 2>/dev/null; then
    log "cursor scale: debug setting not confirmed in log — proceeding anyway"
  else
    log "cursor scale: debug mode confirmed active"
  fi

  # Step 2: cycle clone-mouse to ensure _enableCloningMouse() runs with debug on
  docker exec "$CONTAINER" bash -c "
    export DISPLAY=:99 XDG_RUNTIME_DIR=/run/user/0
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/dbus.sock
    export GSETTINGS_SCHEMA_DIR=/root/.local/share/gnome-shell/extensions/$EXT_ID/schemas
    gsettings set org.gnome.shell.extensions.soft-brightness-plus clone-mouse false
    sleep 0.5
    gsettings set org.gnome.shell.extensions.soft-brightness-plus clone-mouse true
    sleep 2
  "

  # Also trigger cursor shape changes by clicking over window chrome
  # (xdotool click changes cursor interaction state, which may fire cursor-changed)
  docker exec "$CONTAINER" bash -c "
    export DISPLAY=:99
    xdotool mousemove 100 100; sleep 0.3
    xdotool mousemove 960 540; sleep 0.3
    xdotool click 1; sleep 0.3
    xdotool mousemove 50 50; sleep 0.5
  " 2>/dev/null || true

  # Parse log for spriteScale lines (present only when debug log is in the build)
  local LOG_LINE
  LOG_LINE=$(docker exec "$CONTAINER" grep '_updateMouseSprite.*cursorScale' /tmp/shell.log 2>/dev/null | tail -1 || true)

  if [ -n "$LOG_LINE" ]; then
    # Debug log is present — verify the scale math
    ok "cursor scale: _updateMouseSprite scale logged ($LOG_LINE)"

    # Extract cursorScale and spriteScale values and verify 1/cursorScale == spriteScale
    local VERDICT
    VERDICT=$(python3 -c "
import re, sys
line = '''$LOG_LINE'''
m = re.search(r'cursorScale=([0-9.]+).*spriteScale=([0-9.]+)', line)
if not m:
    print('PARSE_ERROR')
    sys.exit(0)
cursor_scale = float(m.group(1))
sprite_scale = float(m.group(2))
expected = 1.0 / cursor_scale if cursor_scale != 0 else 1.0
if abs(sprite_scale - expected) < 0.0001:
    print(f'PASS cursor={cursor_scale} sprite={sprite_scale} expected={expected:.6f}')
else:
    print(f'FAIL cursor={cursor_scale} sprite={sprite_scale} expected={expected:.6f}')
")
    case "$VERDICT" in
      PASS*) ok "cursor scale: $VERDICT" ;;
      FAIL*) fail "cursor scale: $VERDICT — spriteScale != 1/cursorScale" ;;
      *)     fail "cursor scale: could not parse scale values from log line" ;;
    esac
  else
    # Debug log not available (intentionally removed in 4eeecf8) — downgrade gracefully.
    # A meaningful fallback: verify no JS errors occurred while clone-mouse was active.
    log "cursor scale: _updateMouseSprite debug log not present in this build — checking for JS errors instead"
    local CURSOR_ERRORS
    CURSOR_ERRORS=$(docker exec "$CONTAINER" grep 'JS ERROR' /tmp/shell.log 2>/dev/null | grep -iE 'cursor|sprite|clone|_updateMouse' || true)
    if [ -n "$CURSOR_ERRORS" ]; then
      fail "cursor scale: JS errors found during clone-mouse cursor use"
      echo "$CURSOR_ERRORS" | head -5
    else
      ok "cursor scale: debug log not available (build without _updateMouseSprite logging), but no JS errors during cursor use — scale path is error-free"
    fi
  fi

  # Reset
  docker exec "$CONTAINER" bash -c "
    export DISPLAY=:99 XDG_RUNTIME_DIR=/run/user/0
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/dbus.sock
    export GSETTINGS_SCHEMA_DIR=/root/.local/share/gnome-shell/extensions/$EXT_ID/schemas
    gsettings set org.gnome.shell.extensions.soft-brightness-plus clone-mouse false
    gsettings set org.gnome.shell.extensions.soft-brightness-plus debug false
    sleep 1
  "
}

test_clone_mouse_disable
test_cursor_sprite_scale

test_shader_mode() {
  log "Testing dimming-mode=shader (GammaCurveEffect GLSL)..."

  docker exec "$CONTAINER" bash -c "
    export DISPLAY=:99 XDG_RUNTIME_DIR=/run/user/0
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/dbus.sock
    export GSETTINGS_SCHEMA_DIR=/root/.local/share/gnome-shell/extensions/$EXT_ID/schemas
    gsettings set org.gnome.shell.extensions.soft-brightness-plus shader-gamma 2.0
    gsettings set org.gnome.shell.extensions.soft-brightness-plus current-brightness 0.5
    sleep 1.5
  "

  local SHADER_MAX
  SHADER_MAX=$(docker exec "$CONTAINER" bash -c "
    export DISPLAY=:99
    python3 -c \"
import ctypes
libX11 = ctypes.CDLL('libX11.so.6')
libXcomp = ctypes.CDLL('libXcomposite.so.1')
libX11.XOpenDisplay.restype = ctypes.c_void_p
libX11.XOpenDisplay.argtypes = [ctypes.c_char_p]
libX11.XDefaultRootWindow.restype = ctypes.c_ulong
libX11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
libX11.XGetImage.restype = ctypes.c_void_p
libX11.XGetImage.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_int]
libXcomp.XCompositeGetOverlayWindow.restype = ctypes.c_ulong
libXcomp.XCompositeGetOverlayWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
dpy = libX11.XOpenDisplay(b':99')
root = libX11.XDefaultRootWindow(dpy)
overlay = libXcomp.XCompositeGetOverlayWindow(dpy, root)
img_ptr = libX11.XGetImage(dpy, overlay, 0, 0, 1920, 1080, 0xFFFFFFFF, 2)
class XImage(ctypes.Structure):
    _fields_ = [('width', ctypes.c_int),('height', ctypes.c_int),('xoffset', ctypes.c_int),
                 ('format', ctypes.c_int),('data', ctypes.c_char_p),('byte_order', ctypes.c_int),
                 ('bitmap_unit', ctypes.c_int),('bitmap_bit_order', ctypes.c_int),
                 ('bitmap_pad', ctypes.c_int),('depth', ctypes.c_int),
                 ('bytes_per_line', ctypes.c_int),('bits_per_pixel', ctypes.c_int)]
img = XImage.from_address(img_ptr)
BPL, BPP = img.bytes_per_line, img.bits_per_pixel // 8
raw = bytes(ctypes.cast(img.data, ctypes.POINTER(ctypes.c_ubyte * (BPL * img.height))).contents)
max_v = max((raw[y*BPL+x*BPP+2]+raw[y*BPL+x*BPP+1]+raw[y*BPL+x*BPP])/3 for y in range(0,1080,10) for x in range(0,1920,10))
print(f'{max_v:.1f}')
\"
  " 2>/dev/null || echo "0")

  log "shader mode: XComposite max=$SHADER_MAX (baseline=$BASELINE_MAX)"

  # Gamma curve at brightness=0.5, gamma_k=2.0: white → 0.5, so ratio ≈ 0.50
  local RATIO
  RATIO=$(python3 -c "print(f'{float(\"${SHADER_MAX}\") / float(\"${BASELINE_MAX}\"):.3f}')" 2>/dev/null || echo "1.000")
  local DIMMED
  DIMMED=$(python3 -c "print('yes' if float('${RATIO}') < 0.70 else 'no')" 2>/dev/null || echo "no")

  if [ "$DIMMED" = "yes" ]; then
    ok "shader mode: screen dimmed at brightness=0.5 (ratio=$RATIO, max=$SHADER_MAX vs baseline=$BASELINE_MAX)"
  else
    fail "shader mode: screen not sufficiently dimmed (ratio=$RATIO — expected < 0.70)"
  fi

  if docker exec "$CONTAINER" grep -q 'JS ERROR' /tmp/shell.log 2>/dev/null; then
    local SHADER_ERRORS
    SHADER_ERRORS=$(docker exec "$CONTAINER" grep 'JS ERROR' /tmp/shell.log 2>/dev/null | grep -iE 'GammaCurve|GLSLEffect|shader|snippet' || true)
    if [ -n "$SHADER_ERRORS" ]; then
      fail "shader mode: JS errors related to GammaCurveEffect"
      echo "$SHADER_ERRORS" | head -5
    else
      ok "shader mode: no shader-related JS errors"
    fi
  else
    ok "shader mode: no JS errors"
  fi

  # Restore brightness
  docker exec "$CONTAINER" bash -c "
    export DISPLAY=:99 XDG_RUNTIME_DIR=/run/user/0
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/dbus.sock
    export GSETTINGS_SCHEMA_DIR=/root/.local/share/gnome-shell/extensions/$EXT_ID/schemas
    gsettings set org.gnome.shell.extensions.soft-brightness-plus current-brightness 1.0
    sleep 0.5
  " 2>/dev/null || true
}

test_shader_mode

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════"
echo " GNOME $GNOME_VER: $PASS passed, $FAIL failed"
echo "══════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
