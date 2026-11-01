#!/bin/sh
# Re-enable GPU acceleration in the GLKVM macOS desktop app (Electron).
#
# The app's main process calls app.disableHardwareAcceleration() and appends
# --disable-gpu / --disable-gpu-compositing, so H.264 video is decoded and
# composited in software (~1 CPU core at 2560x1440). This script neutralises
# those three statements inside app.asar with same-length comments, refreshes
# the asar integrity hashes, re-signs the bundle ad hoc (entitlements kept)
# and removes the quarantine attribute.
#
# Usage: patch_glkvm_app_gpu.sh apply|revert|status
# Env:   GLKVM_APP         (default /Applications/GLKVM.app)
#        GLKVM_APP_BACKUP  (default ~/Library/Application Support/gl-kvm/gpu-patch-backup)
#
# Safe to re-run; run it again after every app auto-update.

set -eu

APP=${GLKVM_APP:-/Applications/GLKVM.app}
BACKUP=${GLKVM_APP_BACKUP:-"$HOME/Library/Application Support/gl-kvm/gpu-patch-backup"}
ASAR="$APP/Contents/Resources/app.asar"
PLIST="$APP/Contents/Info.plist"
TMPDIR_PATCH=""

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

cleanup() { [ -n "$TMPDIR_PATCH" ] && rm -rf "$TMPDIR_PATCH"; return 0; }
trap cleanup EXIT

check_tools() {
	for t in codesign plutil xattr python3 pgrep; do
		command -v "$t" >/dev/null 2>&1 || die "required tool '$t' not found"
	done
}

check_app() {
	[ -d "$APP" ] || die "app not found: $APP"
	[ -f "$ASAR" ] || die "app.asar not found: $ASAR"
	[ -f "$PLIST" ] || die "Info.plist not found: $PLIST"
}

check_not_running() {
	if pgrep -x GLKVM >/dev/null 2>&1; then
		die "GLKVM is running; quit it first"
	fi
}

app_version() {
	plutil -extract CFBundleShortVersionString raw -o - "$PLIST" 2>/dev/null || echo unknown
}

# Prints: patched | original | unknown
asar_state() {
	python3 - "$ASAR" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
stmts = [b'require$$0$2.app.disableHardwareAcceleration();',
         b'require$$0$2.app.commandLine.appendSwitch("disable-gpu");',
         b'require$$0$2.app.commandLine.appendSwitch("disable-gpu-compositing");']
if b"/* gpu-patch" in data:
    print("patched")
elif any(s in data for s in stmts):
    print("original")
else:
    print("unknown")
PY
}

resign() {
	ent="$1"
	info "Re-signing ad hoc (entitlements preserved)"
	codesign --force --deep --sign - --options runtime --entitlements "$ent" "$APP"
	codesign --verify --deep --strict "$APP" || die "codesign verification failed"
	info "Removing quarantine attribute"
	xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
}

dump_entitlements() {
	out="$1"
	codesign -d --entitlements - --xml "$APP" >"$out" 2>/dev/null ||
		codesign -d --entitlements :- "$APP" >"$out" 2>/dev/null || true
	plutil -lint "$out" >/dev/null 2>&1 || die "could not extract entitlements from $APP"
}

do_backup() {
	mkdir -p "$BACKUP"
	if [ -f "$BACKUP/app.asar" ] && [ -f "$BACKUP/Info.plist" ]; then
		bver=$(sed -n 's/^version: //p' "$BACKUP/backup-info.txt" 2>/dev/null || true)
		if [ "$bver" = "$(app_version)" ]; then
			info "Backup already present in $BACKUP (keeping first pristine copy)"
			return 0
		fi
		# Only reached for an unpatched app, so the current files are pristine.
		info "Backup is for version ${bver:-unknown}; replacing it with the current $(app_version) files"
	fi
	info "Backing up app.asar and Info.plist to $BACKUP"
	cp -p "$ASAR" "$BACKUP/app.asar"
	cp -p "$PLIST" "$BACKUP/Info.plist"
	if [ -f "$APP/Contents/_CodeSignature/CodeResources" ]; then
		cp -p "$APP/Contents/_CodeSignature/CodeResources" "$BACKUP/CodeResources"
	fi
	dump_entitlements "$BACKUP/entitlements.plist"
	{
		echo "app: $APP"
		echo "version: $(app_version)"
		echo "date: $(date)"
	} >"$BACKUP/backup-info.txt"
}

