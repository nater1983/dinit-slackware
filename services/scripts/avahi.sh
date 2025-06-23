#!/bin/bash
export PATH=/usr/bin:/usr/sbin:/bin:/sbin

set -e

if [ "$1" != "stop" ]; then
  if [ -x /usr/sbin/avahi-daemon ]; then
    echo "Avahi mDNS/DNS-SD Daemon: avahi-daemon -D"
    /usr/sbin/avahi-daemon -D
  if [ -x /usr/sbin/avahi-dnsconfd ]; then
    echo "Avahi mDNS/DNS-SD DNS Server Configuration Daemon: avahi-dnsconfd -D"
    /usr/sbin/avahi-dnsconfd -D
  fi
  fi
fi;
