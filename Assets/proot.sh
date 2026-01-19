#!/system/bin/sh

# shellcheck disable=SC1083
export LD_LIBRARY_PATH={{dir}}/lib
export PROOT_TMP_DIR={{dir}}/tmp
export TERM=xterm-256color
#export PROOT_NO_SECCOMP=1

PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/games:/usr/local/bin:/usr/local/sbin:{{dir}}/bin:/system/bin:/system/xbin:/vendor/bin:/product/bin:/odm/bin:/system_ext/bin:\$PATH"

# shellcheck disable=SC1083
PROOT_MAIN={{dir}}
ROOTFS_DIR=$PROOT_MAIN/{{distro}}
PROOT_BIN=$PROOT_MAIN/bin/proot

ARGS="--kill-on-exit"
ARGS="$ARGS -w /root"

for data_dir in /data /data/app /data/data /data/user /data/user_de \
    /data/dalvik-cache /data/misc /data/system /data/vendor \
    /data/misc_ce /data/misc_de /data/misc_apexdata \
    /data/misc/apexdata/com.android.art/dalvik-cache; do
    if [ -e "$data_dir" ]; then
        ARGS="$ARGS -b ${data_dir}"
    fi
done
unset data_dir

for system_mnt in / /system /vendor /product /system_ext /odm /apex \
    /firmware /persist /metadata /efs /omr /spu /prism /optics \
    /linkerconfig /linkerconfig/ld.config.txt \
    /linkerconfig/com.android.art/ld.config.txt \
    /plat_property_contexts /property_contexts /vendor_property_contexts \
    /system/etc/selinux /vendor/etc/selinux /product/etc/selinux \
    /init /init.rc /default.prop /system/build.prop /vendor/build.prop /dsp \
    /bt_firmware /acct; do

    if [ -e "$system_mnt" ]; then
        system_path=$(readlink -f "$system_mnt" 2>/dev/null || echo "$system_mnt")
        ARGS="$ARGS -b ${system_path}"
    fi
done
unset system_mnt system_path

storage_path=""
if [ -e "/storage/emulated/0" ]; then
    storage_path="/storage/emulated/0"
elif [ -e "/storage/self/primary" ]; then
    storage_path="/storage/self/primary"
elif [ -e "/sdcard" ]; then
    storage_path="/sdcard"
fi

if [ -n "$storage_path" ]; then
    ARGS="$ARGS -b ${storage_path}:/sdcard"
    ARGS="$ARGS -b ${storage_path}:/storage/emulated/0"
    ARGS="$ARGS -b ${storage_path}:/storage/self/primary"
    ARGS="$ARGS -b ${storage_path}:/mnt/sdcard"
    # Bind entire storage hierarchy
    ARGS="$ARGS -b /storage"
fi
unset storage_path

ARGS="$ARGS --kernel-release=6.6.30-AndroSH"

ARGS="$ARGS -b /dev"
ARGS="$ARGS -b /dev/urandom:/dev/random"
ARGS="$ARGS -b /proc"
ARGS="$ARGS -b /proc/self/fd:/dev/fd"
ARGS="$ARGS -b /proc/self/fd/0:/dev/stdin"
ARGS="$ARGS -b /proc/self/fd/1:/dev/stdout"
ARGS="$ARGS -b /proc/self/fd/2:/dev/stderr"
ARGS="$ARGS -b $PROOT_MAIN"
ARGS="$ARGS -b /sys"
#ARGS="$ARGS -b /cache"

if [ ! -d "$ROOTFS_DIR/tmp" ]; then
    mkdir -p "$ROOTFS_DIR/tmp"
    chmod 1777 "$ROOTFS_DIR/tmp"
fi

ARGS="$ARGS -b $ROOTFS_DIR/tmp:/tmp"
ARGS="$ARGS -b $ROOTFS_DIR/tmp:/dev/shm"

ARGS="$ARGS -r $ROOTFS_DIR"
ARGS="$ARGS -0"
ARGS="$ARGS --link2symlink"
ARGS="$ARGS --sysvipc"
ARGS="$ARGS -L"
# shellcheck disable=SC2046
# shellcheck disable=SC3014
if [ $($PROOT_BIN --ashmem-memfd echo "supported" 2> /dev/null || echo "unsupported") == "supported" ];then
  ARGS="$ARGS --ashmem-memfd"
