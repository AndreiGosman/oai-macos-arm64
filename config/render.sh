#!/bin/sh
# SPDX-License-Identifier: MIT
# Copy the OAI 5G SA config set into the layout run-5gsa-oai-root.sh expects under CONFDIR:
#   <OUTDIR>/oai-5gsa/gnb.conf and <OUTDIR>/oai-5gsa/ue.conf
# The two files carry no placeholder (no host path is inside them); this script keeps the same step and layout
# as the companion kits, whose config sets do carry placeholders. The 5GC set is rendered by the open5gs kit's
# own render.sh into <OUTDIR>/open5gs-5gc.
#
# Usage: config/render.sh <OUTDIR>
set -eu
[ $# -eq 1 ] || { sed -n '2,8p' "$0"; exit 1; }
out="$1"
src="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$out/oai-5gsa"
cp "$src/gnb.conf" "$src/ue.conf" "$out/oai-5gsa/"
echo "copied gnb.conf and ue.conf into $out/oai-5gsa"
grep -l "@[A-Z]*@" "$out"/oai-5gsa/gnb.conf "$out"/oai-5gsa/ue.conf 2>/dev/null && { echo "placeholders left, check the files above"; exit 1; } || true
