#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Ставит фильтр, PPD и очередь CUPS для Deli M3100D.
#
#   ./install-printer.sh                     # язык печати выбрать по Device ID
#   ./install-printer.sh --pdl pcl5e         # задать вручную
#   ./install-printer.sh --uri usb://...     # если очередь не находится сама
#   ./install-printer.sh --uninstall
#
# Ключи:
#   --pdl pclxl|pcl5e|ps|auto  какой PPD ставить (по умолчанию auto)
#   --name ИМЯ                 имя очереди (по умолчанию Deli-M3100D)
#   --uri URI                  адрес устройства вместо автопоиска
#   --default                  сделать очередь принтером по умолчанию
#   --uninstall                убрать очередь, PPD и фильтр

set -u

PDL=auto
NAME=Deli-M3100D
URI=""
MAKE_DEFAULT=no
UNINSTALL=no
HERE=$(cd "$(dirname "$0")" && pwd)

while [ $# -gt 0 ]; do
    case "$1" in
        --pdl) PDL=$2; shift 2 ;;
        --name) NAME=$2; shift 2 ;;
        --uri) URI=$2; shift 2 ;;
        --default) MAKE_DEFAULT=yes; shift ;;
        --uninstall) UNINSTALL=yes; shift ;;
        -h|--help) awk 'NR>2 && /^#/ { sub(/^# ?/, ""); print; next } NR>2 { exit }' "$0"; exit 0 ;;
        *) echo "неизвестный ключ: $1" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" = 0 ] || { echo "Запускать от root." >&2; exit 1; }

SERVERBIN=$(cups-config --serverbin 2>/dev/null) || SERVERBIN=/usr/lib/cups
FILTERDIR=$SERVERBIN/filter
MODELDIR=/usr/share/cups/model

if [ "$UNINSTALL" = yes ]; then
    lpadmin -x "$NAME" 2>/dev/null && echo "очередь $NAME удалена"
    rm -f "$FILTERDIR/deli-rasterize" && echo "фильтр удалён"
    rm -f "$MODELDIR"/Deli-M3100D-*.ppd && echo "PPD удалены"
    exit 0
fi

command -v lpadmin >/dev/null 2>&1 || { echo "CUPS не установлен (нет lpadmin)." >&2; exit 1; }
command -v gs >/dev/null 2>&1 || {
    echo "Не найден Ghostscript. Поставьте: dnf install ghostscript" >&2
    exit 1
}

# --- какой язык печати -------------------------------------------------------

device_id() {
    for f in /sys/class/usbmisc/lp*/device/ieee1284_id; do
        [ -r "$f" ] || continue
        cat "$f"
        return 0
    done
    return 1
}

if [ "$PDL" = auto ]; then
    ID=$(device_id 2>/dev/null) || ID=""
    CMD=$(printf '%s' "$ID" | tr ';' '\n' | sed -n 's/^ *CMD: *//p')
    UPPER=$(printf '%s' "$CMD" | tr 'a-z' 'A-Z')
    case "$UPPER" in
        *PCLXL*|*PCL6*) PDL=pclxl ;;
        *POSTSCRIPT*)   PDL="ps" ;;
        *PCL*)          PDL=pcl5e ;;
        *)              PDL="" ;;
    esac
    if [ -n "$PDL" ]; then
        echo "Device ID сообщает CMD: $CMD -> ставлю вариант $PDL"
    else
        PDL=pclxl
        echo "Определить язык печати по Device ID не удалось${ID:+ (CMD: $CMD)}."
        echo "Ставлю PCL-XL как самый вероятный. Если страница не выйдет или"
        echo "полезет мусор — сначала прогоните tools/deli-pdl-test.sh,"
        echo "потом переустановите с нужным --pdl (см. docs/02-printing.md)."
    fi
fi

PPD=$HERE/ppd/Deli-M3100D-$PDL.ppd
[ -r "$PPD" ] || { echo "Нет файла $PPD" >&2; exit 1; }

# --- адрес устройства --------------------------------------------------------

if [ -z "$URI" ]; then
    URI=$(lpinfo -v 2>/dev/null | sed -n 's/^direct  *//p' | grep -i 'deli' | head -1)
fi
if [ -z "$URI" ]; then
    URI=$(lpinfo -v 2>/dev/null | sed -n 's/^direct  *//p' | grep -i 'usb://' | head -1)
    [ -n "$URI" ] && echo "МФУ по имени не нашлось, беру первое USB-устройство: $URI"
fi
if [ -z "$URI" ]; then
    echo "CUPS не видит устройство. Проверьте кабель и питание, затем:" >&2
    echo "  lpinfo -v" >&2
    echo "и передайте адрес ключом --uri" >&2
    exit 1
fi

# --- установка ---------------------------------------------------------------

install -d "$FILTERDIR" "$MODELDIR"
install -m 0755 "$HERE/filter/deli-rasterize" "$FILTERDIR/deli-rasterize"
install -m 0644 "$HERE/ppd/Deli-M3100D-$PDL.ppd" "$MODELDIR/"

# SELinux в РЕД ОС включён: без правильной метки cupsd фильтр не запустит.
if command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$FILTERDIR/deli-rasterize" "$MODELDIR/Deli-M3100D-$PDL.ppd" 2>/dev/null
fi

if command -v cupstestppd >/dev/null 2>&1; then
    cupstestppd -q "$MODELDIR/Deli-M3100D-$PDL.ppd" || {
        echo "PPD не прошёл проверку cupstestppd." >&2
        exit 1
    }
fi

systemctl is-active --quiet cups 2>/dev/null || systemctl start cups 2>/dev/null

# Очередь с таким именем может уже существовать — тогда lpadmin не создаст
# вторую, а заменит драйвер у прежней. Сохраняем её PPD, чтобы было куда
# вернуться.
EXISTING=/etc/cups/ppd/$NAME.ppd
if [ -r "$EXISTING" ] && ! grep -q deli-rasterize "$EXISTING" 2>/dev/null; then
    BACKUP=$EXISTING.before-deli-$(date +%Y%m%d-%H%M%S)
    cp -a "$EXISTING" "$BACKUP"
    echo "Очередь $NAME уже есть, и драйвер у неё другой."
    echo "Прежний PPD сохранён: $BACKUP"
    echo "Вернуть его обратно:  sudo ./rollback.sh --yes --restore-ppd $BACKUP"
    echo
fi

lpadmin -p "$NAME" -v "$URI" -P "$MODELDIR/Deli-M3100D-$PDL.ppd" -E \
        -o printer-is-shared=false || exit 1
cupsenable "$NAME" 2>/dev/null
cupsaccept "$NAME" 2>/dev/null
[ "$MAKE_DEFAULT" = yes ] && lpadmin -d "$NAME"

echo
echo "Очередь $NAME создана:"
lpstat -l -p "$NAME" 2>/dev/null | head -5
echo
echo "Проверка:"
echo "  lp -d $NAME /usr/share/cups/data/testprint"
echo "Если вместо страницы вылезли иероглифы или ничего не поехало —"
echo "docs/02-printing.md, раздел «принтер печатает мусор»."
