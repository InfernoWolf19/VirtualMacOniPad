#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

need_command ditto
need_command dpkg-deb
need_command file
need_command ldid
need_command plutil
need_command rsync
need_command xattr

if [[ "${VZ_SKIP_REBUILD:-0}" != 1 ]]; then
    "$SCRIPT_DIR/build-ipad-vm.sh"
    "$SCRIPT_DIR/build-ipad-network-helpers.sh"
    "$SCRIPT_DIR/build-ipad-network-sharing.sh"
    "$SCRIPT_DIR/build-ipad-installation.sh"
    "$SCRIPT_DIR/build-ipad-app.sh"
    "$SCRIPT_DIR/build-springboard-tweak.sh"
fi
"$SCRIPT_DIR/audit-ipados-compatibility.sh"

commit_count="$(git -C "$VZ_REPO_ROOT" rev-list --count HEAD)"
commit_hash="$(git -C "$VZ_REPO_ROOT" rev-parse --short=10 HEAD)"
app_build="$(plutil -extract CFBundleVersion raw \
    "$VZ_BUILD_ROOT/ipad-app/VirtualMac.app/Info.plist")"
[[ "$app_build" == "$commit_count" ]] ||
    die "app build $app_build does not match repository build $commit_count; rebuild the app"
RELEASE_VERSION="${VZ_RELEASE_VERSION:-1.2.3}"
if [[ -n "${VZ_PACKAGE_VERSION:-}" ]]; then
    VERSION="$VZ_PACKAGE_VERSION"
else
    # Epoch 2 supersedes both the early hash-only packages and the previously
    # published `+git` version scheme. Commit count supplies monotonic Debian
    # ordering; the hash keeps provenance without adding a redundant marker.
    VERSION="2:${RELEASE_VERSION}+${commit_count}.${commit_hash}"
fi
PACKAGE_NAME="VirtualMac_${RELEASE_VERSION}_${commit_hash}.deb"
RELEASE="$VZ_BUILD_ROOT/release"
STAGE="$(mktemp -d -t VirtualMac-deb.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

# mktemp intentionally creates a private 0700 directory.  A package archive
# must not carry that mode on its `./` entry: dpkg may otherwise try to apply
# it to the filesystem root while unpacking.  All payload parents are public
# system directories, so normalize the staging root before creating them.
chmod 755 "$STAGE"

mkdir -p \
    "$STAGE/DEBIAN" \
    "$STAGE/var/jb/usr/libexec/VirtualMac" \
    "$STAGE/var/jb/Applications" \
    "$STAGE/var/jb/Library/LaunchDaemons" \
    "$STAGE/var/jb/basebin/LaunchDaemons" \
    "$STAGE/var/jb/usr/lib" \
    "$STAGE/var/jb/usr/libexec" \
    "$STAGE/var/jb/usr/bin" \
    "$STAGE/var/jb/usr/sbin" \
    "$STAGE/var/jb/usr/share/VirtualMac" \
    "$STAGE/var/jb/usr/libexec/VirtualMac/bootstrap-common/usr/lib/TweakInject" \
    "$RELEASE"

ditto "$VZ_BUILD_ROOT/ipad-installation/payload" \
    "$STAGE/var/jb/usr/libexec/VirtualMac/payload"
# The installation build consumes the VM compatibility dylib, so its cached
# payload may lag during a fast VM-only iteration.  Overlay the authoritative
# VM runtime last; both services intentionally use this one shared framework
# tree in the final package.
ditto "$VZ_BUILD_ROOT/ipad-vm/payload" \
    "$STAGE/var/jb/usr/libexec/VirtualMac/payload"
ditto "$VZ_BUILD_ROOT/ipad-installation/install" \
    "$STAGE/var/jb/usr/libexec/VirtualMac/install"
ditto "$VZ_BUILD_ROOT/ipad-app/VirtualMac.app" \
    "$STAGE/var/jb/Applications/VirtualMac.app"
install -m 755 "$VZ_BUILD_ROOT/ipad-app/virtualmac-diagnostics" \
    "$STAGE/var/jb/usr/bin/virtualmac-diagnostics"

# The component builds retain command-line probes for developer iteration.
# They are not used by the app and do not belong in the end-user package.
rm -rf "$STAGE/var/jb/usr/libexec/VirtualMac/payload/bin"
rm -f \
    "$STAGE/var/jb/usr/libexec/VirtualMac/payload/trustcache.txt" \
    "$STAGE/var/jb/usr/libexec/VirtualMac/install/restore-image-probe" \
    "$STAGE/var/jb/usr/libexec/VirtualMac/install/usb-bridge-probe"

install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/InternetSharing" \
    "$STAGE/var/jb/usr/libexec/InternetSharing"
install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/InternetSharing.ipados14" \
    "$STAGE/var/jb/usr/libexec/InternetSharing.ipados14"
install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/InternetSharing.ipados15" \
    "$STAGE/var/jb/usr/libexec/InternetSharing.ipados15"
install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/InternetSharing.ipados16" \
    "$STAGE/var/jb/usr/libexec/InternetSharing.ipados16"
# Keep every host-selected image at its explicit versioned path, even when a
# pair is currently byte-identical. This makes post-install selection
# auditable and prevents an iPadOS 14/16 installation from implicitly relying
# on a file named for iPadOS 15.
install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/libmrc.dylib" \
    "$STAGE/var/jb/usr/lib/libmrc.dylib"
install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/libmrc.ipados15-auth.dylib" \
    "$STAGE/var/jb/usr/lib/libmrc.ipados15-auth.dylib"
