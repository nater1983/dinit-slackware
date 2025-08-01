#!/bin/sh
export PATH=/usr/bin:/usr/sbin:/bin:/sbin

set -e

MOUNTPOINT=/sys/fs/fuse/connections

check_command() {
  command -v "$1" >/dev/null 2>&1 || exit 5
}

load_fuse() {
  echo -n "Loading fuse module"
  if ! modprobe fuse >/dev/null 2>&1; then
    echo " failed!"
    exit 1
  else
    echo "."
  fi
}

mount_fusectl() {
  echo -n "Mounting fuse control filesystem"
  if ! mount -t fusectl fusectl "$MOUNTPOINT" >/dev/null 2>&1; then
    echo " failed!"
    exit 1
  else
    echo "."
  fi
}

unmount_fusectl() {
  echo -n "Unmounting fuse control filesystem"
  if ! umount "$MOUNTPOINT" >/dev/null 2>&1; then
    echo " failed!"
  else
    echo "."
  fi
}

unload_fuse() {
  echo -n "Unloading fuse module"
  if ! rmmod fuse >/dev/null 2>&1; then
    echo " failed!"
  else
    echo "."
  fi
}

case "$1" in
  start)
    check_command fusermount3 || check_command fusermount

    if ! grep -qw fuse /proc/filesystems; then
      load_fuse
    else
      echo "Fuse filesystem already available."
    fi

    if grep -qw fusectl /proc/filesystems && ! grep -qw "$MOUNTPOINT" /proc/mounts; then
      mount_fusectl
    else
      echo "Fuse control filesystem already available."
    fi
    ;;

  stop)
    if ! grep -qw fuse /proc/filesystems; then
      echo "Fuse filesystem not loaded."
      exit 7
    fi

    if grep -qw "$MOUNTPOINT" /proc/mounts; then
      unmount_fusectl
    else
      echo "Fuse control filesystem not mounted."
    fi

    if grep -qw "^fuse" /proc/modules; then
      unload_fuse
    else
      echo "Fuse module not loaded."
    fi
    ;;

  *)
    echo "Usage: $0 {start|stop}"
    exit 2
    ;;
esac