fi
#ARGS="$ARGS -v -1"

if [ ! -f $PROOT_MAIN/patched ]; then
    # shellcheck disable=SC2129
    echo "export PATH=$PATH" >> $ROOTFS_DIR/etc/profile
    echo "export HOME=/root" >> $ROOTFS_DIR/etc/profile
    echo "export TERM=xterm-256color" >> $ROOTFS_DIR/etc/profile
    echo "export LANG=C.UTF-8" >> $ROOTFS_DIR/etc/profile
    echo "export HOSTNAME={{hostname}}" >> $ROOTFS_DIR/etc/profile
    # shellcheck disable=SC2016
    # shellcheck disable=SC2028
    echo '#export PS1=$(echo "$PS1"|sed -e "s/\\\\\h/\${HOSTNAME}/g")' >> $ROOTFS_DIR/etc/profile
    echo "{{hostname}}" > $ROOTFS_DIR/etc/hostname
    echo "127.0.1.1       {{hostname}}" >> $ROOTFS_DIR/etc/hosts
    echo "nameserver 1.1.1.1" > $ROOTFS_DIR/etc/resolv.conf
    echo "nameserver 1.0.0.1" >> $ROOTFS_DIR/etc/resolv.conf
    # Android environment variables
    # shellcheck disable=SC2129
    echo "export ANDROID_DATA=/data" >> $ROOTFS_DIR/etc/profile
    echo "export ANDROID_ROOT=/system" >> $ROOTFS_DIR/etc/profile
    echo "export ANDROID_STORAGE=/storage" >> $ROOTFS_DIR/etc/profile
    mkdir -p $PROOT_MAIN/tmp
    touch $PROOT_MAIN/patched
fi

if [ ! -f "$PROOT_MAIN/patched" ]; then
    echo "[*] Applying Android UID/GID fix..."

    REAL_UID=$(grep '^Uid:' /proc/self/status | awk '{print $2}')
    REAL_GID=$(grep '^Gid:' /proc/self/status | awk '{print $2}')
    REAL_USER=$(id -un)

    chmod u+rw \
        $ROOTFS_DIR/etc/passwd \
        $ROOTFS_DIR/etc/group \
        $ROOTFS_DIR/etc/shadow \
        $ROOTFS_DIR/etc/gshadow 2>/dev/null || true

    if ! grep -q "aid_${REAL_USER}:" $ROOTFS_DIR/etc/passwd; then
        echo "aid_${REAL_USER}:x:${REAL_UID}:${REAL_GID}:Android User:/:/sbin/nologin" \
            >> $ROOTFS_DIR/etc/passwd
        echo "aid_${REAL_USER}:*:18446:0:99999:7:::" \
            >> $ROOTFS_DIR/etc/shadow
    fi

    # --- Fix for paste <(...) in shells without process substitution ---
    TMPNAMES=$(mktemp)
    TMPIDS=$(mktemp)

    id -Gn | tr ' ' '\n' > "$TMPNAMES"
    id -G  | tr ' ' '\n' > "$TMPIDS"

    paste "$TMPNAMES" "$TMPIDS" | while read -r gname gid; do
        if ! grep -q "aid_${gname}:" $ROOTFS_DIR/etc/group; then
            echo "aid_${gname}:x:${gid}:root,aid_${REAL_USER}" \
                >> $ROOTFS_DIR/etc/group
            echo "aid_${gname}:*::root,aid_${REAL_USER}" \
                >> $ROOTFS_DIR/etc/gshadow 2>/dev/null
        fi
    done

    # Clean up temporary files
    rm -f "$TMPNAMES" "$TMPIDS"
fi
    
if [ $# -gt 0 ]; then
    # shellcheck disable=SC2086
    $PROOT_BIN $ARGS "$@"
else
    # shellcheck disable=SC2086
    $PROOT_BIN $ARGS /bin/sh -c "if command -v {{chsh}} >/dev/null 2>&1; then exec {{chsh}} --login; else exec sh; fi"
fi
