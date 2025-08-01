#!/bin/bash

set -e

if [ "$1" = start ]; then
  
  PATH=/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin

  # Mount /proc if it is not already mounted:
  if [ ! -d /proc/sys ]; then
    mount -n -t proc proc /proc
  fi

  # Mount /sys if it is not already mounted:
    if [ ! -d /sys/kernel ]; then
      mount -n -t sysfs sysfs /sys
    fi
    
  # Mount efivarfs if it is not already mounted:
  if [ -d /sys/firmware/efi/efivars ]; then
    if ! mount | grep -wq efivarfs ; then
      if [ -r /etc/default/efivarfs ]; then
        . /etc/default/efivarfs
      else
        EFIVARFS=rw
      fi
      case "$EFIVARFS" in
        'rw')
          mount -o rw -t efivarfs none /sys/firmware/efi/efivars
          ;;
        'ro')
          mount -o ro -t efivarfs none /sys/firmware/efi/efivars
          ;;
      esac
    fi
  fi

  # If /run exists, mount a tmpfs on it (unless the
  # initrd has already done so):
# If /run exists, mount a tmpfs on it (unless the
# initrd has already done so):
if [ -d /run ]; then
  if ! grep -wq "tmpfs /run tmpfs" /proc/mounts ; then
    # Other Linux systems seem to cap the size of /run to half the system memory.
    # We'll go with 25% which should be much larger than the previous default of
    # 32M :-)
    RUNSIZE="$(expr $(grep MemTotal: /proc/meminfo | rev | cut -f 2 -d ' ' | rev) / 1024 / 4)M"
    /sbin/mount -v -t tmpfs tmpfs /run -o mode=0755,size=$RUNSIZE,nodev,nosuid,noexec
    unset RUNSIZE
    # various directories within /run:
      mkdir /run/lock /run/udev
  fi
fi

  # Mount devtmpfs, checking if already mounted:
  if ! grep -wq "devtmpfs /dev devtmpfs" /proc/mounts ; then
    # umount shm if needed
    if grep -wq "tmpfs /dev/shm tmpfs" /proc/mounts ; then
      umount -l /dev/shm
    fi
    
    # umount pts if needed
    if grep -wq "devpts /dev/pts devpts" /proc/mounts ; then
      umount -l /dev/pts
    fi
    mount -n -t devtmpfs -o size=8M devtmpfs /dev
  fi

  # Mount /dev/pts if needed:
  if ! grep -wq "devpts /dev/pts devpts" /proc/mounts ; then
    mkdir -p /dev/pts
    mount -n -t devpts -o mode=0620,gid=5 devpts /dev/pts
  fi

  # Mount /dev/shm if needed:
  if ! grep -wq "tmpfs /dev/shm tmpfs" /proc/mounts ; then
    mkdir -p /dev/shm
    mount -n -t tmpfs tmpfs /dev/shm
  fi

  # Load the kernel loop module. Doing this because its enabled on 
  # slackware by default, presumably to mount loop devices at early boot:
  if modinfo loop ; then
    if ! lsmod | grep -wq "^loop" ; then
      modprobe loop
    fi
  fi

  # Mount the Control Groups filesystem interface.
if grep -wq cgroup2 /proc/filesystems && grep -wq "cgroup_no_v1=all" /proc/cmdline ; then
# Load default setting for v1 or v2:
  if [ -e /etc/default/cgroups ]; then
    . /etc/default/cgroups
  fi
  # If CGROUPS_VERSION=2 in /etc/default/cgroups, then mount as cgroup-v2:
  # See linux-*/Documentation/admin-guide/cgroup-v2.rst (section 2-1)
  if [ "$CGROUPS_VERSION" = "2" ]; then
    if [ -d /sys/fs/cgroup ]; then
      mount -t cgroup2 none /sys/fs/cgroup
    else
      mkdir -p /dev/cgroup
      mount -t cgroup2 none /dev/cgroup
    fi
  elif [ "$CGROUPS_VERSION" = "1" ] || [ -z "$CGROUPS_VERSION"]; then # mount as cgroup-v1 (default):
    if [ -d /sys/fs/cgroup ]; then
      # See linux-*/Documentation/admin-guide/cgroup-v1/cgroups.rst (section 1.6)
      # Mount a tmpfs as the cgroup filesystem root:
      mount -t tmpfs -o mode=0755,size=8M cgroup_root /sys/fs/cgroup
      # Autodetect available controllers and mount them in subfolders:
      for i in $(/bin/cut -f 1 /proc/cgroups | /bin/tail -n +2) ; do
        mkdir /sys/fs/cgroup/$i
        mount -t cgroup -o $i $i /sys/fs/cgroup/$i
      done
      unset i
    else
      mkdir -p /dev/cgroup
      mount -t cgroup cgroup /dev/cgroup
      fi
    fi
  fi
fi

# Enable swapping:
if [ -z "$container" ]; then
  /sbin/swapon -a 2> /dev/null
fi

if ! grep -qw fuse /proc/filesystems; then
   echo -n "Loading fuse module"
   if ! modprobe fuse >/dev/null 2>&1; then
   echo " failed!"
  exit 1
else
 echo "."
 fi
else
   echo "Fuse filesystem already available."
fi

if grep -qw fusectl /proc/filesystems && \
  ! grep -qw $MOUNTPOINT /proc/mounts; then
   echo -n "Mounting fuse control filesystem"
  if ! mount -t fusectl fusectl $MOUNTPOINT >/dev/null 2>&1; then
      echo " failed!"
  exit 1
else
  echo "."
fi
else
  echo "Fuse control filesystem already available."
fi
        
# Enable swapping on a ZRAM device:
if [ -z "$container" -a -r /etc/default/zram ]; then
  . /etc/default/zram
  if [ "$ZRAM_ENABLE" = "1" ]; then
    if [ ! -d /sys/devices/virtual/block/zram0 ]; then
      modprobe zram num_devices=$ZRAMNUMBER
    fi
    echo "Setting up /dev/zram0:  zramctl -f -a $ZRAMCOMPRESSION -s ${ZRAMSIZE}K"
    ZRAM_DEVICE=$(zramctl -f -a $ZRAMCOMPRESSION -s ${ZRAMSIZE}K)
    if [ ! -z $ZRAM_DEVICE ]; then
      mkswap $ZRAM_DEVICE 1> /dev/null 2> /dev/null
      echo "Activating ZRAM swap:  swapon --priority $ZRAMPRIORITY $ZRAM_DEVICE"
      swapon --priority $ZRAMPRIORITY $ZRAM_DEVICE
    fi
  fi
  unset MEMTOTAL ZRAMCOMPRESSION ZRAMNUMBER ZRAMSIZE ZRAM_DEVICE ZRAM_ENABLE
fi
