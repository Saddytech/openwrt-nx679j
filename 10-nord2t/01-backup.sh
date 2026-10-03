#!/bin/sh
# 01-backup.sh — copia di TUTTE le partizioni del Nord 2T sul PC, con verifica hash.
#
# Sul NX679J l'EDL era rotto e lo slot A era l'unica rete di sicurezza; sul Nord 2T
# il recupero BROM (mtkclient) e' incerto per via dell'autenticazione OnePlus/Oppo:
# va trattato allo stesso modo. Questo backup si fa UNA volta, PRIMA di qualunque
# scrittura, e si conserva fuori dal PC (le calibrazioni non si ricreano).
#
# Partizioni da NON perdere mai su MediaTek (equivalenti dell'EFS Qualcomm):
#   nvram, nvdata, nvcfg, protect1, protect2, proinfo, persist  -> IMEI, calibrazioni RF,
#   MAC Wi-Fi/BT. Senza di loro il modem non si registra piu'.
#
# Streaming con 'adb exec-out' (nessun file temporaneo sul telefono), poi sha256
# calcolato sul telefono e sul PC: devono coincidere, altrimenti la copia e' scartata.
#
# Uso: ./01-backup.sh [--with-super] [--only "boot_a boot_b nvram"]
set -eu
OUT=${OUT:-backup-$(date +%Y%m%d-%H%M%S)}
WITH_SUPER=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --with-super) WITH_SUPER=1 ;;
    --only) ONLY="$2"; shift ;;
    *) echo "opzione sconosciuta: $1"; exit 1 ;;
  esac; shift
done
mkdir -p "$OUT"
adb shell su -c id 2>/dev/null | grep -q 'uid=0' || { echo "serve root (Magisk)"; exit 1; }

LIST=$(adb shell su -c 'ls /dev/block/by-name/' | tr -d '\r')
[ -n "$ONLY" ] && LIST="$ONLY"
FAIL=0
: > "$OUT/SHA256SUMS"
for p in $LIST; do
  case "$p" in
    userdata|metadata) echo "salto $p (dati utente/cifrati)"; continue ;;
    super) [ $WITH_SUPER = 1 ] || { echo "salto super (usa --with-super, ~10 GB; ricostruibile dall'OTA)"; continue; } ;;
  esac
  printf '%-20s ' "$p"
  adb exec-out su -c "dd if=/dev/block/by-name/$p bs=4M 2>/dev/null" > "$OUT/$p.img"
  H_PC=$(sha256sum "$OUT/$p.img" | cut -d' ' -f1)
  H_DEV=$(adb shell su -c "sha256sum /dev/block/by-name/$p" | tr -d '\r' | cut -d' ' -f1)
  SZ=$(wc -c < "$OUT/$p.img")
  if [ "$H_PC" = "$H_DEV" ] && [ "$SZ" -gt 0 ]; then
    echo "$H_PC  $p.img" >> "$OUT/SHA256SUMS"; echo "OK  $SZ B  ${H_PC%${H_PC#????????????????}}"
  else
    echo "DIVERSO pc=$H_PC dev=$H_DEV size=$SZ"; FAIL=1
  fi
done
adb shell getprop > "$OUT/getprop.txt"
adb shell su -c 'ls -l /dev/block/by-name/' > "$OUT/by-name.txt"
if [ $FAIL = 0 ]; then
  echo "BACKUP_PASS -> $OUT (copialo anche su un altro disco)"
else
  echo "BACKUP_FAIL: ripeti le partizioni DIVERSO con --only \"...\" prima di andare avanti"; exit 1
fi
