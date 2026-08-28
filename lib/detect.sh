#!/usr/bin/env bash
# Environment detection helpers for the BC-250 dashboard installer.
# Sourced by install.sh - not meant to be run standalone.

detect_pkg_manager() {
    # rpm-ostree takes priority over dnf: on an ostree/immutable image, dnf
    # is present but installing with it directly doesn't work the way it
    # does on a traditional Fedora install - packages must be layered.
    if command -v rpm-ostree >/dev/null 2>&1; then
        echo "rpm-ostree"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v apt >/dev/null 2>&1; then
        echo "apt"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

is_immutable() {
    command -v rpm-ostree >/dev/null 2>&1 && rpm-ostree status >/dev/null 2>&1
}

# Known governor service name candidates, in the order actually observed in
# the wild. "oberon-governor.service" is the only one this installer has
# been tested against (Bazzite/this hardware); "cyan-skillfish-governor-smu"
# is the name the bc250-cu-live-manager tool itself defaults to expecting,
# per its own upstream docs, but has NOT been verified end-to-end here.
GOVERNOR_CANDIDATES=(
    "oberon-governor.service"
    "cyan-skillfish-governor-smu.service"
)

detect_governor_service() {
    # NOTE: deliberately avoid `grep -q`/`head` at the end of a pipeline here.
    # Under `set -o pipefail` (used by install.sh), a downstream command that
    # exits early (-q stops at first match, head stops after N lines) SIGPIPEs
    # the producer, and pipefail then reports that broken-pipe exit as the
    # pipeline's failure even though the match itself succeeded. Redirecting
    # to /dev/null instead of using -q, and letting output flow through in
    # full, sidesteps that.
    local svc
    for svc in "${GOVERNOR_CANDIDATES[@]}"; do
        if systemctl list-unit-files "$svc" 2>/dev/null | grep -F "$svc" >/dev/null; then
            echo "$svc"
            return 0
        fi
    done
    # Fall back to a fuzzy search in case of an unknown naming variant.
    # `|| true` guards the assignment: under `set -e`, a plain `var=$(...)`
    # whose command substitution exits non-zero (e.g. grep finding nothing,
    # which is an expected outcome here, not an error) would otherwise abort
    # the whole script instead of falling through to `return 1` below.
    svc="$(systemctl list-unit-files 2>/dev/null | grep -i -E 'governor|cyan-skillfish' | awk '{print $1; exit}')" || true
    if [ -n "$svc" ]; then
        echo "$svc"
        return 0
    fi
    return 1
}

detect_umr() {
    command -v umr >/dev/null 2>&1 || [ -x /usr/local/bin/umr ] || [ -x /opt/umr/build/src/app/umr ]
}

detect_vulkan_dev() {
    [ -f /usr/include/vulkan/vulkan.h ] || return 1
    ldconfig -p 2>/dev/null | grep "libvulkan.so " >/dev/null
}

install_pkg() {
    # install_pkg <pkg-manager> <pkg-name...>
    local mgr="$1"; shift
    case "$mgr" in
        rpm-ostree)
            echo "Layering via rpm-ostree (requires a reboot to activate): $*"
            sudo rpm-ostree install --idempotent "$@"
            RPM_OSTREE_REBOOT_NEEDED=1
            ;;
        dnf)
            sudo dnf install -y "$@"
            ;;
        apt)
            sudo apt-get install -y "$@"
            ;;
        pacman)
            sudo pacman -S --noconfirm "$@"
            ;;
        *)
            echo "ERROR: unknown package manager, install manually: $*" >&2
            return 1
            ;;
    esac
}
