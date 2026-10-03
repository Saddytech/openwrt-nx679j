# OnePlus Nord 2T: rifare il port NX679J (OpenWrt nativo sullo slot B)

Questa guida riprende il metodo del port NX679J (RedMagic 7) e lo applica al **OnePlus Nord 2T 5G** (CPH2399 / CPH2401). Dice cosa si porta così com'è, cosa va rifatto da capo e quali passaggi manuali diventano script.

> ⚠️ Le voci segnate **[DA VERIFICARE]** sono ipotesi. Si confermano con l'inventario della Fase 0 (`00-inventario.sh`) prima di scrivere qualunque cosa sul telefono. Vale la regola del progetto: nessun risultato senza verifica.

---

## 1. Verdetto: è fattibile?

**Sì, in parte.** La differenza che decide tutto è il SoC. Il RedMagic 7 monta un **Qualcomm** SM8450; il Nord 2T monta un **MediaTek Dimensity 1300** (famiglia MT6893). Il **metodo** del progetto si porta: kernel vendor intatto, ramdisk patchato, chroot OpenWrt, slot A come oracolo e via di ritorno, flash con i gate. Tutto il **codice legato all'hardware Qualcomm** va invece rifatto: modem QMI/QRTR, moduli `cnss`/`qca6490`, DRM SDE/DSI, catena PON, partizioni `sde41`.

