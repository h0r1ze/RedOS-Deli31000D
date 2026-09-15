#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Возврат системы в исходное состояние: убирает всё, что поставили
# install-printer.sh и install-scanner.sh, и помогает вернуть очереди
# печати прежний PPD.
#
#   sudo ./rollback.sh                 # только показать, что будет сделано
#   sudo ./rollback.sh --yes           # выполнить
#   sudo ./rollback.sh --yes --drop-queue        # ещё и удалить очередь целиком
#   sudo ./rollback.sh --yes --restore-ppd ФАЙЛ  # вернуть очереди указанный PPD
#
# Ключи:
#   --yes             выполнять, а не показывать
#   --name ИМЯ        имя очереди (по умолчанию Deli-M3100D)
#   --restore-ppd Ф   переназначить очереди этот PPD
#   --drop-queue      удалить очередь (потом добавите её заново мастером)
#   --keep-scanner    не трогать установленный SANE-backend

set -u

NAME=Deli-M3100D
DO=no
RESTORE=""
DROP=no
KEEP_SCANNER=no

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y) DO=yes; shift ;;
        --name) NAME=$2; shift 2 ;;
        --restore-ppd) RESTORE=$2; shift 2 ;;
        --drop-queue) DROP=yes; shift ;;
        --keep-scanner) KEEP_SCANNER=yes; shift ;;
        -h|--help) awk 'NR>2 && /^#/ { sub(/^# ?/, ""); print; next } NR>2 { exit }' "$0"; exit 0 ;;
        *) echo "неизвестный ключ: $1" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" = 0 ] || { echo "Запускать от root." >&2; exit 1; }

say() { printf '%s\n' "$*"; }
run() {
    if [ "$DO" = yes ]; then
        say "  + $*"
        "$@" >/dev/null 2>&1 || say "    (не выполнилось, это не страшно)"
    else
        say "  ~ $*"
    fi
}

SERVERBIN=$(cups-config --serverbin 2>/dev/null) || SERVERBIN=/usr/lib/cups
FILTERDIR=$SERVERBIN/filter
MODELDIR=/usr/share/cups/model

[ "$DO" = yes ] || say "=== РЕЖИМ ПОКАЗА: ничего не меняется, добавьте --yes ==="

# --- 1. что сейчас --------------------------------------------------------

say ""
say "=== что стоит сейчас ==="
for f in /etc/cups/ppd/*.ppd; do
    [ -r "$f" ] || continue
    nick=$(sed -n 's/^\*NickName:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$f" | head -1)
    say "  $(basename "$f" .ppd): $nick"
done
say ""
say "  задания в очередях:"
lpstat -o 2>/dev/null | sed 's/^/    /' || true

# --- 2. снять задания и погасить очередь ----------------------------------

say ""
say "=== снимаю зависшие задания ==="
run cancel -a -x
run cupsdisable "$NAME"

# --- 3. убрать то, что поставил install-printer.sh ------------------------

say ""
say "=== убираю фильтр и PPD из комплекта ==="
[ -e "$FILTERDIR/deli-rasterize" ] && run rm -f "$FILTERDIR/deli-rasterize"
for f in "$MODELDIR"/Deli-M3100D-*.ppd; do
    [ -e "$f" ] && run rm -f "$f"
done

# --- 4. вернуть очереди прежний драйвер -----------------------------------

say ""
say "=== очередь $NAME ==="
CURRENT=/etc/cups/ppd/$NAME.ppd
if [ -r "$CURRENT" ] && grep -q 'deli-rasterize' "$CURRENT" 2>/dev/null; then
    say "  сейчас у неё PPD из этого комплекта — его надо заменить"
elif [ -r "$CURRENT" ]; then
    say "  PPD очереди к комплекту отношения не имеет, менять не обязательно"
else
    say "  очереди с таким именем нет"
fi

if [ "$DROP" = yes ]; then
    run lpadmin -x "$NAME"
    say "  очередь удалена; добавьте её заново: «Параметры — Принтеры — Добавить»"
elif [ -n "$RESTORE" ]; then
    if [ -r "$RESTORE" ]; then
        URI=$(lpstat -v "$NAME" 2>/dev/null | sed -n 's/.*: //p')
        [ -n "$URI" ] || URI=$(lpinfo -v 2>/dev/null | sed -n 's/^direct  *//p' | grep -i deli | head -1)
        if [ -n "$URI" ]; then
            run lpadmin -p "$NAME" -v "$URI" -P "$RESTORE" -E
            run cupsenable "$NAME"
            run cupsaccept "$NAME"
        else
            say "  не нашёл адрес устройства, задайте вручную:"
            say "    lpadmin -p $NAME -v АДРЕС -P $RESTORE -E"
        fi
    else
        say "  файл $RESTORE не читается" >&2
    fi
