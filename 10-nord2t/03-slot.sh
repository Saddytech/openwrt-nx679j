#!/bin/sh
# 03-slot.sh — passa da uno slot all'altro senza azioni fisiche (torna-b.sh del NX679J,
# con polling al posto degli sleep fissi).
#
#   da Android:   adb reboot bootloader -> fastboot --set-active=<x> -> fastboot reboot
#   da OpenWrt:   ssh ... 'reboot2 bootloader' (LINUX_REBOOT_CMD_RESTART2 "bootloader",
#                 02-sorgenti/wifi-luci/reboot-bootloader.c) -> stessi passi fastboot
#
# Se l'avvio sullo slot nuovo fallisce: tieni POWER ~15 s, poi POWER+VOL- per il
# bootloader, e './03-slot.sh a --from-fastboot' riporta su Android.
# [DA VERIFICARE sul Nord 2T] combinazione tasti del fastboot e comportamento del
# bootloader dopo N avvii falliti (retry-count / unbootable).
#
# Uso: ./03-slot.sh a|b [--from-fastboot] [--ssh root@10.0.0.1]
set -eu
T=${1:-}; shift || true
case "$T" in a|b) ;; *) echo "uso: $0 a|b [--from-fastboot] [--ssh host]"; exit 1 ;; esac
FROM=adb; SSHH=""
while [ $# -gt 0 ]; do
  case "$1" in --from-fastboot) FROM=fb ;; --ssh) FROM=ssh; SSHH="$2"; shift ;; esac; shift
done
wait_for() { i=0; until eval "$1" >/dev/null 2>&1; do i=$((i+1)); [ $i -gt "$2" ] && return 1; sleep 2; done; }

case $FROM in
  adb) adb reboot bootloader ;;
  ssh) ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$SSHH" 'reboot2 bootloader' || true ;;
esac
wait_for 'fastboot devices | grep -q .' 60 || { echo "fastboot non visto in 120 s"; exit 1; }
fastboot getvar current-slot 2>&1 | grep -i slot
fastboot getvar unlocked 2>&1 | grep -i unlocked
for v in slot-successful slot-unbootable slot-retry-count; do fastboot getvar "$v:$T" 2>&1 | grep -i "$v"; done
fastboot --set-active="$T"
fastboot getvar current-slot 2>&1 | grep -i "current-slot: *$T" || { echo "set-active non applicato"; exit 1; }
fastboot reboot
echo "slot $T attivo, riavvio in corso"
if [ "$T" = a ]; then
  wait_for 'adb get-state | grep -q device' 90 && echo "Android su slot a: OK" || echo "adb non tornato in 180 s"
else
  echo "attendo il gadget USB (NCM/RNDIS) o adb..."
  wait_for 'ping -c1 -W1 10.0.0.1' 150 && echo "10.0.0.1 risponde" || echo "nessuna risposta in 300 s: vedi LEGGIMI, 'Se non parte'"
fi
