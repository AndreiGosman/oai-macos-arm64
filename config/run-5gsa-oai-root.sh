#!/bin/bash
# SPDX-License-Identifier: MIT
# 5G SA: OAI nrUE through the OAI gNB (RF simulator) against an Open5GS 5GC, then crossed host routes and a
# bidirectional ping on 10.45.0.0/16, all on one macOS host. Run with sudo: root is needed for the nrUE utun and for
# the routes. The gNB does not need root and runs as $SUDO_USER, through the SCTP shim on UDP 9900 towards the AMF on
# 9899 (NGAP on the real 127.0.0.1).
#
# Preconditions: 5GC up (start-5gc-user.sh as user, plus the UPF as root in its own terminal:
#   sudo "$PREFIX/bin/open5gs-upfd" -c "$CONFDIR/open5gs-5gc/upf.yaml"
# ), the UPF utun carrying 10.45.0.1, the configs copied with config/render.sh into $CONFDIR, and the OAI build
# directory holding nr-softmodem, nr-uesoftmodem and the modules (params_libconfig, rfsimulator, ldpc, dfts).
#
# Environment, all required:
#   PREFIX     install prefix of Open5GS (holds bin/open5gs-upfd), only checked here
#   CONFDIR    directory with oai-5gsa/gnb.conf and oai-5gsa/ue.conf
#   LOGDIR     where the gNB and UE logs go
#   BUILD      the OAI build directory (nr-softmodem, nr-uesoftmodem and the .so modules live there)
#   SUDO_USER  the user that runs the gNB; sudo sets it
#
# Example:
#   sudo PREFIX="$HOME/oai-lab/local" CONFDIR="$HOME/oai-lab/config" LOGDIR="$HOME/oai-lab/logs" \
#        BUILD="$HOME/oai-lab/openairinterface5g/build" config/run-5gsa-oai-root.sh

set -u
PREFIX="${PREFIX:?set PREFIX to the Open5GS install prefix}"
CONFDIR="${CONFDIR:?set CONFDIR to the directory with oai-5gsa/gnb.conf and ue.conf}"
LOGS="${LOGDIR:?set LOGDIR to the log directory}"
BUILD="${BUILD:?set BUILD to the OAI build directory}"
CFG="$CONFDIR/oai-5gsa"
SESSION="5gsa-oai"
GW="10.45.0.1"

[ "$(id -u)" = 0 ] || { echo "Run with sudo: sudo $0"; exit 1; }
command -v tmux >/dev/null || { echo "tmux is missing"; exit 1; }
pgrep -x open5gs-upfd >/dev/null || { echo "[error] open5gs-upfd is not running (sudo $PREFIX/bin/open5gs-upfd -c $CONFDIR/open5gs-5gc/upf.yaml)"; exit 1; }
pgrep -x open5gs-amfd >/dev/null || { echo "[error] open5gs-amfd is not running (start-5gc-user.sh)"; exit 1; }
[ -x "$BUILD/nr-softmodem" ] && [ -x "$BUILD/nr-uesoftmodem" ] || { echo "[error] nr-softmodem or nr-uesoftmodem missing in $BUILD"; exit 1; }
RUNAS="${SUDO_USER:?run through sudo so that SUDO_USER names the user that runs the gNB}"

# The RF simulator is a TCP server inside the gNB (port 4043). Stop a leftover nrUE first, then restart the gNB as the
# user, not as root. SIGINT, never SIGKILL.
if pgrep -x nr-uesoftmodem >/dev/null; then echo "[clean] stopping leftover nr-uesoftmodem"; pkill -INT -x nr-uesoftmodem; for i in 1 2 3 4 5 6; do sleep 1; pgrep -x nr-uesoftmodem >/dev/null || break; done; fi
tmux kill-session -t "$SESSION" 2>/dev/null
if pgrep -x nr-softmodem >/dev/null; then echo "[clean] stopping nr-softmodem"; pkill -INT -x nr-softmodem; for i in $(seq 1 10); do sleep 1; pgrep -x nr-softmodem >/dev/null || break; done; pkill -x nr-softmodem 2>/dev/null; fi
rm -f "$LOGS/oai-5gsa-gnb.log"
cd "$BUILD" || exit 1
sudo -u "$RUNAS" env LIBSCTP_COMPAT_UDP_ENCAPS_PORT=9900 LIBSCTP_COMPAT_UDP_ENCAPS_REMOTE_PORT=9899 \
  nohup ./nr-softmodem -O "$CFG/gnb.conf" --rfsim > "$LOGS/oai-5gsa-gnb.log" 2>&1 &