# Patches the asar in place; prints the new header JSON sha256 on stdout.
patch_asar() {
	python3 - "$ASAR" <<'PY'
import hashlib, json, struct, sys

path = sys.argv[1]
with open(path, "rb") as f:
    data = bytearray(f.read())

def u32(off):
    return struct.unpack_from("<I", data, off)[0]

if u32(0) != 4:
    sys.exit("unexpected asar format")
header_size = u32(4)          # size of the header pickle
json_len = u32(12)            # length of the header JSON string
base = 8 + header_size        # start of the file data area
header = bytes(data[16:16 + json_len])
tree = json.loads(header)

node = tree
for part in ("out", "main", "index.js"):
    node = node["files"][part]
off, size = int(node["offset"]), int(node["size"])
integ = node["integrity"]
old_hash = integ["hash"]
start, end = base + off, base + off + size
content = bytes(data[start:end])
if hashlib.sha256(content).hexdigest() != old_hash:
    sys.exit("out/main/index.js hash mismatch before patching (layout not understood)")
if len(integ.get("blocks", [])) != 1 or size > int(integ["blockSize"]):
    sys.exit("unexpected integrity block layout")

stmts = [b'require$$0$2.app.disableHardwareAcceleration();',
         b'require$$0$2.app.commandLine.appendSwitch("disable-gpu");',
         b'require$$0$2.app.commandLine.appendSwitch("disable-gpu-compositing");']
names = [b"disableHardwareAcceleration", b"disable-gpu", b"disable-gpu-compositing"]
new = content
for s, n in zip(stmts, names):
    if data.count(s) != 1 or new.count(s) != 1:
        sys.exit("statement not found exactly once: %s" % s.decode())
    body = b"/* gpu-patch: removed " + n
    pad = len(s) - len(body) - 3
    if pad < 1:
        body = b"/* gpu-patch"
        pad = len(s) - len(body) - 3
    if pad < 1:
        sys.exit("statement too short to replace")
    rep = body + b" " * pad + b" */"
    assert len(rep) == len(s) and rep.count(b"*/") == 1
    new = new.replace(s, rep)
if len(new) != len(content):
    sys.exit("length changed while patching")
data[start:end] = new

new_hash = hashlib.sha256(new).hexdigest()
htext = header.decode("utf-8")
if htext.count(old_hash) != 2:
    sys.exit("old hash does not occur exactly twice in header")
new_header = htext.replace(old_hash, new_hash).encode("utf-8")
if len(new_header) != len(header):
    sys.exit("header length changed")
json.loads(new_header)
data[16:16 + json_len] = new_header

# write only the two changed regions, in place (keeps owner/mode)
with open(path, "r+b") as f:
    f.seek(start)
    f.write(new)
    f.seek(16)
    f.write(new_header)
print(hashlib.sha256(new_header).hexdigest())
PY
}

cmd_apply() {
	check_not_running
	state=$(asar_state)
	case "$state" in
	patched)
		info "already patched ($APP, version $(app_version))"
		exit 0
		;;
	unknown)
		die "none of the expected statements found: unknown app version, not patching"
		;;
	esac

	do_backup

	TMPDIR_PATCH=$(mktemp -d)
	ent="$TMPDIR_PATCH/entitlements.plist"
	dump_entitlements "$ent"

	info "Patching app.asar"
	hhash=$(patch_asar)
	[ ${#hhash} -eq 64 ] || die "patching failed"

	info "Updating ElectronAsarIntegrity in Info.plist"
	plutil -replace 'ElectronAsarIntegrity.Resources/app\.asar.hash' -string "$hhash" "$PLIST"

	resign "$ent"

	echo
	info "Done: GPU acceleration re-enabled in $APP (version $(app_version))."
	echo "    Backup: $BACKUP"
	echo "    The app is now ad-hoc signed. Launch GLKVM normally."
	echo "    Re-run this script after each app update."
}

cmd_revert() {
	check_not_running
	[ -f "$BACKUP/app.asar" ] && [ -f "$BACKUP/Info.plist" ] ||
		die "no backup found in $BACKUP"
	TMPDIR_PATCH=$(mktemp -d)
	ent="$TMPDIR_PATCH/entitlements.plist"
	if [ -f "$BACKUP/entitlements.plist" ]; then
		cp "$BACKUP/entitlements.plist" "$ent"
	else
		dump_entitlements "$ent"
	fi
	info "Restoring app.asar and Info.plist from $BACKUP"
	cp "$BACKUP/app.asar" "$ASAR"
	cp "$BACKUP/Info.plist" "$PLIST"
	resign "$ent"
	echo
	info "Reverted $APP to the original app.asar (version $(app_version))."
	echo "    Note: the original Developer ID signature cannot be restored; the app"
	echo "    stays ad-hoc signed. Reinstall GLKVM from GL.iNet to restore it fully."
}

cmd_status() {
	echo "App:        $APP"
	echo "Version:    $(app_version)"
	case "$(asar_state)" in
	patched) echo "GPU patch:  applied" ;;
	original) echo "GPU patch:  not applied" ;;
	*) echo "GPU patch:  unknown app version (statements not found)" ;;
	esac
	sig=$(codesign -dvv "$APP" 2>&1 | grep -E '^Authority=|Signature=adhoc' | head -n 1 || true)
	echo "Signature:  ${sig:-unsigned or invalid}"
	if xattr -r "$APP" 2>/dev/null | grep -q com.apple.quarantine; then
		echo "Quarantine: present"
	else
		echo "Quarantine: none"
	fi
	if [ -f "$BACKUP/app.asar" ]; then
		echo "Backup:     $BACKUP ($(sed -n 's/^version: //p' "$BACKUP/backup-info.txt" 2>/dev/null))"
	else
		echo "Backup:     none"
	fi
}

usage() {
	echo "usage: $0 apply|revert|status" >&2
	exit 2
}

[ $# -eq 1 ] || usage
check_tools
check_app
case "$1" in
apply) cmd_apply ;;
revert) cmd_revert ;;
status) cmd_status ;;
*) usage ;;
esac
