#!/bin/zsh
# Three tenants on one card at once: chat on the 12 GB slice, a second chat on the 8 GB slice, embeddings on the 4 GB
# slice. PAR requests per chat endpoint, 4 embedding workers for the duration of the chat runs (about 40 s), plus the
# host view from vgpu-host.sh MODE=watch over SSH.
# Env: PAIS_GW, PAIS_TOKEN or PAIS_TOKEN_FILE (passed on to the Python scripts), ESX_HOST (ssh target), HOST_SCRIPT
# (path of vgpu-host.sh on the host datastore), GPU (PCI address, for the watch), A/B/E (route names), PAR, OUT (dir).
# Run from the scripts folder: ESX_HOST=<esx-host> HOST_SCRIPT=/vmfs/volumes/<datastore>/nvaie/vgpu-host.sh GPU=0000:XX:00.0 zsh mixed-bench.sh
set -u
OUT=${OUT:-/tmp}; PAR=${PAR:-4}; A=${A:-gemma-4-12b-vgpu12c}; B=${B:-gemma-4-12b-vgpu8c}; E=${E:-bge-m3-vgpu4c}
ESX_HOST=${ESX_HOST:?set ESX_HOST}; HOST_SCRIPT=${HOST_SCRIPT:?set HOST_SCRIPT=/vmfs/volumes/<datastore>/nvaie/vgpu-host.sh}; GPU=${GPU:?set GPU}
cd "$(dirname "$0")"
echo "## mixed run $(date +%T): $A + $B (PAR=$PAR each) + $E (4 workers, 40 s)"
ssh $ESX_HOST "GPU=$GPU PKGDIR=$(dirname $HOST_SCRIPT) WATCH=90 MODE=watch sh $HOST_SCRIPT" > $OUT/mixed-host.log 2>&1 &
sleep 5
PAR=$PAR python3 -I gw-bench.py $A > $OUT/mixed-a.txt 2>&1 &
PAR=$PAR python3 -I gw-bench.py $B > $OUT/mixed-b.txt 2>&1 &
PAR=4 DUR=40 python3 -I emb-bench.py $E > $OUT/mixed-e.txt 2>&1 &
wait
for f in a b e; do echo "--- $f"; grep -E "^===|streaming|parallel|route|requests" $OUT/mixed-$f.txt | cut -c1-200; done
echo "--- host peaks:"; grep -E "^[0-9]+ %" $OUT/mixed-host.log | sort -t, -k3 -rn | head -3
