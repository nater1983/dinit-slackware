#!/bin/bash
# /etc/rc.d/rc.inet1
# This script is used to bring up the various network interfaces.
#
# @(#)/etc/rc.d/rc.inet1 15.0  Wed Nov 10 08:17:22 UTC 2021  (pjv)

# If we are in an lxc container, set $container to skip parts of the script.
# Thanks to Matteo Bernardini <ponce@slackbuilds.org> and Chris Willing for
# the initial work making this script lxc compatible.
if grep -aq container=lxc /proc/1/environ 2> /dev/null ; then
  container="lxc"
fi

############################
# READ NETWORK CONFIG FILE #
############################

# Get the configuration information from /etc/rc.d/rc.inet1.conf:
. /etc/dinit.d/config/rc.inet1.conf

###########
# LOGGING #
###########

# Message logging.
info_log() {
  # If possible, log events in /var/log/messages:
  if [ -f /var/run/syslogd.pid ] && [ -x /usr/bin/logger ]; then
    /usr/bin/logger -t "rc.inet1" --id="$$" "$*"
  else
    printf "%s: %s\\n" "rc.inet1" "$*"
  fi
}

# Verbose logging.
debug_log() {
  if [ "$DEBUG_ETH_UP" = "yes" ]; then
    info_log "$*"
  fi
}

############################
# DETERMINE INTERFACE LIST #
############################

# Compose a list of interfaces from /etc/rc.d/rc.inet1.conf (with a maximum
# of 6 interfaces, but you can easily enlarge the interface limit
# - send me a picture of such a box :-).
# If a value for IFNAME[n] is not set, we assume it is an eth'n' interface.
# This way, the new script is compatible with older rc.inet1.conf files.
# The IFNAME array will be used to determine which interfaces to bring up/down.
MAXNICS=${MAXNICS:-6}
i=0
while [ $i -lt $MAXNICS ];
do
  IFNAME[$i]=${IFNAME[$i]:=eth${i}}
  i=$((i+1))
done
debug_log "List of interfaces: ${IFNAME[*]}"

####################
# PRE-LOAD MODULES #
####################

for i in "${IFNAME[@]}"; do
  # If the interface isn't in the kernel yet (but there's an alias for it in modules.conf),
  # then it should be loaded first:
  if [ ! -e /sys/class/net/${i%%[:.]*} ]; then # no interface yet
    if /sbin/modprobe -c | grep -v "^#" | grep -w "alias ${i%%[:.]*}" | grep -vw "alias ${i%%[:.]*} off" >/dev/null; then
      debug_log "/sbin/modprobe ${i%%[:.]*}"
      /sbin/modprobe ${i%%[:.]*}
      _DID_MODPROBE=1
    fi
  fi
done
# Normally the ipv6 module would be automatically loaded when the first IP is assigned to an
# interface (assuming ipv6 has not been disabled entirely), but autoconf/accept_ra need to be
# set to 0 before that happens, so try to pre-load ipv6 here.
if [ ! -e /proc/sys/net/ipv6 ]; then
  debug_log "/sbin/modprobe ipv6"
  /sbin/modprobe -q ipv6
  _DID_MODPROBE=1
fi
# If we did any module loading in the blocks above, sleep for a couple of
# seconds to give time for everything to "take"
[ -n "${_DID_MODPROBE}" ] && sleep 2
unset _DID_MODPROBE

######################
# LOOPBACK FUNCTIONS #
######################

# Function to bring up the loopback interface.  If loopback is
# already up, do nothing.
lo_up() {
  if [ -e /sys/class/net/lo ]; then
    if ! /sbin/ip link show dev lo | grep -wq -e "state UP" -e "state UNKNOWN" ; then
      info_log "lo: configuring interface"
      debug_log "/sbin/ip -4 address add 127.0.0.1/8 dev lo"
      /sbin/ip -4 address add 127.0.0.1/8 dev lo
      if [ -e /proc/sys/net/ipv6 ]; then
        debug_log "/sbin/ip -6 address add ::1/128 dev lo"
        /sbin/ip -6 address add ::1/128 dev lo
      fi
      debug_log "/sbin/ip link set dev lo up"
      /sbin/ip link set dev lo up
      debug_log "/sbin/ip route add 127.0.0.0/8 dev lo"
      /sbin/ip route add 127.0.0.0/8 dev lo
    fi
  fi
}