install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/AuthorizationCompat.dylib" \
    "$STAGE/var/jb/usr/lib/AuthorizationCompat.dylib"
install -m 755 "$VZ_BUILD_ROOT/ipad-network-sharing/NetworkMemoryPolicy.dylib" \
    "$STAGE/var/jb/usr/lib/NetworkMemoryPolicy.dylib"
install -m 755 "$VZ_BUILD_ROOT/ipad-network-helpers/bootpd" \
    "$STAGE/var/jb/usr/libexec/bootpd"
install -m 755 "$VZ_BUILD_ROOT/ipad-network-helpers/rtadvd" \
    "$STAGE/var/jb/usr/sbin/rtadvd"
install -m 755 "$VZ_BUILD_ROOT/ipad-network-helpers/OpenDirectoryCompat.dylib" \
    "$STAGE/var/jb/usr/lib/OpenDirectoryCompat.dylib"
install -m 755 "$VZ_BUILD_ROOT/ipad-network-helpers/IOKit14Compat.dylib" \
    "$STAGE/var/jb/usr/lib/IOKit14Compat.dylib"
install -m 644 "$VZ_BUILD_ROOT/ipad-network-helpers/com.apple.bootpd.plist" \
    "$STAGE/var/jb/Library/LaunchDaemons/com.apple.bootpd.plist"
# This is an intentional mirror, not a second runtime payload: postinst uses
# Library/LaunchDaemons for the immediate user-domain bootstrap, while
# Dopamine's launchd hook discovers basebin/LaunchDaemons across a userspace
# reboot. Both entries must describe the same daemon.
for destination in \
    "$STAGE/var/jb/Library/LaunchDaemons/com.apple.NetworkSharing.plist" \
    "$STAGE/var/jb/basebin/LaunchDaemons/com.apple.NetworkSharing.plist"; do
    install -m 644 "$VZ_BUILD_ROOT/ipad-network-sharing/com.apple.NetworkSharing.plist" \
        "$destination"
done
install -m 755 "$VZ_BUILD_ROOT/ipad-tweak/VZKeyboardPassthrough.dylib" \
    "$STAGE/var/jb/usr/libexec/VirtualMac/bootstrap-common/usr/lib/TweakInject/VZKeyboardPassthrough.dylib"
install -m 644 "$VZ_BUILD_ROOT/ipad-tweak/VZKeyboardPassthrough.plist" \
    "$STAGE/var/jb/usr/libexec/VirtualMac/bootstrap-common/usr/lib/TweakInject/VZKeyboardPassthrough.plist"
# Releases before 1.1 owned the MobileSubstrate compatibility pathname. On
# some bootstraps it aliases usr/lib/TweakInject, so dpkg's obsolete-file pass
# can otherwise unlink a new canonical payload through the old name during an
# upgrade. Keep one neutral package-owned source and let postinst install the
# single loader copy after that pass has completed.

# iPadOS 14 InternetSharing is sandboxed and cannot call launchctl itself. A
# root launchd job watches /tmp/bootpd.plist and enables the private DHCP job
# once InternetSharing has written its configuration. postinst bootstraps this
# only on iPadOS 14; the established iPadOS 15/16 placement is unchanged.
install -m 755 "$VZ_REPO_ROOT/packaging/launchd/bootpd-controller.sh" \
    "$STAGE/var/jb/usr/libexec/VirtualMac/bootpd-controller.sh"
install -m 644 \
    "$VZ_REPO_ROOT/packaging/launchd/vzi.apple.bootpd-controller.plist" \
    "$STAGE/var/jb/Library/LaunchDaemons/vzi.apple.bootpd-controller.plist"
# Never package host filesystem metadata. Component builders also remove it
# before signing, but this catches metadata from every independently built
# app, XPC, framework, and packaging input.
find "$STAGE" -type f \( -name .DS_Store -o -name '._*' \) -delete
xattr -cr "$STAGE"

trustcache="$STAGE/var/jb/usr/share/VirtualMac/trustcache.txt"
: >"$trustcache"
while IFS= read -r -d '' candidate; do
    file "$candidate" | grep -q 'Mach-O' || continue
    hash="$(ldid -h "$candidate" | sed -n 's/^CDHash=//p')"
    [[ -n "$hash" ]] || die "could not read CDHash: $candidate"
    printf '%s\t/%s\n' "$hash" "${candidate#"$STAGE/"}" >>"$trustcache"
done < <(find "$STAGE" -type f -print0)

rsync -a "$VZ_REPO_ROOT/packaging/DEBIAN/" "$STAGE/DEBIAN/"
chmod 755 "$STAGE/DEBIAN/preinst" "$STAGE/DEBIAN/postinst" \
    "$STAGE/DEBIAN/prerm" "$STAGE/DEBIAN/postrm"
chmod 4755 "$STAGE/var/jb/usr/libexec/VirtualMac/install/install-launcher"
"$SCRIPT_DIR/audit-ipad-package-stage.sh" "$STAGE"
installed_size="$(du -sk "$STAGE" | awk '{print $1}')"
sed -i '' -e "s/@VERSION@/$VERSION/g" \
    -e "s/@MIN_IOS@/$VZ_IPADOS_MIN_VERSION/g" \
    -e "s/@INSTALLED_SIZE@/$installed_size/g" "$STAGE/DEBIAN/control"

dpkg-deb --root-owner-group --build "$STAGE" "$RELEASE/$PACKAGE_NAME"
dpkg-deb --info "$RELEASE/$PACKAGE_NAME"
echo "standalone package built: $RELEASE/$PACKAGE_NAME"
