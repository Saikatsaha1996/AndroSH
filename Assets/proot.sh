#!/system/bin/sh

# shellcheck disable=SC1083
export LD_LIBRARY_PATH={{dir}}/lib
export PROOT_TMP_DIR={{dir}}/tmp
export TERM=xterm-256color
#export PROOT_NO_SECCOMP=1

PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/games:/usr/local/bin:/usr/local/sbin:{{dir}}/bin:/system/bin:/system/xbin:/vendor/bin:/product/bin:/odm/bin:/system_ext/bin:\$PATH"

PROOT_MAIN={{dir}}
ROOTFS_DIR=$PROOT_MAIN/{{distro}}
PROOT_BIN=$PROOT_MAIN/bin/proot

# ------------------------
# TMP + XDG_RUNTIME_DIR fix
# ------------------------
mkdir -p "$ROOTFS_DIR/tmp"
chmod 1777 "$ROOTFS_DIR/tmp"

export TMPDIR=$ROOTFS_DIR/tmp
export TEMP=$ROOTFS_DIR/tmp
export TMP=$ROOTFS_DIR/tmp
export XDG_RUNTIME_DIR=$ROOTFS_DIR/tmp
chmod 700 "$XDG_RUNTIME_DIR"

# ------------------------
# Proot ARGS
# ------------------------
ARGS="--kill-on-exit"
ARGS="$ARGS -w /root"
ARGS="$ARGS -r $ROOTFS_DIR"
ARGS="$ARGS -0"
ARGS="$ARGS --link2symlink"
ARGS="$ARGS --sysvipc"
ARGS="$ARGS -L"

# bind necessary paths
ARGS="$ARGS -b $ROOTFS_DIR/tmp:/tmp"
ARGS="$ARGS -b $ROOTFS_DIR/tmp:/dev/shm"
ARGS="$ARGS -b /proc"
ARGS="$ARGS -b /proc/self/fd:/dev/fd"
ARGS="$ARGS -b /proc/self/fd/0:/dev/stdin"
ARGS="$ARGS -b /proc/self/fd/1:/dev/stdout"
ARGS="$ARGS -b /proc/self/fd/2:/dev/stderr"
ARGS="$ARGS -b /dev"
ARGS="$ARGS -b /dev/urandom:/dev/random"
ARGS="$ARGS -b /sys"
ARGS="$ARGS -b $PROOT_MAIN"

# ------------------------
# Bind storage + system (optional)
# ------------------------
for data_dir in /data /storage; do
    [ -e "$data_dir" ] && ARGS="$ARGS -b $data_dir"
done

# ------------------------
# Set host UID/GID in rootfs (optional)
# ------------------------
if [ ! -f "$PROOT_MAIN/patched" ]; then
    REAL_UID=$(grep '^Uid:' /proc/self/status | awk '{print $2}')
    REAL_GID=$(grep '^Gid:' /proc/self/status | awk '{print $2}')
    REAL_USER=$(id -un)

    chmod u+rw $ROOTFS_DIR/etc/passwd $ROOTFS_DIR/etc/group $ROOTFS_DIR/etc/shadow $ROOTFS_DIR/etc/gshadow 2>/dev/null || true

    if ! grep -q "aid_${REAL_USER}:" $ROOTFS_DIR/etc/passwd; then
        echo "aid_${REAL_USER}:x:${REAL_UID}:${REAL_GID}:Android User:/:/sbin/nologin" >> $ROOTFS_DIR/etc/passwd
        echo "aid_${REAL_USER}:*:18446:0:99999:7:::" >> $ROOTFS_DIR/etc/shadow
    fi

    for g in $(id -Gn); do
        gid=$(id -G | cut -d' ' -f1)  # simplified
        if ! grep -q "aid_${g}:" $ROOTFS_DIR/etc/group; then
            echo "aid_${g}:x:${gid}:root,aid_${REAL_USER}" >> $ROOTFS_DIR/etc/group
            echo "aid_${g}:*::root,aid_${REAL_USER}" >> $ROOTFS_DIR/etc/gshadow 2>/dev/null
        fi
    done

    touch $PROOT_MAIN/patched
fi

# ------------------------
# Start dbus inside proot FS
# ------------------------
DBUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
export DBUS_SESSION_BUS_ADDRESS=$DBUS_ADDRESS

# start dbus-daemon only if not running
pgrep -x dbus-daemon >/dev/null || \
dbus-daemon --session --address=$DBUS_ADDRESS --nofork --nopidfile &

# ------------------------
# Run proot
# ------------------------
if [ $# -gt 0 ]; then
    $PROOT_BIN $ARGS "$@"
else
    $PROOT_BIN $ARGS /bin/sh -c "if command -v {{chsh}} >/dev/null 2>&1; then exec {{chsh}} --login; else exec sh; fi"
fi
