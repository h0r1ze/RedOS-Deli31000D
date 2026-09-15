#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Опытным путём выясняет, какой язык печати понимает МФУ.
#
# Строка Device ID отвечает на этот вопрос не всегда, а ошибиться дорого:
# аппарат, не знающий присланного языка, либо молчит, либо печатает пачку
# страниц с мусором. Поэтому шлём по одному короткому заданию на каждом
# языке и смотрим, что выехало из принтера.
#
#   ./tools/deli-pdl-test.sh                 # по очереди, с подтверждением
#   ./tools/deli-pdl-test.sh --only pcl5
#   ./tools/deli-pdl-test.sh --save /tmp/ptest   # только собрать файлы
#
# Ключи:
#   --device УЗЕЛ  куда писать (по умолчанию первый /dev/usb/lpN)
#   --only ЯЗЫК    text | pcl5 | pclxl | ps
#   --save КАТАЛОГ сложить задания в каталог и ничего не отправлять
#
# ВАЖНО: пока идёт проверка, устройство должно быть свободно:
#   systemctl stop cups

set -u

DEVICE=""
ONLY=""
SAVE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --device) DEVICE=$2; shift 2 ;;
        --only) ONLY=$2; shift 2 ;;
        --save) SAVE=$2; shift 2 ;;
        -h|--help) awk 'NR>2 && /^#/ { sub(/^# ?/, ""); print; next } NR>2 { exit }' "$0"; exit 0 ;;
        *) echo "неизвестный ключ: $1" >&2; exit 2 ;;
    esac
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/deli-pdl.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# --- задания -----------------------------------------------------------------

# 1. Чистый текст с переводом страницы: понимает даже самый простой принтер,
#    если у него вообще есть текстовый режим.
printf 'Deli M3100D: prostoy tekst / plain text\r\nESLI VY VIDITE ETU STROKU - printer ponimaet tekst.\r\n\f' \
    > "$WORK/text.prn"

# 2. PCL5: сброс, шрифт Courier 12, текст, перевод страницы, сброс.
printf '\033E\033(s0p12h0s0b4099T\033&a0R' > "$WORK/pcl5.prn"
printf 'Deli M3100D: test PCL5\r\n'        >> "$WORK/pcl5.prn"
printf 'ESLI STRANICA VYSHLA - stavte ppd/Deli-M3100D-pcl5e.ppd\r\n' >> "$WORK/pcl5.prn"
printf '\f\033E' >> "$WORK/pcl5.prn"

need_gs() {
    command -v gs >/dev/null 2>&1 || {
        echo "Для заданий PCL-XL и PostScript нужен Ghostscript (dnf install ghostscript)." >&2
        return 1
    }
}

make_page_pdf() {
    gs -q -dBATCH -dNOPAUSE -sDEVICE=pdfwrite -sOutputFile="$WORK/page.pdf" -c \
       "/Courier findfont 16 scalefont setfont \
        72 760 moveto (Deli M3100D: test $1) show \
        72 730 moveto (ESLI STRANICA VYSHLA - stavte $2) show \
        showpage quit" >/dev/null 2>&1
}

if [ -z "$ONLY" ] || [ "$ONLY" = pclxl ]; then
    if need_gs && make_page_pdf "PCL-XL" "ppd/Deli-M3100D-pclxl.ppd"; then
        gs -q -dBATCH -dNOPAUSE -dSAFER -sDEVICE=pxlmono -r600 -sPAPERSIZE=a4 \
           -dFIXEDMEDIA -sOutputFile="$WORK/pclxl.prn" "$WORK/page.pdf" >/dev/null 2>&1
    fi
fi

if [ -z "$ONLY" ] || [ "$ONLY" = ps ]; then
    cat > "$WORK/ps.prn" <<'PS'
%!PS-Adobe-3.0
/Courier findfont 16 scalefont setfont
72 760 moveto (Deli M3100D: test PostScript) show
72 730 moveto (ESLI STRANICA VYSHLA - stavte ppd/Deli-M3100D-ps.ppd) show
showpage
PS
fi

