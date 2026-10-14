#!/bin/sh
# Install the KMC payload on a Kindle 7 (KT2), firmware 5.12.2.2.
#
# jb.sh v2.2.1 unpacks a 23.8 MB tar.xz into /tmp (-> /var/tmp, a 32 MB tmpfs
# with 26 MB free) before logging is initialised, so when that step fails the
# script carries on and every later copy silently no-ops. This takes the
# already-unpacked payload from /mnt/us instead, then reproduces jb.sh's
# 04_setup_kmc and 06_patch_system stages verbatim.
#
# Launched as root by winterbreak2/dialoger.html. Full trace in /mnt/us/install.log.

LOG=/mnt/us/install.log
SRC=/mnt/us/kmc-payload

PLATFORM=kindlepw2
if [ -f /lib/ld-linux-armhf.so.3 ]; then PLATFORM=kindlehf; fi

exec > "$LOG" 2>&1
set -x
date
id
echo "PLATFORM=$PLATFORM"

echo "### which tools exist (this is why the original unpack failed)"
for t in xz unxz base64 tar sqlite3 chattr chown; do
    printf '%s: ' "$t"; command -v "$t" || echo MISSING
done

echo "### source payload"
ls -la "$SRC"
du -ks "$SRC"

echo "### before"
df -k /var/local /var
ls -la /var/local/kmc

CHATTR=/bin/chattr
if [ ! -f "$CHATTR" ]; then CHATTR=/bin/chattr.e2fsprogs; fi

make_mutable() {
    [ -e "$1" ] || return 0
    find "$1" -type d -exec "$CHATTR" -i {} \; 2>/dev/null
    find "$1" -type f -exec "$CHATTR" -i {} \; 2>/dev/null
}
make_immutable() {
    [ -e "$1" ] || return 0
    find "$1" -type d -exec "$CHATTR" +i {} \; 2>/dev/null
    find "$1" -type f -exec "$CHATTR" +i {} \; 2>/dev/null
}

echo "### wipe old kmc and mkk"
make_mutable /var/local/mkk
rm -rf /var/local/mkk
mkdir -p /var/local/mkk
make_mutable /var/local/kmc
rm -rf /var/local/kmc
mkdir -p /var/local/kmc

echo "### copy payload into /var/local/kmc"
cp -rf "$SRC"/* /var/local/kmc/
ls -la /var/local/kmc
du -ks /var/local/kmc

echo "### permissions (jb.sh 04_setup_kmc)"
chmod -R a+rx /var/local/kmc/sbin/*
chmod -R a+rx /var/local/kmc/kindlepw2/*
chmod -R a+rx /var/local/kmc/kindlehf/*
chmod 0664 /var/local/kmc/system_patches/kmc.conf
chmod a+rx /var/local/kmc/system_patches/patch_system.sh
chmod a+rx /var/local/kmc/system_patches/run_patch.sh

for p in kindlepw2 kindlehf; do
    make_mutable "/var/local/kmc/${p}/bin/gandalf"
    chown root:root "/var/local/kmc/${p}/bin/gandalf"
    chmod a+rx "/var/local/kmc/${p}/bin/gandalf"
    chmod +s "/var/local/kmc/${p}/bin/gandalf"
    ln -sf "/var/local/kmc/${p}/bin/gandalf" "/var/local/kmc/${p}/bin/su"
    make_immutable "/var/local/kmc/${p}/bin/gandalf"
done

echo "### gandalf links"
rm -rf /var/local/kmc/lib /var/local/kmc/bin
ln -sf "/var/local/kmc/${PLATFORM}/lib" /var/local/kmc/lib
ln -sf "/var/local/kmc/${PLATFORM}/bin" /var/local/kmc/bin
ln -sf /var/local/kmc/bin/gandalf /var/local/mkk/gandalf
make_mutable /var/local/mkk
ln -sf /var/local/mkk/gandalf /var/local/mkk/su
make_immutable /var/local/mkk
make_immutable /var/local/kmc
ls -la /var/local/kmc/bin/
ls -la /var/local/mkk/

echo "### libkh binaries"
mkdir -p /mnt/us/libkh/bin
rm -f /mnt/us/libkh/bin/fbink
cp -f "/var/local/kmc/${PLATFORM}/bin/fbink" /mnt/us/libkh/bin/fbink
chmod a+rx /mnt/us/libkh/bin/fbink
ls -la /mnt/us/libkh/bin

echo "### appreg: hotfix and emergency runners"
sqlite3 /var/local/appreg.db < /var/local/kmc/sql/appreg_register_hotfix.sql
sqlite3 /var/local/appreg.db < /var/local/kmc/sql/appreg_register_emergency.sql

echo "### run patch_system.sh (installs kmc.conf, logThis.sh, sh_integration)"
ROOTLESS=0 RUN_MODE=1 JAILBROKEN=0 sh /var/local/kmc/system_patches/patch_system.sh

echo "### cleanup remounts (jb.sh 07_cleanup)"
/bin/mount -o remount,ro /
/bin/mount -o exec /mnt/us

echo "### after"
ls -la /etc/upstart/kmc.conf
ls -la /usr/bin/logThis.sh
ls -la /usr/lib/ccat/sh_integration_extractor.so
sqlite3 /var/local/appreg.db "SELECT * FROM mimetypes WHERE ext='sh';"
sqlite3 /var/local/appreg.db "SELECT handlerId,name,value FROM properties WHERE handlerId LIKE '%shell_integration%';"
df -k /var/local
mount | grep -E ' / type| /mnt/us type'
date
set +x
sync

eips 0 12 "install done - replug USB  " 2>/dev/null
exit 0
