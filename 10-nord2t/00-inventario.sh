#!/bin/sh
# 00-inventario.sh — Fase 0 sul OnePlus Nord 2T: SOLA LETTURA.
#
# Equivalente MediaTek di phase0-inventory.sh / capture-baseline.sh del NX679J:
# raccoglie da Android (slot attivo, root Magisk) tutto cio' che serve per decidere
# il port PRIMA di scrivere qualunque cosa sul telefono. Non scrive partizioni,
# non carica moduli, non tocca nodi di debug pericolosi.
#
# Uso (host, telefono acceso su Android con debug USB e root):
#   ./00-inventario.sh                 # -> inventario-<data>/
#   ./00-inventario.sh --fastboot      # in piu': fastboot getvar all (riavvia nel bootloader!)
set -eu
OUT=${OUT:-inventario-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
adb get-state >/dev/null 2>&1 || { echo "nessun device adb: abilita debug USB e autorizza il PC"; exit 1; }
adb shell su -c id 2>/dev/null | grep -q 'uid=0' || { echo "root assente: serve Magisk sullo slot attivo (vedi LEGGIMI.md, Fase 1)"; exit 1; }

# --- script lato telefono: ogni sezione e' indipendente, un errore non ferma le altre
cat > "$OUT/.probe.sh" <<'EOF'
s() { echo; echo "=== SECTION.$1 ==="; }
s identity;    getprop | grep -E 'ro\.(product|board|hardware|boot|build\.(version|display|fingerprint)|vendor\.build\.fingerprint|soc|mediatek|oplus)|ro\.boot\.(slot|verifiedbootstate|vbmeta|flash|hardware)'
s uname;       uname -a; cat /proc/version
s cmdline;     cat /proc/cmdline; echo; cat /proc/bootconfig 2>/dev/null
s cpu;         cat /proc/cpuinfo | grep -E 'Hardware|processor|CPU part' | sort | uniq -c; head -3 /proc/meminfo
s dt-model;    cat /proc/device-tree/model 2>/dev/null; echo; tr '\0' '\n' < /proc/device-tree/compatible 2>/dev/null
s selinux;     getenforce
s slot;        getprop ro.boot.slot_suffix; bootctl get-current-slot 2>/dev/null; bootctl get-suffix 0 2>/dev/null
s partitions-byname; ls -l /dev/block/by-name/ 2>/dev/null || ls -l /dev/block/platform/*/by-name/
s partitions-sizes
for p in /dev/block/by-name/*; do
  n=${p##*/}; d=$(readlink -f "$p"); b=${d##*/}
  sz=$(cat /sys/class/block/$b/size 2>/dev/null); echo "$n $d sectors=$sz bytes=$((${sz:-0}*512))"
done
s proc-partitions; cat /proc/partitions
s mounts;      cat /proc/mounts
s dynamic;     ls -l /dev/block/mapper/ 2>/dev/null
s boot-headers
for p in boot_a boot_b vendor_boot_a vendor_boot_b init_boot_a init_boot_b dtbo_a vbmeta_a; do
  [ -e /dev/block/by-name/$p ] || { echo "$p: ASSENTE"; continue; }
  echo "$p: magic=$(dd if=/dev/block/by-name/$p bs=8 count=1 2>/dev/null | tr -cd '[:print:]') sha256(4KiB)=$(dd if=/dev/block/by-name/$p bs=4096 count=1 2>/dev/null | sha256sum | cut -c1-16)"
done
s kernel-config; [ -e /proc/config.gz ] && echo "presente (estratto in kernel.config)" || echo "ASSENTE: CONFIG_IKCONFIG off"
s modules-loaded; cat /proc/modules
s modules-vendor; for d in /vendor/lib/modules /vendor_dlkm/lib/modules /lib/modules /odm/lib/modules; do [ -d $d ] && { echo "-- $d"; ls $d; }; done
s modules-load-lists; for f in /vendor/lib/modules/modules.load* /vendor_dlkm/lib/modules/modules.load*; do [ -f $f ] && { echo "-- $f"; cat $f; }; done
s init-insmod; grep -rhE 'insmod|modprobe|wmt|ccci|conninfra|connfem|wlan' /vendor/etc/init/ /vendor/etc/init/hw/ /system/etc/init/ 2>/dev/null | sort -u | head -200
s vendor-services; grep -rhE '^service ' /vendor/etc/init/ /odm/etc/init/ 2>/dev/null | sort -u
# --- modem MediaTek (CCCI): e' il blocco piu' difficile, qui si raccoglie TUTTO
s modem-procs; ps -A -o PID,NAME,ARGS 2>/dev/null | grep -iE 'ccci|md_|mdinit|fsd|nvram|rild|mtkfusion|atci|terservice|gsm0710|mipc|mtkrild|em_svr|mdlogger|epdg|ims' | grep -v grep
s modem-dev;   ls -l /dev | grep -iE 'ccci|ttyC|radio|emd|eemcs|md[0-9]|mipc|ccmni'; ls -l /dev/radio 2>/dev/null
s modem-net;   ip -br link | grep -iE 'ccmni|ccemni|rmnet|clat|v4-'; ip -br addr | grep -iE 'ccmni'
s modem-sysfs; ls /sys/kernel/ccci 2>/dev/null; for f in /sys/kernel/ccci/*; do [ -f "$f" ] && echo "$f: $(head -c 300 $f 2>/dev/null)"; done
s modem-fw;    ls -l /vendor/firmware 2>/dev/null | grep -iE 'md|modem|dsp'; ls -l /dev/block/by-name/ | grep -iE 'md1|md_|nvram|nvdata|nvcfg|protect|proinfo|persist|seccfg|para|misc'
s modem-props; getprop | grep -iE 'ril|ccci|md|telephony|radio|persist\.vendor\.(radio|mtk)|vendor\.gsm|gsm\.' | head -150
s dmesg-modem; dmesg 2>/dev/null | grep -iE 'ccci|ccmni|md1|modem|cldma|dpmaif|mdinit' | tail -150
# --- Wi-Fi / connettivita' MediaTek (conninfra / wmt / gen4m)
s wifi-dev;    ls -l /dev | grep -iE 'wmt|stpwmt|conninfra|fm|bt|wifi|gps'
s wifi-net;    ip -br link | grep -iE 'wlan|ap[0-9]|p2p|swlan'; ls /sys/class/ieee80211/ 2>/dev/null
s wifi-procs;  ps -A -o PID,NAME,ARGS 2>/dev/null | grep -iE 'wmt|wlan|wifi|hostapd|wpa_supp|conn' | grep -v grep
s wifi-fw;     ls /vendor/firmware 2>/dev/null | grep -iE 'wifi|wmt|conn|soc|mt66|bt|WIFI'
s dmesg-wifi;  dmesg 2>/dev/null | grep -iE 'wlan|wifi|wmt|conninfra|connfem|gen4m|mt66' | tail -120
# --- display / touch / tasti
s drm;         ls -l /dev/dri /dev/graphics 2>/dev/null; ls /sys/class/drm/ 2>/dev/null
for c in /sys/class/drm/card*-*; do [ -d "$c" ] && echo "$c status=$(cat $c/status 2>/dev/null) modes=$(head -3 $c/modes 2>/dev/null | tr '\n' ' ')"; done
s fbdev;       ls -l /dev/fb* /dev/graphics/fb* 2>/dev/null; cat /sys/class/graphics/fb0/modes /sys/class/graphics/fb0/virtual_size 2>/dev/null
s drm-debugfs; mount | grep -q debugfs || mount -t debugfs none /sys/kernel/debug 2>/dev/null; ls /sys/kernel/debug/dri/0/ 2>/dev/null; head -c 4000 /sys/kernel/debug/dri/0/state 2>/dev/null
s panel;       dmesg 2>/dev/null | grep -iE 'panel|dsi|lcm|disp|mtk_drm|oplus_display' | head -80
s backlight;   for b in /sys/class/backlight/* /sys/class/leds/lcd-backlight; do [ -e "$b" ] && echo "$b brightness=$(cat $b/brightness 2>/dev/null) max=$(cat $b/max_brightness 2>/dev/null)"; done
s input;       cat /proc/bus/input/devices
s getevent;    getevent -pl 2>/dev/null | head -150
s touch-fw;    ls -l /vendor/firmware /odm/firmware /vendor/etc/firmware 2>/dev/null | grep -iE 'touch|tp|goodix|gt9|novatek|nt36|focal|ft|syna|ilitek|samsung|s6sy'
s dmesg-touch; dmesg 2>/dev/null | grep -iE 'touch|tp_|goodix|novatek|nvt|focal|syna|s6sy|sec_ts' | head -60
# --- USB gadget (il canale SSH 10.0.0.1 del progetto passa da qui)
s usb;         ls /sys/class/udc 2>/dev/null; ls /config/usb_gadget/ 2>/dev/null; ls /config/usb_gadget/*/functions 2>/dev/null; getprop sys.usb.config; getprop sys.usb.controller
s dmesg-usb;   dmesg 2>/dev/null | grep -iE 'musb|mtu3|ssusb|gadget|ncm|rndis|udc' | tail -40
# --- alimentazione / ricarica (sul NX679J servivano moduli glink: qui sara' altro)
s power;       ls /sys/class/power_supply/; for p in /sys/class/power_supply/*; do echo "$p: $(cat $p/type 2>/dev/null) cap=$(cat $p/capacity 2>/dev/null) status=$(cat $p/status 2>/dev/null)"; done
s pstore;      ls -l /sys/fs/pstore 2>/dev/null; ls -l /proc/last_kmsg 2>/dev/null
s rawdmesg;    dmesg 2>/dev/null | head -400
EOF

adb push "$OUT/.probe.sh" /data/local/tmp/nord2t-probe.sh >/dev/null
adb shell su -c 'sh /data/local/tmp/nord2t-probe.sh' > "$OUT/inventario.txt" 2>&1 || true
adb exec-out su -c 'cat /proc/config.gz 2>/dev/null' > "$OUT/config.gz" || true
if [ -s "$OUT/config.gz" ]; then gzip -dc "$OUT/config.gz" > "$OUT/kernel.config" 2>/dev/null || true; fi
rm -f "$OUT/config.gz"
adb exec-out su -c 'cat /sys/firmware/fdt 2>/dev/null' > "$OUT/running_fdt.dtb" || true
[ -s "$OUT/running_fdt.dtb" ] || rm -f "$OUT/running_fdt.dtb"
if [ -f "$OUT/running_fdt.dtb" ] && command -v dtc >/dev/null; then
  dtc -I dtb -O dts -o "$OUT/running_fdt.dts" "$OUT/running_fdt.dtb" 2>/dev/null || true
fi
adb shell rm -f /data/local/tmp/nord2t-probe.sh

# --- riassunto: le domande che decidono il port (LEGGIMI.md, "Gate della Fase 0")
I="$OUT/inventario.txt"
sec() { awk -v s="=== SECTION.$1 ===" '$0==s{f=1;next} /^=== SECTION\./{f=0} f' "$I"; }
cfg() { [ -f "$OUT/kernel.config" ] && grep -E "^$1=" "$OUT/kernel.config" | head -1 || echo "$1: ?"; }
{
  echo "== RIASSUNTO FASE 0 ($OUT) =="
  echo "kernel:        $(sec uname | head -1)"
  echo "slot attivo:   $(sec slot | head -1)"
  echo "verifiedboot:  $(grep -m1 'ro.boot.verifiedbootstate' "$I" || echo '?')"
  echo "boot headers:"; sec boot-headers | sed 's/^/   /'
  echo "fbdev:         $(sec fbdev | grep -c fb) nodi"
  echo "DRM:           $(sec drm | grep -c card) voci"
  echo "UDC (gadget):  $(sec usb | head -1)"
  echo "ccmni netdev:  $(sec modem-net | grep -c ccmni)"
  echo "nodi CCCI:     $(sec modem-dev | grep -ciE 'ccci|ttyC')"
  echo "daemon modem:  $(sec modem-procs | awk '{print $2}' | sort -u | tr '\n' ' ')"
  echo "nodo wmtWifi:  $(sec wifi-dev | grep -c wmtWifi)"
  echo "moduli carichi: $(sec modules-loaded | grep -c .)"
  for c in CONFIG_USB_CONFIGFS_NCM CONFIG_USB_CONFIGFS_RNDIS CONFIG_DRM_FBDEV_EMULATION CONFIG_NAMESPACES \
           CONFIG_IKCONFIG_PROC CONFIG_MODULE_SIG_FORCE CONFIG_BRIDGE CONFIG_NETFILTER_XT_TARGET_MASQUERADE \
           CONFIG_NF_TABLES CONFIG_TUN CONFIG_PANIC_TIMEOUT; do echo "   $(cfg $c)"; done
} | tee "$OUT/RIASSUNTO.txt"

if [ "${1:-}" = "--fastboot" ]; then
  echo "== riavvio nel bootloader per 'fastboot getvar all' =="
  adb reboot bootloader
  i=0; until fastboot devices 2>/dev/null | grep -q .; do i=$((i+1)); [ $i -gt 60 ] && { echo "fastboot non visto in 120 s (vedi LEGGIMI: CPH2399/OOS14)"; exit 1; }; sleep 2; done
  fastboot getvar all > "$OUT/fastboot-getvar.txt" 2>&1 || true
  grep -iE 'unlocked|current-slot|slot-|secure|product|is-userspace|max-download|partition-size:(boot|vendor_boot|init_boot)' "$OUT/fastboot-getvar.txt" | tee -a "$OUT/RIASSUNTO.txt"
  echo "(il telefono resta in fastboot: 'fastboot reboot' per tornare ad Android)"
fi
echo "Inventario in $OUT/ — mandami RIASSUNTO.txt e inventario.txt per la Fase 1."
