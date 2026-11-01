#!/usr/bin/env bash
# Build Quake for the GitHub Universe 2026 badge, back up the badge and flash it.
#
# Steps:
#   1. Install the build tools (asks first).
#   2. Clone zenodante/RP2350-Quake at a known commit and apply the badge patches.
#   3. Ask where your Quake game files are (pak0.pak).
#   4. Build the game program and the game data.
#   5. Back up the whole badge flash to a .bin file.
#   6. Flash Quake to the badge.
#
# Run with --help for options.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="$SCRIPT_DIR/patches"

QUAKE_REPO="https://github.com/zenodante/RP2350-Quake.git"
QUAKE_COMMIT="f054697bebec1c4a886f34e4a48e344111d32ee8"
PICO_SDK_REPO="https://github.com/raspberrypi/pico-sdk.git"
PICO_SDK_TAG="2.3.1"
PICOTOOL_REPO="https://github.com/raspberrypi/picotool.git"
PICOTOOL_TAG="2.3.1"

# MD5 of the shareware v1.06 pak0.pak. The registered v1.06 id1/pak0.pak is the same file.
SHAREWARE_PAK_MD5="5906e5998fc3d896ddaf5e6a62e03abb"

WORKDIR="${HOME}/quake-badge"
PAK=""
BACKUP_DIR=""
INSTALL=1
DO_BACKUP=1
DO_DEPLOY=1
FIRMWARE_ONLY=0
RESTORE=""
BACKUP_ONLY=0
ASSUME_YES=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

  --pak PATH         pak0.pak, or a Quake folder that contains id1/pak0.pak.
                     Without this, the script asks.
  --workdir DIR      Where tools, sources and builds go (default: $WORKDIR).
  --backup-dir DIR   Where badge backups go (default: WORKDIR/backups).
  --no-install       Do not install packages; use the tools already on this computer.
  --skip-backup      Do not back up the badge before flashing.
  --build-only       Build, but do not back up or flash the badge.
  --backup-only      Only back up the badge (no build, no flashing).
  --firmware-only    Flash only the game program. Use this when the game data
                     on the badge has not changed.
  --restore FILE     Flash a backup (.bin or .uf2) back to the badge, then stop.
  -y, --yes          Do not ask for confirmation.
  -h, --help         Show this help.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --pak) PAK="$2"; shift 2 ;;
        --workdir) WORKDIR="$2"; shift 2 ;;
        --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
        --no-install) INSTALL=0; shift ;;
        --skip-backup) DO_BACKUP=0; shift ;;
        --build-only) DO_BACKUP=0; DO_DEPLOY=0; shift ;;
        --firmware-only) FIRMWARE_ONLY=1; shift ;;
        --backup-only) BACKUP_ONLY=1; shift ;;
        --restore) RESTORE="$2"; shift 2 ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

WORKDIR="$(mkdir -p "$WORKDIR" && cd "$WORKDIR" && pwd)"
BACKUP_DIR="${BACKUP_DIR:-$WORKDIR/backups}"
TOOLS_DIR="$WORKDIR/tools"
SRC_DIR="$WORKDIR/RP2350-Quake"
OUT_DIR="$SRC_DIR/build-host/badge"

# ---------------------------------------------------------------- helpers

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { echo; bold "==> $*"; }
info() { echo "    $*"; }
warn() { printf '\033[33mWarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy] ]]
}

have() { command -v "$1" >/dev/null 2>&1; }

md5_of() {
    if have md5sum; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1"; fi
}

