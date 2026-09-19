#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

need_command scp
need_command sshpass
need_command dpkg-deb
ensure_ipad_usb

if [[ -n "${VZ_IPAD_DEB:-}" ]]; then
    DEB="$VZ_IPAD_DEB"
else
    DEB="$(find "$VZ_BUILD_ROOT/release" -maxdepth 1 -type f \
        -name 'VirtualMac_*.deb' \
        -print0 | xargs -0 ls -1t 2>/dev/null | head -1)"
fi
[[ -n "$DEB" && -f "$DEB" ]] ||
    die "standalone package not found; run scripts/build-ipad-deb.sh first"

# Refuse an unsafe development package before it reaches the device. This
# package is rootless-only and contained, so every member must land inside
# the jailbreak prefix; an entry anywhere else would outlive a jailbreak
# removal with no package manager left to clean it up.
archive_paths="$(dpkg-deb --fsys-tarfile "$DEB" | tar -tf -)"
while IFS= read -r member; do
    case "$member" in
        ./|./var/|./var/jb|./var/jb/*) ;;
        *) die "refusing package that installs outside /var/jb: $member" ;;
    esac
done <<<"$archive_paths"

ipad_ssh 'test -x /var/jb/usr/bin/jbctl || test -x /var/jb/basebin/jbctl' ||
    die "iPad is not running a rootless jailbreak; this package requires one"
system_bootpd_before="$(ipad_ssh 'sha256sum /usr/libexec/bootpd | cut -d" " -f1')"

REMOTE_DEB="/tmp/$(basename "$DEB")"
echo "copying standalone package to iPad: $DEB"
sshpass -p "$VZ_IPAD_PASSWORD" scp \
    "${IPAD_SCP_ARGS[@]}" "$DEB" "$IPAD_TARGET:$REMOTE_DEB"

# Package preinst owns VM termination.  Do not invoke the UI stop action here:
# it asks macOS to shut down and can leave an unattended guest confirmation
# sheet in front of the install.
set +e
install_output="$(ipad_ssh "dpkg -i '$REMOTE_DEB' 2>&1" 2>&1)"
install_status=$?
set -e
printf '%s\n' "$install_output"
((install_status == 0)) || die "dpkg installation failed"

# Maintainer scripts never respring. Sileo consumes finish:restart and offers
# the user its Restart SpringBoard button; direct dpkg installs remain online.
status="$(ipad_ssh "dpkg-query -W -f='\${db:Status-Status}' \
    com.mac.virtual 2>/dev/null || true")"
[[ "$status" == installed ]] ||
    die "package did not reach installed state (status: ${status:-missing})"

ipad_ssh "
set -eu
test -u /var/jb/usr/libexec/VirtualMac/install/install-launcher
test -d /var/jb/var/mobile/VirtualMac
"

ipad_ssh "
set -eu
test -x /var/jb/Applications/VirtualMac.app/VirtualMac
test -f /var/jb/usr/lib/TweakInject/VZKeyboardPassthrough.dylib
test -f /var/jb/usr/lib/TweakInject/VZKeyboardPassthrough.plist
if test -L /var/jb/Library/MobileSubstrate/DynamicLibraries; then
    test -f /var/jb/Library/MobileSubstrate/DynamicLibraries/VZKeyboardPassthrough.dylib
fi
launchctl print user/501/vzi.apple.bootpd >/dev/null
launchctl print user/501/com.apple.NetworkSharing >/dev/null
/var/jb/usr/bin/uicache -l | grep -F 'com.mac.virtual' >/dev/null
"

system_bootpd_after="$(ipad_ssh 'sha256sum /usr/libexec/bootpd | cut -d" " -f1')"
[[ "$system_bootpd_after" == "$system_bootpd_before" ]] ||
    die "Apple /usr/libexec/bootpd changed during package installation"
ipad_ssh "rm -f '$REMOTE_DEB'"

echo "standalone package installed and registered on iPad"
