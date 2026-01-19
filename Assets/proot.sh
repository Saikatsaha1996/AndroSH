#!/system/bin/sh

export LD_LIBRARY_PATH={{dir}}/lib
export TERM=xterm-256color
export PROOT_TMP_DIR={{dir}}/tmp

PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:{{dir}}/bin:/system/bin:/system/xbin:/vendor/bin:/product/bin:/odm/bin:/system_ext/bin:$PATH"

PROOT_MAIN={{dir}}
ROOTFS_DIR=$PROOT_MAIN/{{distro}}
PROOT_BIN=$PROOT_MAIN/bin/proot

ARGS="--kill-on-exit"
ARGS="$ARGS -w /root"

# ---------- Android bind mounts ----------
for data_dir in /data /data/app /data/data /data/user /data/user_de \
    /data/dalvik-cache /data/misc /data/system /data/vendor; do
    [ -e "$data_dir" ] && ARGS="$ARGS -b $data_dir"
done

for system_mnt in / /system /vendor /product /system_ext /odm /apex; do
    [ -e "$system_mnt" ] && ARGS="$ARGS -b $system_mnt"
done

# ---------- Storage ----------
if [ -e /storage/emulated/0 ]; then
    ARGS="$ARGS -b /storage"
    ARGS="$ARGS -b /storage/emulated/0:/sdcard"
fi

# ---------- Core ----------
ARGS="$ARGS -b /dev"
ARGS="$ARGS -b /proc"
ARGS="$ARGS -b /sys"
ARGS="$ARGS -b /proc/self/fd:/dev/fd"
ARGS="$ARGS -b /proc/self/fd/0:/dev/stdin"
ARGS="$ARGS -b /proc/self/fd/1:/dev/stdout"
ARGS="$ARGS -b /proc/self/fd/2:/dev/stderr"

# ---------- TMP (DBUS SAFE PART) ----------
# Ensure fake /tmp inside rootfs (DO NOT bind Android paths)
mkdir -p "$ROOTFS_DIR/tmp"
chmod 1777 "$ROOTFS_DIR/tmp"

mkdir -p "$ROOTFS_DIR/dev/shm"
chmod 1777 "$ROOTFS_DIR/dev/shm"

ARGS="$ARGS -b $ROOTFS_DIR/dev/shm:/dev/shm"
# ❌ NO /tmp bind — let proot fake FS handle it

# ---------- Proot core ----------
ARGS="$ARGS -r $ROOTFS_DIR"
ARGS="$ARGS -0"
ARGS="$ARGS --link2symlink"
ARGS="$ARGS --sysvipc"
ARGS="$ARGS -L"
ARGS="$ARGS --kernel-release=6.6.30-AndroSH"

if $PROOT_BIN --ashmem-memfd true >/dev/null 2>&1; then
    ARGS="$ARGS --ashmem-memfd"
fi

# ---------- One-time patch ----------
if [ ! -f "$PROOT_MAIN/patched" ]; then
    {
        echo "export HOME=/root"
        echo "export TERM=xterm-256color"
        echo "export LANG=C.UTF-8"
        echo "export HOSTNAME={{hostname}}"
        echo "export ANDROID_DATA=/data"
        echo "export ANDROID_ROOT=/system"
        echo "export ANDROID_STORAGE=/storage"
    } >> "$ROOTFS_DIR/etc/profile"

    echo "{{hostname}}" > "$ROOTFS_DIR/etc/hostname"
    echo "127.0.1.1 {{hostname}}" >> "$ROOTFS_DIR/etc/hosts"

    echo "nameserver 1.1.1.1" > "$ROOTFS_DIR/etc/resolv.conf"
    echo "nameserver 1.0.0.1" >> "$ROOTFS_DIR/etc/resolv.conf"

    touch "$PROOT_MAIN/patched"
fi

# ---------- Launch ----------
if [ $# -gt 0 ]; then
    exec $PROOT_BIN $ARGS "$@"
else
    exec $PROOT_BIN $ARGS /bin/sh --login
fi
