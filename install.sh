#!/usr/bin/env bash
# BC-250 CPU/GPU dashboard installer.
#
# Works on a fresh, never-unlocked BC-250 (installs everything needed and
# leaves the actual unlock actions to be triggered from the dashboard) and on
# an already-unlocked one like this machine (detects what's already in place
# and skips it - safe to re-run any time).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/detect.sh"

PREFIX="/usr/local/share/bc250-dashboard"
CONF="/etc/bc250-dashboard.conf"
RPM_OSTREE_REBOOT_NEEDED=0

echo "== BC-250 dashboard installer =="
echo

# --- 1. environment detection -------------------------------------------
PKG_MGR="$(detect_pkg_manager)"
IMMUTABLE=0
is_immutable && IMMUTABLE=1
echo "Package manager : $PKG_MGR"
echo "Immutable image : $([ "$IMMUTABLE" = 1 ] && echo yes || echo no)"

if ! GOVERNOR_SERVICE="$(detect_governor_service)"; then
    echo "WARNING: no GPU governor service detected (checked: ${GOVERNOR_CANDIDATES[*]})."
    echo "Clock/voltage control will be unavailable until this is set up manually."
    GOVERNOR_SERVICE=""
else
    echo "Governor service: $GOVERNOR_SERVICE"
    if [ "$GOVERNOR_SERVICE" != "oberon-governor.service" ]; then
        echo "  NOTE: this governor variant has not been tested end-to-end by this"
        echo "  installer (only oberon-governor.service has). The /etc/oberon-config.yaml"
        echo "  format is assumed - verify it applies correctly on this system."
    fi
fi
echo

# --- 2. dependencies ------------------------------------------------------
if detect_umr; then
    echo "umr             : already installed"
else
    echo "umr             : NOT installed - installing"
    case "$PKG_MGR" in
        rpm-ostree) install_pkg rpm-ostree umr ;;
        dnf)        install_pkg dnf umr ;;
        *)
            echo "  No known umr package for '$PKG_MGR'. Install WinnieLV/umr manually"
            echo "  and re-run this installer." ;;
    esac
fi

if detect_vulkan_dev; then
    echo "vulkan dev libs : already installed"
else
    echo "vulkan dev libs : NOT installed - installing (needed for the correctness test)"
    case "$PKG_MGR" in
        rpm-ostree) install_pkg rpm-ostree vulkan-headers vulkan-loader-devel ;;
        dnf)        install_pkg dnf vulkan-headers vulkan-loader-devel ;;
        apt)        install_pkg apt libvulkan-dev ;;
        pacman)     install_pkg pacman vulkan-headers vulkan-icd-loader ;;
        *) echo "  Install Vulkan headers + loader-dev manually for your distro." ;;
    esac
fi

if command -v stress >/dev/null 2>&1; then
    echo "stress          : already installed"
else
    echo "stress          : NOT installed - installing (needed for CPU auto-overclock)"
    case "$PKG_MGR" in
        rpm-ostree) install_pkg rpm-ostree stress ;;
        dnf)        install_pkg dnf stress ;;
        apt)        install_pkg apt stress ;;
        pacman)     install_pkg pacman stress ;;
        *) echo "  Install the 'stress' package manually for your distro." ;;
    esac
fi
echo

