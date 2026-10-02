#!/bin/bash
# SPDX-License-Identifier: MIT
# Starts the part of the Open5GS 5GC that does not need root: mongod, NRF, SCP, AMF, AUSF, UDM, UDR, PCF, NSSF, BSF, SMF.
# The UPF (root, utun) is started separately, in its own terminal:
#   sudo "$PREFIX/bin/open5gs-upfd" -c "$CONFDIR/open5gs-5gc/upf.yaml"
# Idempotent: NFs that already run are skipped. The yaml files and lo0-aliases-5gc.sh are the 5gc set of the
# open5gs-macos-arm64 kit, rendered into $CONFDIR/open5gs-5gc. mongod and mongosh must be in PATH.
#
# Environment, all required:
#   PREFIX   install prefix of Open5GS (holds bin/open5gs-*d)
#   CONFDIR  directory that holds open5gs-5gc/*.yaml
#   LOGDIR   where the NF logs go
#   MONGODB  mongod data directory
#
# Example:
#   PREFIX="$HOME/ocudu-lab/local" CONFDIR="$HOME/ocudu-lab/config" LOGDIR="$HOME/ocudu-lab/logs" \
#   MONGODB="$HOME/ocudu-lab/mongodb" config/start-5gc-user.sh
set -u
PREFIX="${PREFIX:?set PREFIX to the Open5GS install prefix}"
CONFDIR="${CONFDIR:?set CONFDIR to the directory that holds open5gs-5gc/}"
LOGDIR="${LOGDIR:?set LOGDIR to the log directory}"
MONGODB="${MONGODB:?set MONGODB to the mongod data directory}"
CFG="$CONFDIR/open5gs-5gc"; BIN="$PREFIX/bin"
[ "$(ifconfig lo0 | grep -c 'inet 127.0.0.4 ')" = 1 ] || { echo "[error] lo0 aliases missing: sudo $CFG/lo0-aliases-5gc.sh"; exit 1; }
if ! pgrep -x mongod >/dev/null; then
  nohup mongod --dbpath "$MONGODB" --logpath "$LOGDIR/open5gs-mongod.log" --logappend --bind_ip 127.0.0.1 --port 27017 >/dev/null 2>&1 &
  for i in $(seq 1 20); do mongosh --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null | grep -q 1 && break; sleep 0.5; done
  echo "[ok] mongod"
fi
start_nf() { local nf="$1"; if pgrep -x "open5gs-${nf}d" >/dev/null; then echo "[skip] $nf already running"; return; fi
  nohup "$BIN/open5gs-${nf}d" -c "$CFG/${nf}.yaml" > "$LOGDIR/open5gs-5gc-${nf}.log" 2>&1 &
  echo "[start] $nf pid $!"; }
start_nf nrf; sleep 2; start_nf scp; sleep 1
for nf in amf ausf udm udr pcf nssf bsf smf; do start_nf "$nf"; sleep 0.5; done
sleep 4
echo "=== NRF registrations ==="; grep -c "NF registered" "$LOGDIR/open5gs-5gc-nrf.log" 2>/dev/null
echo "=== AMF NGAP ==="; grep -m2 "ngap_server\|NGAP" "$LOGDIR/open5gs-5gc-amf.log" 2>/dev/null | cut -c1-160
echo "=== UDP 9899 (AMF usrsctp) ==="; netstat -anv -p udp 2>/dev/null | grep -E "\.9899 " | head -3
echo "=== processes ==="; pgrep -lf "open5gs-|mongod" | awk '{print $2}' | sort | tr '\n' ' '; echo
