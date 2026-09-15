#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Ставит SANE-backend для сканера Deli M3100D.
#
# Берёт свободный backend pantum-open (он разобран из протокола Pantum
# M6500), накладывает патч из sane/patches — идентификатор Deli и поиск
# нужного USB-интерфейса — собирает и раскладывает по системе.
#
#   ./install-scanner.sh                 # скачать исходники и поставить
#   ./install-scanner.sh --source DIR    # взять уже скачанное дерево
#   ./install-scanner.sh --no-probe      # не проверять протокол заранее
#   ./install-scanner.sh --uninstall
#
# Ключи:
#   --source DIR   каталог с исходниками pantum-open (без сети)
#   --no-probe     пропустить tools/deli-asp-probe.py
#   --force        ставить, даже если проверка протокола провалилась
#   --keep-build   не удалять каталог сборки (для разбирательств)
#   --uninstall    убрать backend, конфиг и правило udev

set -u

UPSTREAM=https://github.com/loss-and-quick/pantum-open
COMMIT=cd25c1d4e97447af162e24af5aa931fd31c85903
SOURCE=""
PROBE=yes
FORCE=no
KEEP=no
UNINSTALL=no
HERE=$(cd "$(dirname "$0")" && pwd)

while [ $# -gt 0 ]; do
    case "$1" in
        --source) SOURCE=$2; shift 2 ;;
        --no-probe) PROBE=no; shift ;;
        --force) FORCE=yes; shift ;;
        --keep-build) KEEP=yes; shift ;;
        --uninstall) UNINSTALL=yes; shift ;;
        -h|--help) awk 'NR>2 && /^#/ { sub(/^# ?/, ""); print; next } NR>2 { exit }' "$0"; exit 0 ;;
        *) echo "неизвестный ключ: $1" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" = 0 ] || { echo "Запускать от root." >&2; exit 1; }

