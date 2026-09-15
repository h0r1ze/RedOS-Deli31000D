#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Снимает с машины всё, что нужно, чтобы выбрать драйвер для Deli M3100D,
# и складывает в один файл отчёта. Ничего не устанавливает и не меняет.
#
#   ./tools/deli-probe.sh [-o отчёт.txt] [--vid 0x300e] [--pid 0x10c4]

set -u

VID=0x300e
PID=0x10c4
OUT=""
HERE=$(cd "$(dirname "$0")" && pwd)

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output) OUT=$2; shift 2 ;;
        --vid) VID=$2; shift 2 ;;
        --pid) PID=$2; shift 2 ;;
        -h|--help) awk 'NR>2 && /^#/ { sub(/^# ?/, ""); print; next } NR>2 { exit }' "$0"; exit 0 ;;
        *) echo "неизвестный ключ: $1" >&2; exit 2 ;;
    esac
done

[ -n "$OUT" ] || OUT="deli-probe-$(date +%Y%m%d-%H%M%S).txt"
SHORT=$(printf '%s:%s' "${VID#0x}" "${PID#0x}")

section() {
    printf '\n===== %s =====\n' "$1"
}

run() {
    printf '\n$ %s\n' "$*"
    "$@" 2>&1 || printf '(команда завершилась с кодом %d)\n' $?
}

collect() {
    printf 'Отчёт по Deli M3100D, собран %s на %s\n' "$(date -Is)" "$(hostname)"

    section "система"
    run cat /etc/os-release
    run uname -a

    section "пакеты печати и сканирования"
    if command -v rpm >/dev/null 2>&1; then
        run rpm -q cups cups-filters ghostscript sane-backends sane-backends-libs usbutils
    elif command -v dpkg >/dev/null 2>&1; then
        run dpkg -l cups cups-filters ghostscript sane-utils libsane1 usbutils
    fi
    if command -v gs >/dev/null 2>&1; then
        printf '\n$ gs --version\n'; gs --version 2>&1
        printf '\nдоступные устройства Ghostscript (интересны pxlmono, ljet4, ps2write):\n'
        gs -h 2>/dev/null | sed -n '/Available devices/,/^$/p' \
            | tr ' ' '\n' | grep -E '^(pxl|ljet|lj|pcl|ps2write|cups|bit)' | sort -u | tr '\n' ' '
        printf '\n'
    else
        printf '\nGhostscript не установлен — без него печать через PPD не поедет.\n'
    fi

    section "USB"
    run lsusb
    printf '\n$ lsusb -v -d %s\n' "$SHORT"
    lsusb -v -d "$SHORT" 2>&1 | sed -n '1,200p'

    section "интерфейсы и эндпоинты (разбор дескрипторов)"
    if [ -r /sys/bus/usb/devices ]; then
        DELI_TOOLS="$HERE" python3 - "$VID" "$PID" <<'PY' 2>&1
import sys, os
sys.path.insert(0, os.environ.get("DELI_TOOLS", "."))
try:
    import deli_usb as usb
except ImportError as exc:
    print("не найден модуль deli_usb.py:", exc); raise SystemExit(0)
vid, pid = int(sys.argv[1], 16), int(sys.argv[2], 16)
devs = usb.find_devices(vid, pid)
if not devs:
    print("устройство %04x:%04x не найдено" % (vid, pid)); raise SystemExit(0)
for d in devs:
    print("%s %s, серийный %s, узел %s" % (d["manufacturer"], d["product"], d["serial"], d["node"]))
    try:
        _, ifaces = usb.parse_descriptors(d["node"])
    except OSError as exc:
        print("  дескрипторы не читаются (%s) — нужен root" % exc); continue
    for i in ifaces:
        print("  " + usb.describe_interface(i))
    ifno, ep_in, ep_out = usb.find_vendor_interface(ifaces)
    if ifno is None:
        print("  vendor-интерфейса со сканером не видно")
    else:
        print("  сканер, вероятно, на интерфейсе %d (bulk in 0x%02x, out 0x%02x)" % (ifno, ep_in, ep_out))
    pif, _, _ = usb.find_printer_interface(ifaces)
    if pif is not None:
        print("  интерфейс принтера: %d" % pif)
PY
    fi

    section "IEEE-1284 Device ID"
    for f in /sys/class/usbmisc/lp*/device/ieee1284_id; do
        [ -r "$f" ] || continue
        printf '%s:\n  %s\n' "$f" "$(cat "$f")"
    done
    if [ -x "$HERE/deli-devid.py" ]; then
        run python3 "$HERE/deli-devid.py" --vid "$VID" --pid "$PID" --pjl
    fi

    section "модуль usblp и узлы"
    run lsmod
    printf '\n$ ls -l /dev/usb/\n'; ls -l /dev/usb/ 2>&1
    printf '\n$ dmesg | tail\n'; dmesg 2>/dev/null | grep -iE 'usblp|usb .*(deli|printer)' | tail -20

    section "CUPS"
    run lpinfo -v
    run lpstat -t
    run lpstat -p -d
    printf '\nустановленные PPD в /etc/cups/ppd:\n'; ls -l /etc/cups/ppd 2>&1

    section "SANE"
    run sane-find-scanner -q
    run scanimage -L
    printf '\n$ cat /etc/sane.d/dll.conf (активные строки)\n'
    grep -v '^\s*#' /etc/sane.d/dll.conf 2>/dev/null | grep -v '^\s*$' | tr '\n' ' '
    printf '\n'
    printf '\nдополнительные backends в /etc/sane.d/dll.d:\n'; ls -l /etc/sane.d/dll.d 2>&1

    section "SELinux"
    run getenforce

    printf '\n===== конец отчёта =====\n'
}

collect > "$OUT" 2>&1
printf 'Отчёт записан: %s\n' "$OUT"
printf 'Главное из него:\n\n'
grep -A 6 'IEEE-1284 Device ID' "$OUT" | head -20
printf '\nПолный файл можно целиком приложить к вопросу — в нём нет паролей,\n'
printf 'только сведения о железе, пакетах и очередях печати.\n'