# Function to take down the loopback interface:
lo_down() {
  if [ -e /sys/class/net/lo ]; then
    info_log "lo: de-configuring interface"
    debug_log "/sbin/ip address flush dev lo"
    /sbin/ip address flush dev lo
    debug_log "/sbin/ip link set dev lo down"
    /sbin/ip link set dev lo down
  fi
}

#######################
# INTERFACE FUNCTIONS #
#######################

# Function to create virtual interfaces
virtif_create() {
  # argument is 'i' - the position of this interface in the VIRTIFNAME array.
  # this loop goes from i=0 to i=number_of_configured_virtual_interfaces_minus_one
  # which means it doesn't do anything if there are none.
  for i in $(seq 0 $((${#VIRTIFNAME[@]} - 1))); do
    info_log "${VIRTIFNAME[$i]}: creating virtual interface"
    debug_log "/sbin/ip tuntap add dev ${VIRTIFNAME[$i]} mode ${VIRTIFTYPE[$i]} user ${VIRTIFUSER[$i]} group ${VIRTIFGROUP[$i]}"
    /sbin/ip tuntap add dev ${VIRTIFNAME[$i]} mode ${VIRTIFTYPE[$i]} user ${VIRTIFUSER[$i]} group ${VIRTIFGROUP[$i]}
  done
}

# Function to destroy virtual interfaces
virtif_destroy() {
  # argument is 'i' - the position of this interface in the VIRTIFNAME array.
  for i in $(seq 0 $((${#VIRTIFNAME[@]} - 1))); do
    info_log "${VIRTIFNAME[$i]}: destroying virtual interface"
    debug_log "/sbin/ip tuntap del dev ${VIRTIFNAME[$i]} mode ${VIRTIFTYPE[$i]}"
    /sbin/ip tuntap del dev ${VIRTIFNAME[$i]} mode ${VIRTIFTYPE[$i]}
  done
}

# Function to assemble a bridge interface.
br_open() {
  # argument is 'i' - the position of this interface in the IFNAME array.
  info_log "${IFNAME[$1]}: creating bridge"
  debug_log "/sbin/ip link add name ${IFNAME[$1]} type bridge"
  /sbin/ip link add name ${IFNAME[$1]} type bridge
  for BRIF in ${BRNICS[$1]}; do
    debug_log "/sbin/ip address flush dev $BRIF"
    /sbin/ip address flush dev $BRIF
    debug_log "/sbin/ip link set dev $BRIF master ${IFNAME[$1]}"
    /sbin/ip link set dev $BRIF master ${IFNAME[$1]}
    debug_log "/sbin/ip link set dev $BRIF up"
    /sbin/ip link set dev $BRIF up
  done
  while read -r -d \| IFOPT; do
    if [ -n "$IFOPT" ]; then
      debug_log "/sbin/ip link set dev ${IFNAME[$1]} type bridge $IFOPT"
      /sbin/ip link set dev ${IFNAME[$1]} type bridge $IFOPT
    fi
  done <<<"${IFOPTS[$1]/%|*([[:blank:]])}|"	# The | on the end is required.
  # Don't bring up the interface if it will be brought up later during IP configuration.
  # This prevents a situation where SLAAC takes a while to apply if the interface is already up.
  if [ -z "${IPADDRS[$1]}" ] && [ -z "${IP6ADDRS[$1]}" ] && [ -z "${IPADDR[$1]}" ] && [ "${USE_DHCP[$1]}" != "yes" ] && [ "${USE_DHCP6[$1]}" != "yes" ] && [ "${USE_SLAAC[$1]}" != "yes" ]; then
    debug_log "/sbin/ip link set dev ${IFNAME[$1]} up"
    /sbin/ip link set dev ${IFNAME[$1]} up
  fi
}

# Function to disassemble a bridge interface.
br_close() {
  # argument is 'i' - the position of this interface in the IFNAME array.
  info_log "${IFNAME[$1]}: destroying bridge"
  debug_log "/sbin/ip link set dev ${IFNAME[$1]} down"
  /sbin/ip link set dev ${IFNAME[$1]} down
  for BRIF in $(ls --indicator-style=none /sys/class/net/${IFNAME[$1]}/brif/)
  do
    debug_log "/sbin/ip link set dev $BRIF nomaster"
    /sbin/ip link set dev $BRIF nomaster
  done
  for BRIF in ${BRNICS[$1]}; do
    debug_log "/sbin/ip link set dev $BRIF down"
    /sbin/ip link set dev $BRIF down
  done
  debug_log "/sbin/ip link del ${IFNAME[$1]}"
  /sbin/ip link del ${IFNAME[$1]}
}

# Function to create a bond.
bond_create() {
  # Argument is 'i' - the position of this interface in the IFNAME array.
  info_log "${IFNAME[$1]}: creating bond"
  debug_log "/sbin/ip link add name ${IFNAME[$1]} type bond"
  /sbin/ip link add name ${IFNAME[$1]} type bond
  debug_log "/sbin/ip link set dev ${IFNAME[$1]} type bond mode ${BONDMODE[$1]:-balance-rr}"
  /sbin/ip link set dev ${IFNAME[$1]} type bond mode ${BONDMODE[$1]:-balance-rr}
  for BONDIF in ${BONDNICS[$1]}; do
    debug_log "/sbin/ip address flush dev $BONDIF"
    /sbin/ip address flush dev $BONDIF
    debug_log "/sbin/ip link set $BONDIF master ${IFNAME[$1]}"
    /sbin/ip link set $BONDIF master ${IFNAME[$1]}
    debug_log "/sbin/ip link set dev $BONDIF up"
    /sbin/ip link set dev $BONDIF up
  done
  # This has to be done *after* the interface is brought up because the
  # 'primary <interface>' option has to occur after the interface is active.
  while read -r -d \| IFOPT; do
    if [ -n "$IFOPT" ]; then
      debug_log "/sbin/ip link set dev ${IFNAME[$1]} type bond $IFOPT"
      /sbin/ip link set dev ${IFNAME[$1]} type bond $IFOPT
    fi
  done <<<"${IFOPTS[$1]/%|*([[:blank:]])}|"	# The | on the end is required.
}

# Function to destroy a bond.
bond_destroy() {
  # Argument is 'i' - the position of this interface in the IFNAME array.
  info_log "${IFNAME[$1]}: destroying bond"
  debug_log "/sbin/ip link set dev ${IFNAME[$1]} down"
  /sbin/ip link set dev ${IFNAME[$1]} down
  debug_log "/sbin/ip address flush dev ${IFNAME[$1]}"
  /sbin/ip address flush dev ${IFNAME[$1]}
  for BONDIF in ${BONDNICS[$1]}; do
    debug_log "/sbin/ip link set $BONDIF nomaster"
    /sbin/ip link set $BONDIF nomaster
    debug_log "/sbin/ip link set dev $BONDIF down"
    /sbin/ip link set dev $BONDIF down
  done
  debug_log "/sbin/ip link del name ${IFNAME[$1]} type bond"
  /sbin/ip link del name ${IFNAME[$1]} type bond
}

# Function to bring up a network interface.  If the interface is
# already up or does not yet exist (perhaps because the kernel driver
# is not loaded yet), do nothing.
if_up() {
  # Determine position 'i' of this interface in the IFNAME array:
  i=0
  while [ $i -lt $MAXNICS ]; do
    [ "${IFNAME[$i]}" = "${1}" ] && break
    i=$((i+1))
  done
  # If "i" is greater or equal to "MAXNICS" at this point, it means we didn't
  # find an entry in IFNAME array corresponding to "${1}", which likely means
  # there are more interfaces configured than MAXNICS. Let's err on the
  # side of caution and do nothing instead of possibly doing the wrong thing.
  if [ $i -ge $MAXNICS ]; then
    info_log "${1}: skipping - you might need to increase MAXNICS"
    return
  fi
  info_log "${1}: configuring interface"
  # If you need to set hardware addresses for the underlying interfaces in a
  # bond or bridge, configure the interfaces with IPs of 0.0.0.0 and set the
  # MAC address with HWADDR.  Then, finally, define the bond or bridge.
  # If the interface is a bond, create it.
  [ -n "${BONDNICS[$i]}" -a -z "$container" ] && bond_create $i
  # If the interface is a bridge, create it.
  [ -n "${BRNICS[$i]}" -a -z "$container" ] && br_open $i
  if [ -e /sys/class/net/${1%%[:.]*} ]; then # interface exists
    if ! /sbin/ip address show scope global dev ${1} 2>/dev/null | grep -Ewq '(inet|inet6)' || \
        ! /sbin/ip link show dev ${1} | grep -wq "state UP"; then # interface not up or not configured
      local IF_UP=0
      # Initialize any wireless parameters:
      if [ -x /etc/rc.d/rc.wireless ]; then
        . /etc/rc.d/rc.wireless ${1} start
      fi
      # Handle VLAN interfaces before trying to configure IP addresses.
      if echo "${1}" | grep -Fq .; then
        IFACE="${1%.*}"
        VLAN="${1##*.}"
        # Check if the underlying interface is already up.
        if ! /sbin/ip link show dev $IFACE 2>/dev/null| grep -wq "state UP"; then
          # Bring up the underlying interface.
          debug_log "/sbin/ip link set dev $IFACE up"
          if ! /sbin/ip link set dev $IFACE up; then
            info_log "${1}: failed to bring up interface $IFACE"
            return
          fi
          IF_UP=1
        fi
        # Configure the VLAN interface.
        info_log "${1}: creating VLAN interface"
        debug_log "/sbin/ip link add link $IFACE name ${1} type vlan id $VLAN"
        if ! /sbin/ip link add link $IFACE name ${1} type vlan id $VLAN; then
          info_log "${1}: failed to create VLAN interface"
          ((IF_UP == 1)) && /sbin/ip link set dev $IFACE down
          return
        fi
        while read -r -d \| IFOPT; do
          if [ -n "$IFOPT" ]; then
            debug_log "/sbin/ip link set dev ${1} type vlan $IFOPT"
            /sbin/ip link set dev ${1} type vlan $IFOPT
          fi
        done <<<"${IFOPTS[$i]/%|*([[:blank:]])}|"	# The | on the end is required.
      elif [ -z "${BONDNICS[$i]}" ] && [ -z "${BRNICS[$i]}" ]; then
        # Only apply IFOPTS for a physical interface if it's not been handled
        # by a higher level interface.
        while read -r -d \| IFOPT; do
          if [ -n "$IFOPT" ]; then
            debug_log "/sbin/ip link set dev ${1} $IFOPT"
            /sbin/ip link set dev ${1} $IFOPT
          fi
        done <<<"${IFOPTS[$i]/%|*([[:blank:]])}|"	# The | on the end is required.
      fi
      # Set hardware address:
      if [ -n "${HWADDR[$i]}" ]; then
        debug_log "/sbin/ip link set dev ${1} address ${HWADDR[$i]}"
        if ! /sbin/ip link set dev ${1} address ${HWADDR[$i]} 2>/dev/null; then
          info_log "${1}: failed to set hardware address"
        fi
      fi
      if [ -e /proc/sys/net/ipv6 ]; then # ipv6 networking is available
        # Disable v6 IP auto configuration before trying to bring up the interface:
        debug_log "${1}: disabling IPv6 autoconf"
        echo "0" >/proc/sys/net/ipv6/conf/${1}/autoconf
        if [ "${USE_RA[$i]}" = "yes" ]; then
          # Unconditionally accept router advertisements on this interface:
          debug_log "${1}: accepting IPv6 RA"
          echo "1" >/proc/sys/net/ipv6/conf/${1}/accept_ra
        else
          # Disable router advertisments on this interface until SLAAC is enabled:
          debug_log "${1}: ignoring IPv6 RA"
          echo "0" >/proc/sys/net/ipv6/conf/${1}/accept_ra
        fi
      fi
      debug_log "/sbin/ip address flush dev ${1}"
      /sbin/ip address flush dev ${1}
      IF_UP=0
      if [ -e /proc/sys/net/ipv6 ] && [ "${USE_DHCP6[$i]}" != "yes" ] && [ "${USE_SLAAC[$i]}" = "yes" ]; then # configure via SLAAC
        info_log "${1}: enabling SLAAC"
        # Enable accepting of RA packets, unless explicitly configured not to:
        if [ "${USE_RA[$i]}" = "no" ]; then
          debug_log "${1}: ignoring IPv6 RA"
          echo "0" >/proc/sys/net/ipv6/conf/${1}/accept_ra
        else
          debug_log "${1}: accepting IPv6 RA"
          echo "1" >/proc/sys/net/ipv6/conf/${1}/accept_ra
        fi
        # Set up SLAAC privacy enhancements if configured.
        if [ "${SLAAC_PRIVIPGEN[$i]}" = "yes" ]; then
          if [ -n "${SLAAC_SECRET[$i]}" ]; then
            debug_log "${1}: seeding secret and enabling private IPv6 generation"
            echo "${SLAAC_SECRET[$i]}" >/proc/sys/net/ipv6/conf/${1}/stable_secret
            echo "2" >/proc/sys/net/ipv6/conf/${1}/addr_gen_mode
          else
            debug_log "${1}: using random secret and enabling private IPv6 generation"
            echo -n >/proc/sys/net/ipv6/conf/${1}/stable_secret
            echo "3" >/proc/sys/net/ipv6/conf/${1}/addr_gen_mode
          fi
        fi
        if [ "${SLAAC_TEMPADDR[$i]}" = "yes" ]; then
          debug_log "${1}: enabling SLAAC tempaddr"
          echo "2" >/proc/sys/net/ipv6/conf/${1}/use_tempaddr
        fi
        # Enable auto configuration of interfaces:
        echo "1" >/proc/sys/net/ipv6/conf/${1}/autoconf
        # Bring the interface up:
        debug_log "/sbin/ip link set dev ${1} up"
        /sbin/ip link set dev ${1} up
        echo "${1}: waiting for router announcement"
        for ((j = ${SLAAC_TIMEOUT[$i]:=15} * 2; j--;)); do # by default, wait a max of 15 seconds for the interface to configure
          /sbin/ip -6 address show dynamic dev ${1} 2>/dev/null | grep -Ewq 'inet6' && { IF_UP=1; break; }
          sleep 0.5
        done
        if ((IF_UP != 1)); then
          echo "${1}: timed out"
          info_log "${1}: failed to auto configure after ${SLAAC_TIMEOUT[$i]} seconds"
          debug_log "/sbin/ip address flush dev ${1}"
          /sbin/ip address flush dev ${1}
          debug_log "/sbin/ip link set dev ${1} down"
          /sbin/ip link set dev ${1} down
        fi
      fi
      # Slackware historically favours dynamic configuration over fixed IP to configure interfaces, so keep that tradition:
      if [ "${USE_DHCP[$i]}" = "yes" ] || { [ -e /proc/sys/net/ipv6 ] && [ "${USE_DHCP6[$i]}" = "yes" ]; }; then # use dhcpcd
        info_log "${1}: starting dhcpcd"
        # Declare DHCP_OPTIONS array before adding new options to it:
        local -a DHCP_OPTIONS=()
        # Set DHCP_OPTIONS for this interface:
        if [ -e /proc/sys/net/ipv6 ]; then
          if [ "${USE_DHCP[$i]}" = "yes" ] && [ "${USE_DHCP6[$i]}" != "yes" ]; then # only try v4 dhcp
            DHCP_OPTIONS+=("-4")
          elif [ "${USE_DHCP[$i]}" != "yes" ] && [ "${USE_DHCP6[$i]}" = "yes" ]; then # only try v6 dhcp
            DHCP_OPTIONS+=("-6")
          fi
        else
          DHCP_OPTIONS+=("-4")
        fi
        [ -n "${DHCP_HOSTNAME[$i]}" ] && DHCP_OPTIONS+=("-h" "${DHCP_HOSTNAME[$i]}")
        [ "${DHCP_KEEPRESOLV[$i]}" = "yes" ] && DHCP_OPTIONS+=("-C" "resolv.conf")
        [ "${DHCP_KEEPNTP[$i]}" = "yes" ] && DHCP_OPTIONS+=("-C" "ntp.conf")
        [ "${DHCP_KEEPGW[$i]}" = "yes" ] && DHCP_OPTIONS+=("-G")
        [ -n "${DHCP_IPADDR[$i]}" ] && DHCP_OPTIONS+=("-r" "${DHCP_IPADDR[$i]}")
        [ "${DHCP_DEBUG[$i]}" = "yes" ] && DHCP_OPTIONS+=("-d")
        [ -n "${DHCP_OPTS[$i]}" ] && DHCP_OPTIONS+=(${DHCP_OPTS[$i]})
        # The -L option used to be hard coded into the dhcpcd command line in -current.  It was added to assist ARM users
        # get networking up and running.  Previous versions of Slackware did not have -L hard coded - the code here keeps
        # the 14.2 behaviour, but can be altered to make the use of -L default as in -current.  To change the behaviour,
        # alter the test below to be: [ "${DHCP_NOIPV4LL[$i]}" != "no" ].
        # Note: ARM users should make use of the DHCP_NOIPV4LL[x]="yes" parameter in rc.inet1.conf - this is the correct
        # way to get the behaviour they seek.
        [ "${DHCP_NOIPV4LL[$i]}" = "yes" ] && DHCP_OPTIONS+=("-L")
        echo "${1}: polling for DHCP server"
        # 15 seconds should be a reasonable default DHCP timeout.  30 was too much.
        debug_log "/sbin/dhcpcd -t ${DHCP_TIMEOUT[$i]:-15} ${DHCP_OPTIONS[*]} ${1}"
        if /sbin/dhcpcd -t "${DHCP_TIMEOUT[$i]:-15}" "${DHCP_OPTIONS[@]}" ${1}; then
          # Enable accepting of RA packets if explicitly told to:
          if [ -e /proc/sys/net/ipv6 ] && [ "${USE_RA[$i]}" = "yes" ]; then
            debug_log "${1}: unconditionally accepting IPv6 RA"
            echo "1" >/proc/sys/net/ipv6/conf/${1}/accept_ra
          fi
          IF_UP=1
        else
          info_log "${1}: failed to obtain DHCP lease"
          debug_log "/sbin/ip address flush dev ${1}"
          /sbin/ip address flush dev ${1}
          debug_log "/sbin/ip link set dev ${1} down"
          /sbin/ip link set dev ${1} down
        fi
      fi
      if [ -e /proc/sys/net/ipv6 ] && [ -n "${IP6ADDRS[$i]}" ]; then # add v6 IPs
        info_log "${1}: setting IPv6 addresses"
        # IPv6's Duplicate Address Detection (DAD) causes a race condition when bringing up interfaces, as
        # described here:  https://www.agwa.name/blog/post/beware_the_ipv6_dad_race_condition
        # Disable DAD while bringing up the interface - but note that this means the loss of detection of a
        # duplicate address.  It's a trade off, unfortunately.
        debug_log "${1}: disabling IPv6 DAD"
        echo "0" >/proc/sys/net/ipv6/conf/${1}/accept_dad
        for V6IP in ${IP6ADDRS[$i]}; do
          IP="${V6IP%/*}"
          PREFIX="${V6IP#*/}"
          if [ -z "$PREFIX" ] || [ "$IP" == "$PREFIX" ]; then
            info_log "${1}: no prefix length set for IP $IP - assuming 64"
            PREFIX="64"
          fi
          debug_log "/sbin/ip -6 address add $IP/$PREFIX dev ${1}"
          if /sbin/ip -6 address add $IP/$PREFIX dev ${1} && /sbin/ip link set dev ${1} up; then
            # Enable accepting of RA packets if explicitly told to.
            if [ "${USE_RA[$i]}" = "yes" ]; then
              debug_log "${1}: unconditionally accepting IPv6 RA"
              echo "1" >/proc/sys/net/ipv6/conf/${1}/accept_ra
            fi
            IF_UP=1
          else
            info_log "${1}: failed to set IP $IP"
            if ((IF_UP != 1)); then # a v4 address was configured, don't flush it
              debug_log "/sbin/ip address flush dev ${1}"
              /sbin/ip address flush dev ${1}
              debug_log "/sbin/ip link set dev ${1} down"
              /sbin/ip link set dev ${1} down
            fi
          fi
        done
        # Reset accept_dad back to default now all the IPs are configured:
        debug_log "${1}: resetting IPv6 DAD to default"
        cat /proc/sys/net/ipv6/conf/default/accept_dad >/proc/sys/net/ipv6/conf/${1}/accept_dad
      fi
      if [ -n "${IPADDRS[$i]}" ] || [ -n "${IPADDR[$i]}" ]; then # add v4 IPs
        info_log "${1}: setting IPv4 addresses"
        # Only use IPADDR if no dynamic configuration was done.
        if [ "${USE_DHCP[$i]}" == "yes" ] || [ "${USE_DHCP6[$i]}" == "yes" ] || [ "${USE_SLAAC[$i]}" == "yes" ]; then
          V4IPS="${IPADDRS[$i]}"
        else
          V4IPS="${IPADDRS[$i]} ${IPADDR[$i]}${NETMASK[$i]:+/${NETMASK[$i]}}"
        fi
        for V4IP in $V4IPS; do
          IP="${V4IP%/*}"
          NM="${V4IP#*/}"
          if [ -z "$NM" ] || [ "$IP" == "$NM" ]; then
            info_log "${1}: no netmask set for IP $IP - assuming 24 (aka, 255.255.255.0)"
            NM="24"
          fi
          debug_log "/sbin/ip -4 address add $IP/$NM broadcast + dev ${1}"
          if /sbin/ip -4 address add $IP/$NM broadcast + dev ${1} && /sbin/ip link set dev ${1} up; then
            IF_UP=1
          else
            info_log "${1}: failed to set IP $IP"
            if ((IF_UP != 1)); then # if at least one address was configured, don't flush the device
              debug_log "/sbin/ip address flush dev ${1}"
              /sbin/ip address flush dev ${1}
              debug_log "/sbin/ip link set dev ${1} down"
              /sbin/ip link set dev ${1} down
            fi
          fi
        done
      fi
      if ((IF_UP == 1)) && [ -n "${IPALIASES[$i]}" ]; then # Only apply IPALIASES onto an up interface
        info_log "${1}: setting extra IPv4 addresses"
        NUM=0
        for EXTRAIP in ${IPALIASES[$i]}; do
          IP="${EXTRAIP%/*}"
          NM="${EXTRAIP#*/}"
          if [ -z "$NM" ] || [ "$IP" == "$NM" ]; then
            info_log "${1}: no netmask set for alias IP $IP - assuming 24 (aka, 255.255.255.0)"
            NM="24"
          fi
          debug_log "/sbin/ip -4 address add $IP/$NM broadcast + dev ${1} label ${1}:$NUM"
          if /sbin/ip -4 address add $IP/$NM broadcast + dev ${1} label ${1}:$NUM; then
            NUM=$((NUM + 1))
          else
            info_log "${1}: failed to add alias IP $IP"
          fi
        done
      fi
      if ((IF_UP == 1)); then
        # Force an MTU (possibly overriding that set by DHCP or RA):
        if [ -n "${MTU[$i]}" ]; then
          info_log "${1}: setting custom MTU"
          debug_log "/sbin/ip link set dev ${1} mtu ${MTU[$i]}"
          if ! /sbin/ip link set dev ${1} mtu ${MTU[$i]}; then
            info_log "${1}: failed to set MTU"
          fi
        fi
        # Set promiscuous mode on the interface:
        if [ "${PROMISCUOUS[$i]}" = "yes" ]; then
          info_log "${1}: setting promiscuous mode"
          debug_log "/sbin/ip link set dev ${1} promisc on"
          if ! /sbin/ip link set dev ${1} promisc on; then
            info_log "${1}: failed to set promiscuous mode"
          fi
        fi
      fi
    else
      debug_log "${1}: skipping configuration - already up"
    fi
  else
    debug_log "${1}: skipping configuration - does not exist (yet)"
  fi
}

# Function to take down a network interface:
if_down() {
  # Determine position 'i' of this interface in the IFNAME array:
  i=0
  while [ $i -lt $MAXNICS ]; do
    [ "${IFNAME[$i]}" = "${1}" ] && break
    i=$((i+1))
  done
  if [ $i -ge $MAXNICS ]; then
    info_log "${1}: skipping - you might need to increase MAXNICS"
    return
  fi
  info_log "${1}: de-configuring interface"
  if [ -e /sys/class/net/${1} ]; then
    if [ "${USE_DHCP[$i]}" = "yes" ] || [ "${USE_DHCP6[$i]}" = "yes" ]; then # take down dhcpcd
      info_log "${1}: stopping dhcpcd"
      # When using -k, dhcpcd requires some command line options to match those used to invoke it:
      if [ "${USE_DHCP[$i]}" = "yes" ] && [ "${USE_DHCP6[$i]}" != "yes" ]; then # only v4 dhcp
        DHCP_OPTIONS=( -4 )
      elif [ "${USE_DHCP[$i]}" != "yes" ] && [ "${USE_DHCP6[$i]}" = "yes" ]; then # only v6 dhcp
        DHCP_OPTIONS=( -6 )
      fi
      debug_log "/sbin/dhcpcd ${DHCP_OPTIONS[*]} -k -d ${1}"
      /sbin/dhcpcd "${DHCP_OPTIONS[*]}" -k -d ${1} 2>/dev/null || info_log "${1}: failed to stop dhcpcd"
    fi
    # Disable v6 IP auto configuration and RA before trying to clear the IP from the interface:
    if [ -e /proc/sys/net/ipv6 ]; then
      debug_log "${1}: disabling IPv6 autoconf and RA"
      echo "0" >/proc/sys/net/ipv6/conf/${1}/autoconf
      echo "0" >/proc/sys/net/ipv6/conf/${1}/accept_ra
    fi
    sleep 0.5 # allow time for DHCP/RA to unconfigure the interface
    # Flush any remaining IPs:
    debug_log "/sbin/ip address flush dev ${1}"
    /sbin/ip address flush dev ${1}
    # Bring the interface down:
    debug_log "/sbin/ip link set dev ${1} down"
    /sbin/ip link set dev ${1} down
    # Reset everything back to defaults:
    if [ -e /proc/sys/net/ipv6 ]; then
      debug_log "${1}: resetting IPv6 configuration to defaults"
      cat /proc/sys/net/ipv6/conf/default/autoconf >/proc/sys/net/ipv6/conf/${1}/autoconf
      cat /proc/sys/net/ipv6/conf/default/accept_ra >/proc/sys/net/ipv6/conf/${1}/accept_ra
      cat /proc/sys/net/ipv6/conf/default/use_tempaddr >/proc/sys/net/ipv6/conf/${1}/use_tempaddr
      cat /proc/sys/net/ipv6/conf/default/addr_gen_mode >/proc/sys/net/ipv6/conf/${1}/addr_gen_mode
      echo -n >/proc/sys/net/ipv6/conf/${1}/stable_secret
    fi
    # If the interface is a bridge, then destroy it now:
    [ -n "${BRNICS[$i]}" ] && br_close $i
    # If the interface is a bond, then destroy it now.
    [ -n "${BONDNICS[$i]}" ] && bond_destroy $i
    # Take down VLAN interface, if configured.
    if echo "${1}" | grep -Fq .; then
      info_log "${1}: destroying VLAN interface"
      debug_log "/sbin/ip link set dev ${1} down"
      /sbin/ip link set dev ${1} down
      debug_log "/sbin/ip link delete ${1}"
      /sbin/ip link delete ${1}
      if ! /sbin/ip address show scope global dev ${1%.*} 2>/dev/null | grep -Ewq '(inet|inet6)'; then
        debug_log "/sbin/ip link set dev ${1%.*} down"
        /sbin/ip link set dev ${1%.*} down
      fi
    fi
    # Kill wireless daemons if any:
    if [ -x /etc/rc.d/rc.wireless ]; then
      . /etc/rc.d/rc.wireless ${1} stop
    fi
  fi
}

#####################
# GATEWAY FUNCTIONS #
#####################

# Function to bring up the gateway if there is not yet a default route:
gateway_up() {
  info_log "Configuring gateways"
  # Bring up the IPv4 gateway:
  if [ -n "$GATEWAY" ]; then
    if ! /sbin/ip -4 route show | grep -wq default; then
      debug_log "/sbin/ip -4 route add default via ${GATEWAY}"
      /sbin/ip -4 route add default via ${GATEWAY}
    fi
  fi
  # Bring up the IPv6 gateway:
  if [ -n "$GATEWAY6" ]; then
    if ! /sbin/ip -6 route show | grep -wq default; then
      debug_log "/sbin/ip -6 route add default via ${GATEWAY6}"
      /sbin/ip -6 route add default via ${GATEWAY6}
    fi
  fi
}

# Function to take down an existing default gateway:
gateway_down() {
  info_log "De-configuring gateways"
  if /sbin/ip -4 route show | grep -wq default ; then
    debug_log "/sbin/ip -4 route del default"
    /sbin/ip -4 route del default
  fi
  if /sbin/ip -6 route show | grep -wq default ; then
    debug_log "/sbin/ip -6 route del default"
    /sbin/ip -6 route del default
  fi
}

# Function to start the network:
start() {
  echo "Starting the network interfaces..."
  lo_up
  virtif_create
  for i in "${IFNAME[@]}" ; do
    if_up $i
  done
  gateway_up
}

# Function to stop the network:
stop() {
  echo "Stopping the network interfaces..."
  gateway_down
  for (( i = MAXNICS - 1; i >= 0; i-- )); do
    if_down ${IFNAME[$i]}
  done
  virtif_destroy
  lo_down
}


############
### MAIN ###
############

# extglob is required for some functionallity.
shopt -s extglob

case "${1}" in
start|up) # "start" (or "up") brings up all configured interfaces:
  start
  ;;
stop|down) # "stop" (or "down") takes down all configured interfaces:
  stop
  ;;
restart) # "restart" restarts the network:
  stop
  start
  ;;
lo_start|lo_up) # Start the loopback interface:
  lo_up
  ;;
lo_stop|lo_down) # Stop the loopback interface:
  lo_down
  ;;
*_start|*_up) # Example: "eth1_start" (or "eth1_up") will start the specified interface 'eth1'
  INTERFACE=$(echo ${1} | /bin/cut -d '_' -f 1)
  if_up $INTERFACE
  gateway_up
  ;;
*_stop|*_down) # Example: "eth0_stop" (or "eth0_down") will stop the specified interface 'eth0'
  INTERFACE=$(echo ${1} | /bin/cut -d '_' -f 1)
  if_down $INTERFACE
  ;;
*_restart) # Example: "wlan0_restart" will take 'wlan0' down and up again
  INTERFACE=$(echo ${1} | /bin/cut -d '_' -f 1)
  if_down $INTERFACE
  sleep 1
  if_up $INTERFACE
  gateway_up
  ;;
*) # The default is to bring up all configured interfaces:
  start
esac

# End of /etc/rc.d/rc.inet1