# Куда система кладёт backends SANE: рядом с уже установленными.
find_sane_dir() {
    for f in /usr/lib64/sane /usr/lib/x86_64-linux-gnu/sane /usr/lib/sane \
             /usr/local/lib64/sane /usr/local/lib/sane; do
        [ -d "$f" ] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

SANEDIR=$(find_sane_dir) || SANEDIR=/usr/lib64/sane

if [ "$UNINSTALL" = yes ]; then
    rm -f "$SANEDIR"/libsane-pantum.so "$SANEDIR"/libsane-pantum.so.1 \
          /etc/sane.d/pantum.conf /etc/sane.d/dll.d/pantum \
          /etc/udev/rules.d/99-deli-m3100d.rules \
          /etc/udev/rules.d/60-pantum-open.rules
    sed -i '/^pantum$/d' /etc/sane.d/dll.conf 2>/dev/null
    udevadm control --reload 2>/dev/null
    echo "backend, конфиг и правила удалены"
    exit 0
fi

# --- 1. отвечает ли сканер на протокол ASP -----------------------------------

if [ "$PROBE" = yes ]; then
    echo "== проверяю протокол сканера =="
    if python3 "$HERE/tools/deli-asp-probe.py"; then
        :
    else
        rc=$?
        echo
        if [ "$FORCE" = yes ]; then
            echo "Проверка не прошла (код $rc), но указан --force — продолжаю."
        else
            echo "Сканер не ответил так, как ожидает backend (код $rc)."
            echo "Ставить его сейчас смысла мало — сначала docs/03-scanning.md."
            echo "Если всё же хотите попробовать: $0 --force"
            exit $rc
        fi
    fi
    echo
fi

# --- 2. чем собирать ---------------------------------------------------------

missing=""
for tool in cmake make gcc git; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
[ -f /usr/include/sane/sane.h ] || missing="$missing sane-backends-devel"
if ! pkg-config --exists libusb-1.0 2>/dev/null; then
    [ -f /usr/include/libusb-1.0/libusb.h ] || missing="$missing libusbx-devel"
fi
if [ -n "$missing" ]; then
    echo "Не хватает для сборки:$missing" >&2
    echo "В РЕД ОС ставится так:" >&2
    echo "  dnf install -y cmake make gcc git sane-backends-devel libusbx-devel" >&2
    exit 1
fi

# --- 3. исходники ------------------------------------------------------------

BUILD=$(mktemp -d /var/tmp/deli-scanner.XXXXXX) || exit 1
cleanup() {
    if [ "$KEEP" = yes ]; then
        echo "каталог сборки оставлен: $BUILD"
    else
        rm -rf "$BUILD"
    fi
}
trap cleanup EXIT HUP INT TERM

TREE=$BUILD/pantum-open
if [ -n "$SOURCE" ]; then
    echo "== беру исходники из $SOURCE =="
    cp -a "$SOURCE" "$TREE" || exit 1
    # На случай, если патч уже наложен в исходном дереве.
    if grep -q '0x300e' "$TREE/etc/sane.d/pantum.conf" 2>/dev/null; then
        PATCHED=yes
    else
        PATCHED=no
    fi
else
    echo "== скачиваю $UPSTREAM =="
    git clone --quiet "$UPSTREAM" "$TREE" || {
        echo "Не скачалось. Возьмите дерево на машине с сетью и укажите --source." >&2
        exit 1
    }
    ( cd "$TREE" && git checkout --quiet "$COMMIT" ) || exit 1
    PATCHED=no
fi

if [ "$PATCHED" = no ]; then
    echo "== накладываю патч для Deli M3100D =="
    ( cd "$TREE" && git apply "$HERE/sane/patches/0001-deli-m3100d.patch" ) || {
        echo "Патч не лёг. Проверьте, что дерево соответствует коммиту $COMMIT." >&2
        exit 1
    }
fi

# --- 4. сборка ---------------------------------------------------------------

echo "== собираю backend =="
cmake -S "$TREE" -B "$BUILD/build" \
      -DCMAKE_BUILD_TYPE=Release \
      -DPANTUM_BUILD_FILTER=OFF \
      -DCMAKE_INSTALL_PREFIX="$BUILD/stage" >"$BUILD/cmake.log" 2>&1 || {
    echo "cmake не отработал, подробности в $BUILD/cmake.log" >&2
    KEEP=yes
    exit 1
}
cmake --build "$BUILD/build" >>"$BUILD/cmake.log" 2>&1 || {
    echo "сборка не удалась, подробности в $BUILD/cmake.log" >&2
    KEEP=yes
    exit 1
}
cmake --install "$BUILD/build" >>"$BUILD/cmake.log" 2>&1 || {
    echo "установка в промежуточный каталог не удалась, см. $BUILD/cmake.log" >&2
    KEEP=yes
    exit 1
}

# --- 5. раскладка по системе -------------------------------------------------

echo "== ставлю в систему =="
install -d "$SANEDIR" /etc/sane.d/dll.d
install -m 0755 "$BUILD/stage/lib/sane/libsane-pantum.so.1" "$SANEDIR/libsane-pantum.so.1"
ln -sf libsane-pantum.so.1 "$SANEDIR/libsane-pantum.so"
install -m 0644 "$BUILD/stage/etc/sane.d/pantum.conf" /etc/sane.d/pantum.conf
install -m 0644 "$BUILD/stage/etc/sane.d/dll.d/pantum" /etc/sane.d/dll.d/pantum

# Старые sane-backends каталог dll.d не читают — подстрахуемся dll.conf.
if [ -f /etc/sane.d/dll.conf ] && ! grep -qx 'pantum' /etc/sane.d/dll.conf; then
    printf 'pantum\n' >> /etc/sane.d/dll.conf
fi

install -m 0644 "$HERE/sane/99-deli-m3100d.rules" /etc/udev/rules.d/99-deli-m3100d.rules
udevadm control --reload 2>/dev/null
udevadm trigger --subsystem-match=usb 2>/dev/null

if command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$SANEDIR/libsane-pantum.so.1" /etc/sane.d/pantum.conf 2>/dev/null
fi

getent group scanner >/dev/null 2>&1 || groupadd -r scanner

# --- 6. проверка -------------------------------------------------------------

echo
echo "== что видит SANE =="
scanimage -L 2>&1 | sed 's/^/  /'
echo
cat <<'TXT'
Если устройство в списке — пробуйте:
  scanimage -d pantum --mode Gray --resolution 300 --format=png -o /tmp/scan.png

Если списка нет или пишет «No scanners were identified»:
  * пользователю нужны права: usermod -aG scanner,lp ИМЯ_ПОЛЬЗОВАТЕЛЯ,
    затем перелогиниться;
  * отладка: SANE_DEBUG_PANTUM=4 scanimage -L 2>&1 | tail -40
  * дальше — docs/03-scanning.md и docs/04-troubleshooting.md.
TXT
