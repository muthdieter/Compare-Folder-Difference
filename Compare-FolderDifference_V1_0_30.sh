#!/bin/bash

SCRIPT_NAME="Compare_Folders_Difference"
SCRIPT_VERSION="V_1_0_30
SCRIPT_DATE="7.2025"
SCRIPT_GITHUB="https://github.com/muthdieter"

SRC_MOUNT="/mnt/source"
TGT_MOUNT="/mnt/target"
LOG_FILE="./compare_folders_$(date +%Y-%m-%d_%H%M%S).log"

log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

clear
log ""
log "             ____  __  __"
log "            |  _ \\|  \\/  |"
log "            | | | | |\\/| |"
log "            | |_| | |  | |"
log "            |____/|_|  |_|"
log ""
log "  $SCRIPT_GITHUB"
log "  $SCRIPT_NAME"
log "  $SCRIPT_VERSION"
log "  $SCRIPT_DATE"
log ""

read -p "Press Enter to continue..."

# === Check and unmount if already mounted ===
if mountpoint -q "$SRC_MOUNT" || mountpoint -q "$TGT_MOUNT"; then
    log "\nOne or both mount points are already mounted. Unmounting first..."
    sudo umount "$SRC_MOUNT" 2>/dev/null
    sudo umount "$TGT_MOUNT" 2>/dev/null
    log "Unmounted $SRC_MOUNT and $TGT_MOUNT if they were mounted."
    echo ""
    read -p "Press Enter to continue..."
fi

# === Detect package manager ===
detect_pkg_mgr() {
    if command -v apt >/dev/null 2>&1; then echo "apt"
    elif command -v dnf >/dev/null 2>&1; then echo "dnf"
    elif command -v yum >/dev/null 2>&1; then echo "yum"
    else echo ""; fi
}

PKG_MGR=$(detect_pkg_mgr)

# === Check/install tool ===
check_or_ask_install() {
    local pkg="$1"
    if ! command -v "$pkg" >/dev/null 2>&1 && ! dpkg -s "$pkg" >/dev/null 2>&1 && ! rpm -q "$pkg" >/dev/null 2>&1; then
        log "\nMissing prerequisite: $pkg"
        read -p "Install $pkg? (y=yes / n=abort): " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            log "Installing $pkg..."
            case "$PKG_MGR" in
                apt) sudo apt update && sudo apt install -y "$pkg" | tee -a "$LOG_FILE" ;;
                dnf|yum) sudo $PKG_MGR install -y "$pkg" | tee -a "$LOG_FILE" ;;
            esac
        else
            log "Aborting script. Unmounting any mounted folders if necessary."
            sudo umount "$SRC_MOUNT" 2>/dev/null
            sudo umount "$TGT_MOUNT" 2>/dev/null
            exit 1
        fi
    else
        log "Found prerequisite: $pkg"
        echo ""
        read -p "Press Enter to continue..."
    fi
}

# === Prerequisite tools ===
for tool in cifs-utils nfs-common coreutils util-linux; do check_or_ask_install "$tool"; done

# === Mount source ===
log "\nMounting source to $SRC_MOUNT"
echo ""
sudo mkdir -p "$SRC_MOUNT"
read -p "Enter SMB source share (e.g. //host/share): " SRC_REMOTE
echo ""
read -p "Enter username: " SRC_USER
read -s -p "Enter password: " SRC_PASS; echo

# Check if reachable
if ! ping -c 1 "$(echo "$SRC_REMOTE" | cut -d/ -f3)" >/dev/null 2>&1; then
    log "\nCannot reach source host. Exiting."
    exit 1
fi

log "Mounting source share..."
sudo mount -t cifs "$SRC_REMOTE" "$SRC_MOUNT" -o username="$SRC_USER",password="$SRC_PASS",vers=3.0 | tee -a "$LOG_FILE" || {
    log "\nFailed to mount source. Exiting."
    exit 1
}

# === Mount target ===
log "\nMounting target to $TGT_MOUNT"
echo ""
sudo mkdir -p "$TGT_MOUNT"
read -p "Enter SMB target share (e.g. //host/share): " TGT_REMOTE
echo ""
read -p "Enter username: " TGT_USER
read -s -p "Enter password: " TGT_PASS; echo