for i in $(seq 1 40); do grep -q "Received NGSetupResponse" "$LOGS/oai-5gsa-gnb.log" 2>/dev/null && grep -q "void samples" "$LOGS/oai-5gsa-gnb.log" && break; sleep 1; done
grep -q "Received NGSetupResponse" "$LOGS/oai-5gsa-gnb.log" || { echo "[error] gNB without NG Setup within 40 s"; tail -8 "$LOGS/oai-5gsa-gnb.log"; exit 1; }
echo "[ok]     OAI gNB started as $RUNAS, NG Setup completed, RF simulator on 4043"
UPF_IF=$(ifconfig | awk '/^utun/{i=$1} /inet 10\.45\.0\.1 /{sub(":","",i); print i; exit}')
[ -n "$UPF_IF" ] || { echo "[error] no utun with $GW"; exit 1; }
echo "[info]   UPF utun: $UPF_IF"

wait_for() {
  local file="$1" pattern="$2" timeout="$3" label="$4" i=0
  echo "[wait]   $label"
  while [ $i -lt "$timeout" ]; do
    if [ -f "$file" ] && grep -qE -- "$pattern" "$file" 2>/dev/null; then echo "[ok]     $label"; return 0; fi
    sleep 1; i=$((i + 1))
  done
  echo "[fail]   $label did not appear within ${timeout} s"; tail -15 "$file" 2>/dev/null | sed 's/^/         /'; return 1
}

# The nrUE as root: it opens the utun at PDU Session Establishment Accept and puts the UE address on it.
rm -f "$LOGS/oai-5gsa-ue.log"
tmux new-session -d -s "$SESSION" -n ue "cd $BUILD && ./nr-uesoftmodem -O $CFG/ue.conf --rfsim '--rfsimulator.[0].serveraddr' 127.0.0.1 -r 106 --numerology 1 --band 78 -C 3619200000 2>&1 | tee -a $LOGS/oai-5gsa-ue.log; read"
wait_for "$LOGS/oai-5gsa-ue.log" "Received PDU Session Establishment Accept" 120 "UE 5G SA: registration + PDU session" || {
  echo; echo "Attach failed. tmux attach -t $SESSION; log: $LOGS/oai-5gsa-ue.log"; exit 1; }

sleep 2
UE_IF=$(grep -oE 'the kernel assigned utun[0-9]+' "$LOGS/oai-5gsa-ue.log" | tail -1 | awk '{print $4}')
UE_IP=$(grep -oE 'Accept, UE IPv4: [0-9.]+' "$LOGS/oai-5gsa-ue.log" | tail -1 | awk '{print $4}')
echo "=============================================================="
echo "Attach succeeded. UE IP: ${UE_IP:-unknown}   UE utun: ${UE_IF:-unknown}   UPF utun: $UPF_IF"
[ -n "$UE_IF" ] && [ -n "$UE_IP" ] || { echo "[error] UE utun or IP missing in the log"; exit 1; }

# Both addresses are local to this host. Without crossed host routes the kernel answers over loopback. The UPF utun
# gets the UE address as its point-to-point destination (XNU binds a host route for 10.45.0.1 to the utun that owns
# it otherwise, and the ping reports "No route to host"), the /16 route added by the UPF is removed and two host
# routes send each address through the other utun, so the packets travel nrUE, RF simulator, gNB, GTP-U, UPF and back.
ifconfig "$UPF_IF" inet "$GW" "$UE_IP" netmask 255.255.255.255 && echo "[p2p]    $UPF_IF dst $UE_IP"
route -q -n delete -net 10.45.0.0/16 >/dev/null 2>&1
route -q -n delete -host "$GW" >/dev/null 2>&1
route -q -n delete -host "$UE_IP" >/dev/null 2>&1
route -n add -host "$GW" -interface "$UE_IF" >/dev/null && echo "[route]  $GW via $UE_IF"
route -n add -host "$UE_IP" -interface "$UPF_IF" >/dev/null && echo "[route]  $UE_IP via $UPF_IF"
for d in "$GW" "$UE_IP"; do printf "[get]    %s: " "$d"; route -n get "$d" 2>&1 | awk '/interface|flags/{printf "%s ", $2}'; echo; done
echo; echo "10.45 routes:"; netstat -rn -f inet | grep -E "^10\.45" | sed 's/^/  /'
echo; echo "Ping UE -> GW ($UE_IP -> $GW):"; ping -c 4 -S "$UE_IP" "$GW" | tee -a "$LOGS/oai-5gsa-ping.log" | tail -3 | sed 's/^/  /'
echo; echo "Ping GW -> UE ($GW -> $UE_IP):"; ping -c 4 -S "$GW" "$UE_IP" | tee -a "$LOGS/oai-5gsa-ping.log" | tail -3 | sed 's/^/  /'
echo; echo "tmux session: tmux attach -t $SESSION    Stop the UE: tmux send-keys -t $SESSION C-c"
echo "=============================================================="