sha256_of() {
    if have sha256sum; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# version_ge 2.3.1 2.1 -> true
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

OS="$(uname -s)"
DISTRO=""
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    DISTRO="$(. /etc/os-release; echo "${ID:-} ${ID_LIKE:-}")"
fi

# ---------------------------------------------------------------- 1. tools

install_packages() {
    step "Installing build tools"
    local cmd=()
    case "$OS $DISTRO" in
        Darwin*)
            have brew || die "Install Homebrew first: https://brew.sh"
            info "brew install cmake ninja python git libusb pkg-config, plus the Arm toolchain"
            confirm "Install these with Homebrew?" || die "Cancelled."
            brew install cmake ninja python git libusb pkg-config
            brew install --cask gcc-arm-embedded
            return ;;
        *arch*)
            cmd=(sudo pacman -S --needed git cmake ninja python arm-none-eabi-gcc
                 arm-none-eabi-newlib libusb pkgconf base-devel) ;;
        *debian*|*ubuntu*)
            cmd=(sudo apt-get install -y git cmake ninja-build python3 gcc-arm-none-eabi
                 libnewlib-arm-none-eabi libstdc++-arm-none-eabi-newlib build-essential
                 pkg-config libusb-1.0-0-dev) ;;
        *fedora*|*rhel*)
            cmd=(sudo dnf install -y git cmake ninja-build python3 arm-none-eabi-gcc-cs
                 arm-none-eabi-gcc-cs-c++ arm-none-eabi-newlib gcc-c++ libusb1-devel pkgconf) ;;
        *)
            warn "Unknown system ($OS $DISTRO). Install these yourself: git, cmake, ninja,"
            warn "python3, the arm-none-eabi GCC toolchain with newlib, a C++ compiler and libusb."
            return ;;
    esac
    info "${cmd[*]}"
    confirm "Run this command?" || die "Cancelled."
    if [[ "$DISTRO" == *debian* || "$DISTRO" == *ubuntu* ]]; then sudo apt-get update; fi
    "${cmd[@]}"
}

