#!/bin/sh
# 02-flash-boot.sh — scrive un boot image sullo slot INATTIVO, con il "protocollo forte"
# del progetto NX679J (Fase 2 / boot-flash-device.md) e i suoi gate:
#
#   G1  l'immagine ha la stessa dimensione della partizione (immagine di partizione intera)
#   G2  mai sullo slot da cui sta girando Android (la rete di sicurezza e' lo slot attivo)
#   G3  il contenuto ATTUALE della partizione combacia con il backup dichiarato
#       (--expect-current <sha256>, o il file del backup): il gate che sul NX679J ha
#       "fermato un flash su premesse sbagliate"
#   G4  l'immagine non e' identica a quella gia' scritta (niente flash inutili)
#   G5  dopo la scrittura: DUE letture fredde (drop_caches + iflag=direct, 3 s di distanza)
#       devono dare lo sha256 dell'immagine. Il primo v82 del NX679J "sembrava ok" ma era
#       la cache del block device.
#
# Funziona da Android (root Magisk) sullo slot attivo. Il riavvio NON e' automatico:
# usare poi 03-slot.sh per provare l'altro slot.
#
# Uso: ./02-flash-boot.sh <img> [--part boot_b] --expect-current <sha256|backup.img>
set -eu
IMG=""; PART=""; EXPECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --part) PART="$2"; shift ;;
    --expect-current) EXPECT="$2"; shift ;;
    -*) echo "opzione sconosciuta: $1"; exit 1 ;;
    *) IMG="$1" ;;
  esac; shift
done
[ -f "$IMG" ] || { echo "uso: $0 <img> [--part boot_b] --expect-current <sha256|backup.img>"; exit 1; }
[ -n "$EXPECT" ] || { echo "G3: manca --expect-current (sha256 o file di backup della partizione)"; exit 1; }
[ -f "$EXPECT" ] && EXPECT=$(sha256sum "$EXPECT" | cut -d' ' -f1)

SU() { adb shell su -c "$1" | tr -d '\r'; }
SLOT=$(SU 'getprop ro.boot.slot_suffix')
[ -n "$SLOT" ] || { echo "slot attivo sconosciuto: device non A/B?"; exit 1; }
if [ -z "$PART" ]; then
  case "$SLOT" in _a) PART=boot_b ;; _b) PART=boot_a ;; *) echo "slot $SLOT?"; exit 1 ;; esac
fi
case "$PART" in
  boot_a|boot_b) ;;
  *) echo "G0 FAIL: solo boot_a/boot_b (mai nvram/protect/lk/preloader/vbmeta)"; exit 1 ;;
esac
case "$PART" in
  *"$SLOT") echo "G2 FAIL: $PART e' lo slot attivo ($SLOT): rifiuto"; exit 1 ;;
esac
DEV=/dev/block/by-name/$PART
N=$(wc -c < "$IMG")
PSZ=$(SU "blockdev --getsize64 $DEV")
echo "partizione $PART ($DEV) = $PSZ B, immagine = $N B, slot attivo $SLOT"
[ "$N" = "$PSZ" ] || { echo "G1 FAIL: dimensioni diverse"; exit 1; }

H_IMG=$(sha256sum "$IMG" | cut -d' ' -f1)
H_CUR=$(SU "sha256sum $DEV" | cut -d' ' -f1)
[ "$H_CUR" = "$EXPECT" ] || { echo "G3 FAIL: contenuto attuale $H_CUR != atteso $EXPECT"; exit 1; }
[ "$H_CUR" != "$H_IMG" ] || { echo "G4: l'immagine e' gia' scritta, niente da fare"; exit 0; }
echo "BACKUP_MATCHES_$PART OK"

adb push "$IMG" /data/local/tmp/flash.img >/dev/null
H_REM=$(SU 'sha256sum /data/local/tmp/flash.img' | cut -d' ' -f1)
[ "$H_REM" = "$H_IMG" ] || { echo "REMOTE_IMAGE FAIL: push corrotto"; exit 1; }
echo "REMOTE_IMAGE_SHA256=$H_IMG OK"

BB=/data/adb/magisk/busybox   # dd di busybox: supporta oflag/iflag=direct (toybox no)
SU "$BB dd if=/data/local/tmp/flash.img of=$DEV bs=4M oflag=direct conv=fsync 2>&1; sync"
cold() { SU "sync; echo 3 > /proc/sys/vm/drop_caches; $BB dd if=$DEV bs=4M iflag=direct 2>/dev/null | sha256sum" | cut -d' ' -f1; }
R1=$(cold); sleep 3; R2=$(cold)
echo "lettura fredda 1: $R1"; echo "lettura fredda 2: $R2"
SU 'rm -f /data/local/tmp/flash.img'
if [ "$R1" = "$H_IMG" ] && [ "$R2" = "$H_IMG" ]; then
  echo "WRITE_GATE_PASS $PART = $H_IMG"
  echo "prossimo passo: ./03-slot.sh ${PART#boot_}"
else
  echo "WRITE_GATE_FAIL: NON cambiare slot. Riscrivi il backup con: $0 <backup> --part $PART --expect-current $R2"
  exit 1
fi