if [ -n "$SAVE" ]; then
    mkdir -p "$SAVE" || exit 1
    for f in "$WORK"/*.prn; do
        [ -e "$f" ] || continue
        cp "$f" "$SAVE/" && printf 'сохранено %s/%s\n' "$SAVE" "$(basename "$f")"
    done
    printf '\nОтправить вручную:  cat %s/pcl5.prn > /dev/usb/lp0\n' "$SAVE"
    exit 0
fi

# --- куда отправлять ---------------------------------------------------------

if [ -z "$DEVICE" ]; then
    for n in /dev/usb/lp0 /dev/usb/lp1 /dev/usb/lp2; do
        [ -c "$n" ] && { DEVICE=$n; break; }
    done
fi

if [ -z "$DEVICE" ] || [ ! -c "$DEVICE" ]; then
    cat >&2 <<'TXT'
Узел /dev/usb/lpN не найден.

Обычно это значит, что устройство занял CUPS (его backend забирает USB у
модуля usblp). Остановите службу и повторите:

    systemctl stop cups
    ./tools/deli-pdl-test.sh
    systemctl start cups
TXT
    exit 1
fi

[ -w "$DEVICE" ] || { echo "Нет прав на запись в $DEVICE — запустите от root." >&2; exit 1; }

send() {  # send ИМЯ ФАЙЛ ПОЯСНЕНИЕ
    name=$1; file=$2; note=$3
    [ -s "$file" ] || { printf 'пропускаю %s: задание не собралось\n' "$name"; return 0; }
    printf '\n--- %s (%s байт) ---\n%s\n' "$name" "$(wc -c < "$file")" "$note"
    printf 'Отправить в %s? [y/N] ' "$DEVICE"
    read answer </dev/tty || answer=n
    case "$answer" in
        y|Y|д|Д) ;;
        *) echo "пропущено"; return 0 ;;
    esac
    if cat "$file" > "$DEVICE"; then
        echo "отправлено; посмотрите, что выехало из принтера"
    else
        echo "запись не удалась"
    fi
    printf 'Нажмите Enter, когда посмотрите на принтер... '
    read _ignored </dev/tty || true
}

echo "Устройство: $DEVICE"
echo "После каждой отправки смотрите на принтер: пустой лоток, одна страница"
echo "с текстом или пачка мусора — это и есть ответ."

case "${ONLY:-all}" in
    all)   set -- text pcl5 pclxl ps ;;
    *)     set -- "$ONLY" ;;
esac

for lang in "$@"; do
    case "$lang" in
        text)  send "простой текст" "$WORK/text.prn" \
                    "Если вышла страница — аппарат печатает текст как есть." ;;
        pcl5)  send "PCL5" "$WORK/pcl5.prn" \
                    "Вышла аккуратная страница -> ppd/Deli-M3100D-pcl5e.ppd" ;;
        pclxl) send "PCL-XL (PCL6)" "$WORK/pclxl.prn" \
                    "Вышла аккуратная страница -> ppd/Deli-M3100D-pclxl.ppd" ;;
        ps)    send "PostScript" "$WORK/ps.prn" \
                    "Вышла аккуратная страница -> ppd/Deli-M3100D-ps.ppd" ;;
        *)     echo "неизвестный язык: $lang" >&2 ;;
    esac
done

cat <<'TXT'

Итог:
  * страница вышла ровно на одном языке — ставьте соответствующий PPD:
        ./install-printer.sh --pdl pcl5e     (или pclxl / ps)
  * ничего не вышло ни на одном — аппарат растровый (GDI/ZjStream),
    обычный PPD ему не подходит: docs/02-printing.md, раздел «растровые»;
  * полезли листы с мусором — язык не тот, не повторяйте его;
    нажмите «Отмена» на панели МФУ и выньте бумагу.
TXT