# --- 3. install vendored/own scripts --------------------------------------
sudo mkdir -p "$PREFIX"
sudo cp "$HERE/vendor/bc250-cu-live-manager.sh" "$PREFIX/"
sudo cp "$HERE/vendor/bc250-compute-verify.sh" "$PREFIX/"
sudo cp "$HERE/scripts/bc250-unlock-cores.py" "$PREFIX/"
sudo cp "$HERE/scripts/bc250-auto-unlock.sh" "$PREFIX/"
sudo cp "$HERE/scripts/gpu-autooc.py" "$PREFIX/"
sudo cp "$HERE/scripts/gpu-undervolt.py" "$PREFIX/"
sudo cp "$HERE/scripts/bc250-graphics-verify.sh" "$PREFIX/"
sudo chmod 755 "$PREFIX"/*.sh "$PREFIX"/*.py

sudo ln -sf "$PREFIX/bc250-cu-live-manager.sh" /usr/local/bin/bc250-cu-live-manager
sudo cp "$HERE/scripts/dash-helpers/"* /usr/local/bin/
sudo chown root:root /usr/local/bin/bc250-dash-*
sudo chmod 755 /usr/local/bin/bc250-dash-*
echo "Installed scripts to $PREFIX and /usr/local/bin"
echo

# --- 3b. CPU auto-overclock tool (bc250_smu_oc, vendored) -----------------
# Installed into its own venv under $PREFIX so it doesn't need root to own
# ~/.local, and so root (via pkexec) can run it without touching a user venv.
if [ -x "$PREFIX/oc-venv/bin/bc250-detect" ]; then
    echo "bc250_smu_oc    : already installed"
else
    echo "bc250_smu_oc    : installing CPU auto-overclock tool"
    sudo python3 -m venv "$PREFIX/oc-venv"
    sudo "$PREFIX/oc-venv/bin/pip" install --quiet "$HERE/vendor/bc250_smu_oc"
fi
echo

# --- 4. runtime config for the dashboard ----------------------------------
sudo tee "$CONF" > /dev/null <<EOF
GOVERNOR_SERVICE=$GOVERNOR_SERVICE
PREFIX=$PREFIX
OBERON_CONF=/etc/oberon-config.yaml
EXPECTED_CPUS=16
EOF
echo "Wrote $CONF"
echo

# --- 5. CPU core-unlock boot service ---------------------------------------
if systemctl is-enabled bc250-core-unlock.service >/dev/null 2>&1; then
    echo "CPU core-unlock service: already installed"
else
    echo "Installing CPU core-unlock boot service"
    sudo tee /etc/systemd/system/bc250-core-unlock.service > /dev/null <<EOF
[Unit]
Description=BC-250 auto core-unlock (checks core count, unlocks+reboots once if needed)
$( [ -n "$GOVERNOR_SERVICE" ] && printf 'After=%s\nRequires=%s\n' "$GOVERNOR_SERVICE" "$GOVERNOR_SERVICE" )

[Service]
Type=oneshot
Environment=UNLOCK_SCRIPT=$PREFIX/bc250-unlock-cores.py
Environment=GOVERNOR=$GOVERNOR_SERVICE
ExecStart=$PREFIX/bc250-auto-unlock.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable bc250-core-unlock.service
fi
echo

# --- 6. GPU CU live-manager boot service ------------------------------------
if systemctl is-enabled bc250-cu-live-manager.service >/dev/null 2>&1; then
    echo "GPU CU live-manager service: already installed"
else
    echo "Installing GPU CU live-manager boot service (won't apply anything until"
    echo "you've enabled CUs at least once from the dashboard - see below)"
    sudo tee /etc/systemd/system/bc250-cu-live-manager.service > /dev/null <<'EOF'
[Unit]
Description=BC-250 CU saved enumeration and dispatch
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
EnvironmentFile=-/etc/bc250-cu-live-manager.conf
ExecStartPre=/usr/bin/bash -c 'for _ in {1..30}; do compgen -G "/dev/dri/renderD*" >/dev/null && exit 0; sleep 1; done; exit 1'
ExecStart=/usr/local/bin/bc250-cu-live-manager --yes apply-service
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable bc250-cu-live-manager.service
fi
echo

# --- 7. WebKitGTK (needed for the pywebview desktop app window) -----------
# Package names vary a lot by distro - best-effort per package manager,
# same spirit as the other dependency installs above.
if python3 -c "import gi; gi.require_version('WebKit2','4.1')" >/dev/null 2>&1; then
    echo "WebKitGTK        : already installed"
else
    echo "WebKitGTK        : NOT installed - installing (needed for the desktop app window)"
    case "$PKG_MGR" in
        rpm-ostree) install_pkg rpm-ostree webkit2gtk4.1 gtk3 python3-gobject ;;
        dnf)        install_pkg dnf webkit2gtk4.1 gtk3 python3-gobject ;;
        apt)        install_pkg apt gir1.2-webkit2-4.1 python3-gi ;;
        pacman)     install_pkg pacman webkit2gtk-4.1 python-gobject ;;
        *) echo "  Install WebKitGTK + PyGObject manually for your distro." ;;
    esac
fi
echo

# --- 8. python venv + dashboard app ----------------------------------------
# --system-site-packages so the venv can see the system PyGObject/gi
# bindings above (pip can't install those cleanly - they need system
# dev headers). Rebuild it if it's missing the flag, OR if it's just
# plain broken - which happens if this whole project folder (including a
# previously-built venv) was copied from another machine instead of being
# freshly set up here. A venv's python3 is usually a symlink to the
# system interpreter that created it, and its installed console scripts
# have that machine's absolute path baked into their shebang line -
# neither survives being copied to a different machine/path, so checking
# the directory merely *exists* isn't enough.
rebuild_venv=0
if [ -d "$HERE/venv" ]; then
    if ! grep -q "include-system-site-packages = true" "$HERE/venv/pyvenv.cfg" 2>/dev/null; then
        echo "Existing venv lacks --system-site-packages - recreating it"
        rebuild_venv=1
    elif ! "$HERE/venv/bin/python3" -c "" >/dev/null 2>&1; then
        echo "Existing venv's python3 doesn't run on this machine (likely copied from elsewhere) - recreating it"
        rebuild_venv=1
    fi
fi
if [ "$rebuild_venv" = 1 ]; then
    rm -rf "$HERE/venv"
fi
if [ ! -d "$HERE/venv" ]; then
    echo "Creating Python venv"
    python3 -m venv --system-site-packages "$HERE/venv"
fi
"$HERE/venv/bin/pip" install --quiet --upgrade pip
"$HERE/venv/bin/pip" install --quiet flask pywebview
echo "Python venv ready"
echo

# --- 9. desktop app launcher -----------------------------------------------
ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
APPS_DIR="$HOME/.local/share/applications"
mkdir -p "$ICON_DIR" "$APPS_DIR"
if [ ! -f "$ICON_DIR/bc250-command-center.png" ] && command -v convert >/dev/null 2>&1; then
    convert -size 256x256 xc:'#191b24' -fill '#6d8cff' -draw "circle 128,128 128,40" \
        -fill white -pointsize 90 -gravity center -annotate +0+0 "BC" \
        "$ICON_DIR/bc250-command-center.png" 2>/dev/null || true
fi
cat > "$APPS_DIR/bc250-command-center.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=BC-250 Command Center
Comment=CPU/GPU unlock and overclock control panel for the BC-250
Exec=$HERE/venv/bin/python3 $HERE/desktop.py
Icon=bc250-command-center
Terminal=false
Categories=System;Utility;
StartupNotify=true
EOF
chmod +x "$APPS_DIR/bc250-command-center.desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" 2>/dev/null || true
echo "Installed app launcher: BC-250 Command Center (check your app menu)"
echo

echo "== Install complete =="
echo
if [ "$RPM_OSTREE_REBOOT_NEEDED" = 1 ]; then
    echo "*** A reboot is required to activate newly-layered packages before"
    echo "*** the dashboard's CU-unlock or correctness-test features will work."
fi
echo
CPU_ONLINE="$(nproc)"
echo "Current state: $CPU_ONLINE CPU(s) online."
echo
echo "Launch it from your application menu: 'BC-250 Command Center'"
echo "(or directly: $HERE/venv/bin/python3 $HERE/desktop.py)"
echo
echo "If this is a FRESH, never-unlocked BC-250: open the dashboard, check the"
echo "CPU and GPU CU status cards, and use their unlock buttons - everything,"
echo "including enabling all 40 GPU CUs, runs entirely through the GUI (each"
echo "action asks for your password separately; no manual terminal commands"
echo "needed). Enabling the CUs automatically runs a correctness test before"
echo "keeping the change - not every board can run all 40, so if that test"
echo "fails it reverts to stock on its own rather than leaving a broken state."