check_basic_tools() {
    local missing=()
    for t in git cmake ninja python3 arm-none-eabi-gcc; do have "$t" || missing+=("$t"); done
    [ ${#missing[@]} -eq 0 ] || die "Missing tools: ${missing[*]}. Run without --no-install, or install them."
}

sdk_version() {
    local f="$1/pico_sdk_version.cmake"
    [ -r "$f" ] || return 1
    local major minor rev
    major=$(sed -n 's/.*PICO_SDK_VERSION_MAJOR \([0-9]*\).*/\1/p' "$f")
    minor=$(sed -n 's/.*PICO_SDK_VERSION_MINOR \([0-9]*\).*/\1/p' "$f")
    rev=$(sed -n 's/.*PICO_SDK_VERSION_REVISION \([0-9]*\).*/\1/p' "$f")
    echo "$major.$minor.$rev"
}

find_pico_sdk() {
    local d v
    for d in "${PICO_SDK_PATH:-}" /usr/share/pico-sdk /opt/pico-sdk "$TOOLS_DIR/pico-sdk"; do
        [ -n "$d" ] || continue
        v=$(sdk_version "$d") || continue
        if version_ge "$v" 2.1.0 && [ -e "$d/lib/tinyusb/src/tusb.h" ]; then
            PICO_SDK="$d"; info "Pico SDK $v: $d"; return 0
        fi
    done
    return 1
}

setup_pico_sdk() {
    step "Pico SDK"
    find_pico_sdk && return
    info "Downloading Pico SDK $PICO_SDK_TAG to $TOOLS_DIR/pico-sdk"
    mkdir -p "$TOOLS_DIR"
    rm -rf "$TOOLS_DIR/pico-sdk"
    git clone --depth 1 --branch "$PICO_SDK_TAG" "$PICO_SDK_REPO" "$TOOLS_DIR/pico-sdk"
    git -C "$TOOLS_DIR/pico-sdk" submodule update --init --depth 1 lib/tinyusb
    find_pico_sdk || die "Pico SDK set-up failed."
}

find_picotool() {
    local bin dir v
    for bin in "$TOOLS_DIR/picotool-install/bin/picotool" "$(command -v picotool || true)"; do
        [ -n "$bin" ] && [ -x "$bin" ] || continue
        v=$("$bin" version 2>/dev/null | sed -n 's/^picotool v\([0-9.]*\).*/\1/p')
        [ -n "$v" ] && version_ge "$v" 2.0.0 || continue
        for dir in "$(dirname "$(dirname "$bin")")/lib/cmake/picotool" /usr/lib/cmake/picotool \
                   /usr/local/lib/cmake/picotool /opt/homebrew/lib/cmake/picotool; do
            if [ -r "$dir/picotoolConfig.cmake" ]; then
                PICOTOOL="$bin"; PICOTOOL_CMAKE="$dir"
                info "picotool $v: $bin"
                return 0
            fi
        done
    done
    return 1
}

setup_picotool() {
    step "picotool"
    find_picotool && return
    info "Building picotool $PICOTOOL_TAG in $TOOLS_DIR"
    mkdir -p "$TOOLS_DIR"
    rm -rf "$TOOLS_DIR/picotool" "$TOOLS_DIR/picotool-build"
    git clone --depth 1 --branch "$PICOTOOL_TAG" "$PICOTOOL_REPO" "$TOOLS_DIR/picotool" ||
        git clone --depth 1 "$PICOTOOL_REPO" "$TOOLS_DIR/picotool"
    cmake -S "$TOOLS_DIR/picotool" -B "$TOOLS_DIR/picotool-build" -G Ninja \
        -DPICO_SDK_PATH="$PICO_SDK" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$TOOLS_DIR/picotool-install"
    cmake --build "$TOOLS_DIR/picotool-build"
    cmake --install "$TOOLS_DIR/picotool-build"
    find_picotool || die "picotool build failed."

    # On Linux, picotool needs a udev rule to reach the badge without root.
    if [ "$OS" = Linux ] && ! grep -qs 2e8a /etc/udev/rules.d/*.rules /usr/lib/udev/rules.d/*.rules; then
        local rule
        rule=$(ls "$TOOLS_DIR"/picotool/udev/*.rules 2>/dev/null | head -1)
        if [ -n "$rule" ] && confirm "Install the picotool udev rule (needs sudo) so it can reach the badge?"; then
            sudo install -m 644 "$rule" /etc/udev/rules.d/
            sudo udevadm control --reload-rules && sudo udevadm trigger
        fi
    fi
}

# ---------------------------------------------------------------- picotool / badge helpers

bootsel_present() { "$PICOTOOL" info >/dev/null 2>&1; }

wait_bootsel() {
    local i
    for i in $(seq 1 "${1:-10}"); do bootsel_present && return 0; sleep 1; done
    return 1
}

# Puts the badge in bootloader (BOOTSEL) mode.
enter_bootsel() {
    bootsel_present && return 0
    info "Switching the badge to bootloader mode..."
    # Works while Quake (or any Pico SDK program with USB serial) is running.
    "$PICOTOOL" reboot -f -u >/dev/null 2>&1 || true
    wait_bootsel 5 && return 0

    # The badge's normal MicroPython software: ask it over USB serial.
    local tty
    for tty in /dev/ttyACM* /dev/cu.usbmodem*; do
        [ -w "$tty" ] || continue
        if [ "$OS" = Darwin ]; then stty -f "$tty" 115200 raw -echo 2>/dev/null || continue
        else stty -F "$tty" 115200 raw -echo 2>/dev/null || continue; fi
        printf '\x03\x03' >"$tty"; sleep 1
        printf 'import machine\r\nmachine.bootloader()\r\n' >"$tty"
        wait_bootsel 5 && return 0
    done

    echo
    bold "Put the badge in bootloader mode: hold BOOT, press and release RESET, then release BOOT."
    info "Waiting for the badge (up to 60 s)..."
    wait_bootsel 60 || die "The badge did not appear in bootloader mode."
}

badge_field() { "$PICOTOOL" info -a 2>/dev/null | sed -n "s/^ *$1: *//p" | head -1; }

backup_badge() {
    step "Backing up the badge"
    enter_bootsel
    mkdir -p "$BACKUP_DIR"
    local chip name stamp file
    chip=$(badge_field chipid); chip=${chip:-unknown}
    name=$(badge_field name); name=${name:-unknown}
    stamp=$(date +%Y%m%d-%H%M%S)
    file="$BACKUP_DIR/badge-${chip}-${stamp}-${name// /_}.bin"
    if [ "$name" = quake_rp2350 ]; then
        warn "The badge is already running Quake, so this backup holds Quake, not the original software."
        warn "Earlier backups in $BACKUP_DIR are kept."
    fi
    info "Reading 16 MB of flash to $file"
    "$PICOTOOL" save -a "$file"
    info "Checking the backup against the badge"
    "$PICOTOOL" verify "$file" -o 0x10000000 >/dev/null || die "The backup does not match the badge. Try again."
    "$PICOTOOL" info -a >"${file%.bin}.info.txt" 2>&1 || true
    sha256_of "$file" >"$file.sha256"
    info "Backup saved and checked: $file"
    LAST_BACKUP="$file"
}

restore_badge() {
    local file="$1"
    [ -r "$file" ] || die "Backup not found: $file"
    step "Restoring $file"
    confirm "This replaces everything on the badge with the backup. Continue?" || die "Cancelled."
    enter_bootsel
    case "$file" in
        *.uf2) "$PICOTOOL" load -v "$file" ;;
        *)     "$PICOTOOL" load -v "$file" -o 0x10000000 ;;
    esac
    "$PICOTOOL" reboot >/dev/null
    info "Restored. The badge is restarting."
}

# ---------------------------------------------------------------- 2. source

setup_source() {
    step "Quake source"
    if [ ! -d "$SRC_DIR/.git" ]; then
        git clone "$QUAKE_REPO" "$SRC_DIR"
    fi
    if git -C "$SRC_DIR" log --format=%s | grep -q "^Add GitHub Universe badge board"; then
        info "Badge patches already applied in $SRC_DIR"
        return
    fi
    [ -z "$(git -C "$SRC_DIR" status --porcelain --untracked-files=no)" ] ||
        die "$SRC_DIR has local changes. Move it away or commit them, then run again."
    git -C "$SRC_DIR" fetch -q origin "$QUAKE_COMMIT" 2>/dev/null || true
    git -C "$SRC_DIR" checkout -q -B universe-badge "$QUAKE_COMMIT"
    info "Applying $(ls "$PATCH_DIR"/*.patch | wc -l | tr -d ' ') badge patches"
    GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-setup-quake}" \
    GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-setup-quake@localhost}" \
        git -C "$SRC_DIR" am -q "$PATCH_DIR"/*.patch || {
            git -C "$SRC_DIR" am --abort || true
            die "The badge patches did not apply."
        }
}

# ---------------------------------------------------------------- 3. game files

# Finds id1/pak0.pak in a folder, case-insensitively, skipping the 2021 re-release.
pak_in_dir() {
    find "$1" -maxdepth 3 -ipath '*id1/pak0.pak' -not -ipath '*rerelease*' 2>/dev/null | head -1
}

choose_pak() {
    step "Quake game files"
    local guess="" d
    if [ -z "$PAK" ]; then
        for d in "$HOME/.local/share/Steam/steamapps/common/Quake" \
                 "$HOME/.steam/steam/steamapps/common/Quake" \
                 "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common/Quake" \
                 "$HOME/Library/Application Support/Steam/steamapps/common/Quake"; do
            [ -d "$d" ] && guess=$(pak_in_dir "$d") && [ -n "$guess" ] && break
        done
        info "The game needs pak0.pak from Quake (shareware or the original id1 folder)."
        info "You can give the file itself or a Quake folder."
        if [ -n "$guess" ]; then info "Found: $guess"; fi
        if [ "$ASSUME_YES" = 1 ] && [ -n "$guess" ]; then
            PAK="$guess"
        else
            read -r -e -p "    Path to pak0.pak or Quake folder [${guess}]: " PAK
            PAK="${PAK:-$guess}"
        fi
    fi
    PAK="${PAK/#\~/$HOME}"
    [ -d "$PAK" ] && PAK=$(pak_in_dir "$PAK")
    [ -n "$PAK" ] && [ -r "$PAK" ] || die "pak0.pak not found."

    local sum
    sum=$(md5_of "$PAK")
    if [ "$sum" = "$SHAREWARE_PAK_MD5" ]; then
        info "Using $PAK (Quake v1.06 pak0.pak, checksum matches)"
    else
        warn "$PAK is not the v1.06 pak0.pak (MD5 $sum)."
        warn "The 2021 re-release pak0.pak does not work. Use the original id1 or shareware file."
        confirm "Use it anyway?" || die "Cancelled."
    fi
    mkdir -p "$SRC_DIR/build"
    cp "$PAK" "$SRC_DIR/build/pak0.pak"
    PAK_MD5="$sum"
}

# ---------------------------------------------------------------- 4. build

build_quake() {
    step "Building Quake for the badge"
    # The build script expects a "pico8c" folder holding the SDK and the Arm toolchain.
    local pico8c="$WORKDIR/pico8c" gcc_prefix
    gcc_prefix=$(dirname "$(dirname "$(command -v arm-none-eabi-gcc)")")
    mkdir -p "$pico8c/third_party/toolchains"
    ln -sfn "$PICO_SDK" "$pico8c/third_party/pico-sdk"
    ln -sfn "$gcc_prefix" "$pico8c/third_party/toolchains/arm-gnu-toolchain-system"

    local reuse=()
    if [ -r "$OUT_DIR/resources/quake-resources.uf2" ] && [ "$(cat "$OUT_DIR/.pak.md5" 2>/dev/null)" = "$PAK_MD5" ]; then
        info "Game data is up to date; rebuilding the program only."
        reuse=(--reuse-resources)
    else
        info "Converting the game data takes a few minutes."
    fi
    local log="$SRC_DIR/build/badge-build.log"
    (cd "$SRC_DIR" && python3 Tools/RP2350Pack/build_game_firmware.py build/pak0.pak -o "$OUT_DIR" \
        --pico8c-root "$pico8c" --picotool-dir "$PICOTOOL_CMAKE" "${reuse[@]}") >"$log" 2>&1 || {
        tail -30 "$log" >&2
        die "Build failed. Full log: $log"
    }
    echo "$PAK_MD5" >"$OUT_DIR/.pak.md5"
    FIRMWARE_UF2="$OUT_DIR/firmware/game/quake_rp2350.uf2"
    RESOURCES_UF2="$OUT_DIR/resources/quake-resources.uf2"
    [ -r "$FIRMWARE_UF2" ] && [ -r "$RESOURCES_UF2" ] || die "Build finished but the UF2 files are missing. Log: $log"
    info "Program: $FIRMWARE_UF2"
    info "Data:    $RESOURCES_UF2"
}

# ---------------------------------------------------------------- 6. deploy

deploy_quake() {
    step "Flashing Quake to the badge"
    if [ "$FIRMWARE_ONLY" = 1 ]; then
        info "Flashing the game program only."
    else
        info "This replaces the badge's software. Writing the game data takes about 2 minutes."
    fi
    confirm "Flash Quake to the badge now?" || { info "Skipped flashing."; return; }
    enter_bootsel
    "$PICOTOOL" load -v "$FIRMWARE_UF2"
    [ "$FIRMWARE_ONLY" = 1 ] || "$PICOTOOL" load -v "$RESOURCES_UF2"
    "$PICOTOOL" reboot >/dev/null
    info "Done. The badge is restarting into Quake."
}

# ---------------------------------------------------------------- main

LAST_BACKUP=""
PICO_SDK=""
PICOTOOL=""
PICOTOOL_CMAKE=""

if [ -n "$RESTORE" ]; then
    find_picotool || die "picotool 2.x is needed to restore. Run the full set-up once, or install picotool."
    restore_badge "$RESTORE"
    exit 0
fi

if [ "$BACKUP_ONLY" = 1 ]; then
    find_picotool || die "picotool 2.x is needed. Run the full set-up once, or install picotool."
    backup_badge
    "$PICOTOOL" reboot >/dev/null 2>&1 || true
    exit 0
fi

bold "Quake for the GitHub Universe 2026 badge"
info "Work folder: $WORKDIR"

if [ "$INSTALL" = 1 ]; then
    install_packages
    # On Arch, prefer the AUR packages for the SDK and picotool when an AUR helper is present.
    if [[ "$DISTRO" == *arch* ]]; then
        aur=""; have paru && aur=paru; have yay && aur=yay
        if [ -n "$aur" ] && { ! have picotool || [ ! -d /usr/share/pico-sdk ]; }; then
            confirm "Install pico-sdk and picotool from the AUR with $aur?" && "$aur" -S --needed pico-sdk picotool
        fi
    fi
fi
check_basic_tools
setup_pico_sdk
setup_picotool
setup_source
choose_pak
build_quake

if [ "$DO_DEPLOY" = 1 ]; then
    if [ "$DO_BACKUP" = 1 ]; then backup_badge; else warn "Skipping the backup."; fi
    deploy_quake
fi

echo
bold "All done."
[ -n "$LAST_BACKUP" ] && info "Backup: $LAST_BACKUP"
info "To put the badge back to its earlier software:"
info "  $0 --restore ${LAST_BACKUP:-<backup.bin>}"
