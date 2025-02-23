#!/bin/bash

if [ "$1" = start ]; then
  PATH=/usr/bin:/usr/sbin:/bin:/sbin
  
  [ -x /etc/rc.d/rc.local ] && /etc/rc.d/rc.local
fi