if ! ping -c 1 "$(echo "$TGT_REMOTE" | cut -d/ -f3)" >/dev/null 2>&1; then
    log "\nCannot reach target host. Exiting."
    sudo umount "$SRC_MOUNT"
    exit 1
fi

log "Mounting target share..."
sudo mount -t cifs "$TGT_REMOTE" "$TGT_MOUNT" -o username="$TGT_USER",password="$TGT_PASS",vers=3.0 | tee -a "$LOG_FILE" || {
    log "\nFailed to mount target. Exiting."
    sudo umount "$SRC_MOUNT"
    exit 1
}

# === Scan folders ===
log "\nScanning folders..."
SRC_LIST=$(mktemp)
TGT_LIST=$(mktemp)
find "$SRC_MOUNT" -type f | sed "s|^$SRC_MOUNT/||" | sort > "$SRC_LIST"
find "$TGT_MOUNT" -type f | sed "s|^$TGT_MOUNT/||" | sort > "$TGT_LIST"

RESULTS=$(mktemp)
echo "Location;RelativePath;Name;Size" > "$RESULTS"

comm -23 "$SRC_LIST" "$TGT_LIST" | while read -r path; do
    SIZE=$(stat -c %s "$SRC_MOUNT/$path")
    echo "Source;$path;$(basename "$path");$SIZE" >> "$RESULTS"
done

comm -12 "$SRC_LIST" "$TGT_LIST" | while read -r path; do
    SIZE=$(stat -c %s "$SRC_MOUNT/$path")
    echo "Both;$path;$(basename "$path");$SIZE" >> "$RESULTS"
done

comm -13 "$SRC_LIST" "$TGT_LIST" | while read -r path; do
    SIZE=$(stat -c %s "$TGT_MOUNT/$path")
    echo "Target;$path;$(basename "$path");$SIZE" >> "$RESULTS"
done

# === Output ===
log "\nChoose output format:"
echo "1. CSV"
echo "2. TXT"
echo "3. HTML"
echo ""
read -p "Enter your choice [1-3]: " FORMAT

SRC_LABEL=$(basename "$SRC_REMOTE" | tr -c '[:alnum:]' '_')
TGT_LABEL=$(basename "$TGT_REMOTE" | tr -c '[:alnum:]' '_')
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)

case "$FORMAT" in
  2)
    OUT_FILE="./${SRC_LABEL}_VS_${TGT_LABEL}_$TIMESTAMP.txt"
    column -t -s ';' "$RESULTS" > "$OUT_FILE"
    ;;
  3)
    OUT_FILE="./${SRC_LABEL}_VS_${TGT_LABEL}_$TIMESTAMP.html"
    {
        echo "<html><body><table border='1'>"
        echo "<tr><th>Location</th><th>RelativePath</th><th>Name</th><th>Size</th></tr>"
        tail -n +2 "$RESULTS" | while IFS=";" read -r a b c d; do
            echo "<tr><td>$a</td><td>$b</td><td>$c</td><td>$d</td></tr>"
        done
        echo "</table></body></html>"
    } > "$OUT_FILE"
    ;;
  *)
    OUT_FILE="./${SRC_LABEL}_VS_${TGT_LABEL}_$TIMESTAMP.csv"
    cp "$RESULTS" "$OUT_FILE"
    ;;
esac

log "\n✅ Output saved to: $OUT_FILE"

# === Open in default application ===
if command -v xdg-open >/dev/null 2>&1; then
    log "Opening output file with default application..."
    xdg-open "$OUT_FILE" >/dev/null 2>&1 &
elif command -v open >/dev/null 2>&1; then  # macOS support
    open "$OUT_FILE"
fi

# === Cleanup ===
rm -f "$SRC_LIST" "$TGT_LIST" "$RESULTS"
sudo umount "$SRC_MOUNT"
sudo umount "$TGT_MOUNT"
log "\n✅ Unmounted source and target. Log saved to: $LOG_FILE"