| Blocco | Sul NX679J (Qualcomm) | Sul Nord 2T (MediaTek) | Difficoltà | Riuso |
|---|---|---|---|---|
| Sblocco + root | `unlocked`/`orange`, Magisk su slot A | Sblocco ufficiale OnePlus + Magisk sul `boot.img`. **Attenzione CPH2399 (India) con OxygenOS 14:** ci sono segnalazioni di fastboot inaccessibile | bassa (alta se il fastboot è bloccato) | procedura |
| Boot image | header v4, ramdisk a offset 49115136, `lz4 -l` | header **v2 o v4 [DA VERIFICARE]**; possibile header MTK da 512 B davanti al ramdisk | bassa | **`bootimg.py` (generalizzato)** |
| Recupero da brick | EDL rotto, solo slot A | BROM/mtkclient **incerto** (autenticazione Oppo/OnePlus, test point) | — | stessa disciplina: slot A + backup |
| `/init` PID 1 + `switch.sh` + chroot | funzionante | stessa architettura; cambiano moduli, nodi e partizioni | media | **alto** (`nx679j-init-v9.c` è freestanding aarch64) |
| SSH su USB gadget (NCM `10.0.0.1`) | configfs, UDC Qualcomm | configfs, UDC MediaTek (`musb`/`mtu3`) | bassa | alto (cambia il nome dell'UDC) |
| OpenWrt 25.12.5 armsr/armv8 + LuCI | chroot | identico (stesso rootfs aarch64) | bassa | **totale** |
| Wi-Fi AP | `cnss2` + `qca_cld3_qca6490.ko` | `conninfra`/`wmt` + `wlan_drv_gen4m` + `echo 1 > /dev/wmtWifi` (AP: `ap0`) **[DA VERIFICARE]** | media | concetto |
| **Modem / dati mobili** | QMI su QRTR, `qmicli`, MM patchato, rmnet | **CCCI + `ccmni`**: il modem lo avvia e lo pilota lo stack Android proprietario (`ccci_mdinit`, `ccci_fsd`, `nvram_daemon`, `mtkfusionrild`) | **molto alta: è ricerca nuova** | quasi nullo (resta la parte netifd/LuCI) |
| UI sul display | DRM grezzo, trappola dei 58 ms di idle (DSI SDE) | DRM MediaTek (`mtk_drm`), forse con **fbdev** **[DA VERIFICARE]** | media (potenzialmente più facile) | alto (`ui-*.c`: cambia solo lo strato `ui-2-drm.c`) |
| Touch | Goodix GT9897 + firmware dal vendor | controller da identificare; firmware in `/vendor/firmware` o `/odm` | media | concetto |
| Tasti | `qcom-pon` → `pm8941-pwrkey` | `mtk-pmic-keys` (quasi sempre built-in) | bassa | ricerca per NOME già pronta |

**In una riga:** router OpenWrt con SSH, LuCI, Wi-Fi AP e UI sul display è **realistico**, con molto del lavoro già fatto. L'uplink **4G/5G nativo senza Android** è il vero progetto di ricerca. Sul NX679J il modem Qualcomm parla QMI, un protocollo aperto con libqmi e ModemManager pronti. Il modem MediaTek invece dipende da demoni Android proprietari.

### Le due strade per il modem (decidere dopo la Fase 0)

1. **Strada fedele (come il NX679J): OpenWrt nativo, modem senza Android.** I demoni vendor `ccci_mdinit`, `ccci_fsd` e `nvram_daemon` girano dentro un mini-ambiente Android: `/vendor` montato, linker bionic, property service minimo, simile a Halium/LXC. Poi si pilota il modem via AT sui nodi CCCI, con dati su `ccmni0`. ofono, che ha un driver MTK/AT, è la base da studiare. Il risultato è identico al progetto originale, ma servono settimane di ricerca e l'esito non è garantito.
2. **Strada ibrida (rapida): Android minimo sotto, OpenWrt in chroot sopra.** Android resta PID 1 e gestisce modem e SIM. OpenWrt gira in chroot/namespace e prende LAN, Wi-Fi AP, firewall, LuCI e UI, usando `ccmni0` come WAN già configurata da Android. Si ottiene un router funzionante in pochi giorni. Il prezzo: non è "OpenWrt nativo" e l'avvio è più pesante.

Il consiglio è procedere per tappe: Fasi 0-4 sulla strada fedele, che danno un router senza modem. Poi un tentativo a tempo sul modem nativo (Fase 5). Se fallisce, si ripiega sulla strada ibrida **solo per il modem**.

---

## 2. Roadmap con i gate (stessa disciplina del NX679J)

Ogni fase ha un **gate**: non si passa alla fase dopo senza l'evidenza indicata.

### Fase 0: inventario (sola lettura) → `00-inventario.sh`
- Android stock su slot A, debug USB, root (se non c'è ancora: Fase 1 prima, poi si torna qui).
- `./00-inventario.sh --fastboot` produce `inventario-*/RIASSUNTO.txt`, `inventario.txt`, `kernel.config`, `running_fdt.dtb` e `fastboot-getvar.txt`.
- **Gate:** sappiamo (1) kernel e versione, (2) header del `boot` (v2/v4, MTK header sì/no), (3) se il device è A/B (atteso `slot-count:2`), (4) se c'è fbdev o solo DRM, (5) nome dell'UDC, (6) quali demoni e nodi CCCI esistono, (7) se `fastboot --set-active` funziona.

### Fase 1: sblocco, root, backup → `01-backup.sh`
1. Impostazioni → Opzioni sviluppatore → **Sblocco OEM** e **Debug USB** (*manuale*).
2. `adb reboot bootloader` → `fastboot flashing unlock` → conferma con i tasti volume (*manuale, cancella i dati*).
3. Magisk: si patcha il `boot.img` dello **stesso firmware installato** (dall'OTA con `payload-dumper-go`, vedi `ESTRAZIONE-BLOB.md` §1) e si fa `fastboot flash boot_a magisk_patched.img`. Se non si avvia, prova anche `fastboot --disable-verity --disable-verification flash vbmeta_a vbmeta.img` **[DA VERIFICARE se serve]**.
4. `./01-backup.sh` copia tutte le partizioni (tranne `userdata`/`super`) con sha256 confrontato fra telefono e PC.
- **Gate:** `BACKUP_PASS` e copia del backup su un secondo disco. **Prima di questo gate non si scrive nulla.** `nvram`, `nvdata`, `nvcfg`, `protect1/2` e `proinfo` sono l'equivalente dell'EFS: contengono IMEI e calibrazioni, che non si ricreano.

### Fase 1b: rete di sicurezza (facoltativa ma preziosa)
- Prova **una sola** operazione di lettura con mtkclient (`mtk printgpt`) in modalità BROM (telefono spento, VOL+ e cavo).
- Se funziona, hai un recupero da brick che il NX679J non aveva (lì l'EDL era rotto). Se non funziona, lo slot A resta l'unica via di ritorno: si lavora **solo** sullo slot B.

### Fase 2: provare che lo slot B accetta un'immagine → `02-flash-boot.sh`, `03-slot.sh`
Si ripete la prova del 17/09 del NX679J: **il boot Magisk dello slot A, scritto su `boot_b`, deve avviare Android dallo slot B.**
```sh
./02-flash-boot.sh magisk_patched.img --part boot_b --expect-current backup-*/boot_b.img
./03-slot.sh b        # Android parte da B?  poi:  ./03-slot.sh a
```
- **Gate:** Android si avvia da B e si torna su A senza azioni fisiche. Così è provato il ciclo A↔B (il ciclo chiuso della Fase 1(b) di `DOCUMENTAZIONE.md`).

### Fase 3: primo ramdisk proprio (PID 1 + gadget USB) → `bootimg.py`
Si parte dal **contenitore già accettato** (il boot Magisk) e si sostituisce **solo** il ramdisk:
```sh
python3 bootimg.py info magisk_patched.img           # versione header, offset, compressione
python3 bootimg.py extract magisk_patched.img x/     # x/ramdisk = ramdisk originale
# overlay: /init (nx679j-init-v9.c ricompilato), /nord2t/switch.sh, moduli necessari
python3 bootimg.py mkcpio overlay/ new.cpio --root
lz4 -l -9 -c new.cpio > new.rd       # STESSO formato che 'info' ha mostrato (qui: lz4 legacy)
python3 bootimg.py swap magisk_patched.img new.rd boot_b-v1.img
```
`bootimg.py` legge l'header (v0-v4), sposta byte per byte le sezioni dopo il ramdisk, mantiene la lunghezza del file, conserva l'eventuale header MTK e rifiuta un formato di compressione diverso dall'originale. Sull'header v4 del NX679J ricalcola esattamente l'offset fisso del vecchio builder (4096 + 49111040 = **49115136**). Prova sintetica: `python3 bootimg.py selftest`.

Cosa cambiare in `/init` e `switch.sh` rispetto al NX679J:
- **niente** `insmod` in PID 1 (lezione v5/v6: un modulo che si blocca congela il telefono senza segni esterni);
- gadget: nome UDC da `ls /sys/class/udc` (preso dall'inventario), funzione `ncm` (o `rndis` se manca `CONFIG_USB_CONFIGFS_NCM`), `10.0.0.1/24`;
- partizioni: per nome (`/dev/block/by-name/...`), mai numeri `sdeNN` fissi.
- **Gate:** dall'host risponde `nc 10.0.0.1 9999` (il relay di sola lettura della v9), poi SSH.

### Fase 4: OpenWrt in chroot + LuCI + Wi-Fi AP
- Rootfs OpenWrt 25.12.5 armsr/armv8: è **lo stesso** del NX679J. Persistenza con i tar iniettati nel ramdisk (`04-persistenza/`, procedura in `08-skill/nx679j-openwrt/references/persistenza-v87.md`).
- Wi-Fi MediaTek: caricare i moduli della connettività nell'ordine visto in `init-insmod` dell'inventario, poi `echo 1 > /dev/wmtWifi` (STA) o `echo AP > /dev/wmtWifi` (AP, interfaccia `ap0`) e `wpad`/`hostapd` di OpenWrt su nl80211 **[DA VERIFICARE]**.
- **Gate:** SSH + LuCI HTTP 200 + client collegato all'AP. A questo punto hai un **router senza modem**.

### Fase 5: modem (ricerca, a tempo)
- Usa Android su slot A come **oracolo**: `strace`/`logcat -b radio` di `ccci_mdinit`, di `mtkfusionrild` e dei comandi AT in chiaro mentre si accende il modem e si attiva la connessione dati.
- Obiettivo minimo: modem avviato (stato in `/sys/kernel/ccci/`) + un `AT` che risponde su un nodo CCCI + `ccmni0` con IP e ping a `8.8.8.8` (mai `1.1.1.1`, vedi le trappole del NX679J).
- In OpenWrt: interfaccia di sola lettura sul modello del proto `nx679j` (`proto_init_update "$ifname" 1 1`, nessuna route riportata). La lezione sull'L3 della Fase 3 vale identica.
- **Gate (o ripiego):** se dopo il tempo stabilito il modem non si registra, si passa alla strada ibrida.

### Fase 6: UI sul display
- Se c'è **fbdev**: disegno diretto su `/dev/fb0`, molto più semplice.
- Se c'è solo DRM: si riusa `ui-*.c` cambiando `ui-2-drm.c` (ID di CRTC/plane/connector dall'enumerazione, pitch reale da `CREATE_DUMB`).
- Regole che restano valide finché l'hardware non dimostra il contrario: mai aprire `/dev/dri/card0` se un altro master è attivo, sempre `TEST_ONLY` prima, commit `NONBLOCK`, e standby con frame nero e backlight 0 invece del DPMS.

---

## 3. Cosa è automatizzato e cosa resta manuale

| Passaggio del NX679J | Prima | Adesso |
|---|---|---|
| Inventario dell'hardware | comandi sparsi (`phase0-inventory.sh`, `capture-baseline.sh`) | **`00-inventario.sh`**: un comando, riassunto con le domande-gate |
| Backup delle partizioni | `adb shell su -c dd ...` una per una | **`01-backup.sh`**: tutte, in streaming, sha256 telefono = PC |
| Costruzione del boot image | `build-vNN.py` con offset fissi per il NX679J | **`bootimg.py`**: legge l'header, con test e controlli |
| Flash con gate | `dd` + `md5sum` a mano; il `WRITE_GATE` era fuori dal progetto | **`02-flash-boot.sh`**: gate G1-G5, mai sullo slot attivo |
| Cambio slot A↔B | `torna-b.sh` con `sleep 30`/`sleep 200` | **`03-slot.sh`**: polling, verifica di `current-slot` |
| Verifica post-boot | one-liner SSH | si riusa la procedura 1 della skill, adattata alla Fase 4 |

**Restano manuali** (per sicurezza o per limiti fisici):
- attivare *Sblocco OEM* e confermare `fastboot flashing unlock` con i tasti;
- entrare in BROM o fastboot quando il telefono non risponde (combinazioni di tasti, test point);
- forzare lo spegnimento (POWER ~15 s) dopo un blocco: sul NX679J era l'unico recupero da un blocco del display;
- le **decisioni** ai gate: gli script si fermano e stampano il motivo, non decidono loro di andare avanti.

---

## 4. Trappole note da evitare fin dall'inizio

- **Mai scrivere sullo slot attivo** e **mai** su `nvram`/`nvdata`/`protect*`/`proinfo`/`seccfg`/`preloader`/`lk`: `02-flash-boot.sh` accetta solo partizioni `boot_*` passate esplicitamente.
- **Il firmware usato per Magisk deve essere identico a quello installato** (stessa build OxygenOS), altrimenti bootloop.
- **CPH2399 con OxygenOS 14:** se `adb reboot bootloader` non porta al fastboot, non forzare. Valuta mtkclient (Fase 1b) o la variante di firmware prima di proseguire.
- **Anti-rollback:** non flashare `lk`/`preloader` o firmware più vecchi di quello installato.
- **Sul MediaTek lo stato A/B non è negli attributi GPT** come sul Qualcomm. Di solito sta in `misc` o `para` **[DA VERIFICARE]**. Usa sempre `fastboot --set-active`, mai scritture a mano.
- Tutte le lezioni del NX679J non legate al Qualcomm restano valide: PID 1 senza syscall bloccanti, `scp -O`, niente `timeout`/`pkill` su busybox, giudicare un effetto su 4-5 boot e non su uno solo, ripetere un tentativo solo con un dato nuovo.

---

## 5. File di questa cartella

| File | Cosa fa | Scrive sul telefono? |
|---|---|---|
| `00-inventario.sh` | inventario Fase 0 + riassunto dei gate | no |
| `01-backup.sh` | backup completo con verifica sha256 | no |
| `bootimg.py` | info/extract/mkcpio/swap del ramdisk, `selftest` | no (lavora sul PC) |
| `02-flash-boot.sh` | flash con gate G1-G5 sullo slot inattivo | **sì**, solo `boot_*` inattivo |
| `03-slot.sh` | cambio slot via fastboot, con polling | cambia lo slot attivo |

**Primo passo concreto:** `./00-inventario.sh --fastboot` e poi condividere `RIASSUNTO.txt` e `inventario.txt`. Da lì si decidono header, gadget, Wi-Fi e la strada per il modem.