else
    say ""
    SAVED=$(ls -1t /etc/cups/ppd/"$NAME".ppd.before-deli-* 2>/dev/null | head -3)
    if [ -n "$SAVED" ]; then
        say "  есть сохранённые копии прежнего PPD этой очереди:"
        printf '%s\n' "$SAVED" | sed 's/^/    /'
        say "    вернуть так:  sudo ./rollback.sh --yes --restore-ppd $(printf '%s\n' "$SAVED" | head -1)"
        say ""
    fi
    say "  чем заменить — выбрать из того, что есть в системе:"
    FOUND=$(find /usr/share/ppd /usr/share/cups/model /opt -iname '*deli*' \
                 \( -name '*.ppd' -o -name '*.ppd.gz' \) 2>/dev/null | head -10)
    if [ -n "$FOUND" ]; then
        printf '%s\n' "$FOUND" | sed 's/^/    /'
        say "    вернуть так:  sudo ./rollback.sh --yes --restore-ppd ФАЙЛ"
    else
        say "    PPD с упоминанием Deli в системе не нашлось"
    fi
    say ""
    say "  что предлагает сам CUPS:"
    MODELS=$(lpinfo -m 2>/dev/null | grep -iE 'deli|pantum' | head -10)
    if [ -n "$MODELS" ]; then
        printf '%s\n' "$MODELS" | sed 's/^/    /'
    else
        say "    (ничего подходящего)"
    fi
    say ""
    say "  если драйвер ставился пакетом — вернуть его целиком:"
    if command -v rpm >/dev/null 2>&1; then
        PKGS=$(rpm -qa 2>/dev/null | grep -iE 'deli|pantum')
        if [ -n "$PKGS" ]; then
            printf '%s\n' "$PKGS" | sed 's/^/    dnf reinstall /'
        else
            say "    пакетов Deli/Pantum не установлено"
        fi
    fi
    say ""
    say "  а проще всего — удалить очередь и добавить заново мастером:"
    say "    sudo ./rollback.sh --yes --drop-queue"
fi

# --- 5. сканер -------------------------------------------------------------

if [ "$KEEP_SCANNER" = no ]; then
    say ""
    say "=== убираю SANE-backend из комплекта ==="
    for d in /usr/lib64/sane /usr/lib/x86_64-linux-gnu/sane /usr/lib/sane \
             /usr/local/lib64/sane /usr/local/lib/sane; do
        for f in "$d/libsane-pantum.so" "$d/libsane-pantum.so.1"; do
            [ -e "$f" ] && run rm -f "$f"
        done
    done
    for f in /etc/sane.d/pantum.conf /etc/sane.d/dll.d/pantum \
             /etc/udev/rules.d/99-deli-m3100d.rules \
             /etc/udev/rules.d/60-pantum-open.rules; do
        [ -e "$f" ] && run rm -f "$f"
    done
    if [ -f /etc/sane.d/dll.conf ] && grep -qx 'pantum' /etc/sane.d/dll.conf; then
        run sed -i '/^pantum$/d' /etc/sane.d/dll.conf
    fi
    # строку, которую мог добавить пробный вариант с xerox_mfp
    if [ -f /etc/sane.d/xerox_mfp.conf ] && grep -q '0x300e' /etc/sane.d/xerox_mfp.conf; then
        run sed -i '/0x300e/d' /etc/sane.d/xerox_mfp.conf
    fi
    run udevadm control --reload
fi

# --- 6. перезапуск ---------------------------------------------------------

say ""
say "=== перезапускаю CUPS ==="
run systemctl restart cups

say ""
if [ "$DO" = yes ]; then
    cat <<'TXT'
Готово. Дальше обязательно:

  1. Выключите МФУ кнопкой, подождите полминуты, включите снова.
     Пробные задания могли оставить аппарат в чужом языковом режиме —
     полосы на бумаге чаще всего именно от этого, и лечится это только
     полным сбросом питания.

  2. Напечатайте что-нибудь простое и посмотрите:
        lp -d Deli-M3100D /usr/share/cups/data/testprint

Если полосы остались — это не состояние аппарата, а драйвер очереди:
удалите очередь (--drop-queue) и добавьте заново тем драйвером, который
стоял раньше.
TXT
else
    say "Это был показ. Чтобы выполнить:  sudo ./rollback.sh --yes"
fi
