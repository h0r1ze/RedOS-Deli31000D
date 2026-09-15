#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Сколько тонера осталось и что аппарат думает о своём состоянии.

Уровень тонера по USB отдаётся ровно одним способом — асинхронными
сообщениями PJL. На прямые запросы (@PJL INFO SUPPLIES и десяток похожих)
принтер отвечает «?», поэтому драйверы обычно считают, что данных о
расходниках нет. А они есть: после @PJL USTATUS DEVICE=ON аппарат сам
присылает отчёт при каждой смене состояния, и в отчёте есть строка TONER=
с процентами.

    @PJL USTATUS DEVICE
    CODE=40021
    TONER=44

Пока ничего не происходит, устройство молчит — поэтому режим watch просит
открыть и закрыть переднюю крышку: это самая безобидная смена состояния.

    sudo ./tools/deli-toner.py            # состояние + уровень тонера
    sudo ./tools/deli-toner.py --watch    # следить за сообщениями

Требуется свободный узел /dev/usb/lpN, то есть остановленный CUPS:
    systemctl stop cups
"""

import argparse
import os
import re
import select
import sys
import time

UEL = b"\x1b%-12345X"

CODES = {
    "10001": "готов",
    "10002": "простой",
    "10003": "прогрев",
    "10005": "печатает",
    "40021": "открыта передняя крышка",
    "40600": "картридж вынут или не установлен",
    "42000": "замятие в области подачи",
}


def find_node(explicit=None):
    if explicit:
        return explicit
    if not os.path.isdir("/dev/usb"):
        return None
    for name in sorted(os.listdir("/dev/usb")):
        if name.startswith("lp"):
            return os.path.join("/dev/usb", name)
    return None


def pjl(commands):
    payload = UEL + b"@PJL\r\n"
    for cmd in commands:
        payload += cmd.encode("latin-1") + b"\r\n"
    return payload


def read_for(fd, seconds):
    chunks, deadline = [], time.monotonic() + seconds
    while True:
        left = deadline - time.monotonic()
        if left <= 0:
            break
        ready, _, _ = select.select([fd], [], [], left)
        if not ready:
            continue
        try:
            data = os.read(fd, 4096)
        except BlockingIOError:
            continue
        if not data:
            break
        chunks.append(data)
    return b"".join(chunks).decode("latin-1")


def report(text):
    """Вытаскивает CODE= и TONER= из ответа и поясняет их по-человечески."""
    shown = False
    for code in re.findall(r"CODE\s*=\s*(\d+)", text):
        print("  состояние: %s (%s)" % (code, CODES.get(code, "код неизвестен")))
        shown = True
    for toner in re.findall(r"TONER\s*=\s*(\d+)", text):
        level = int(toner)
        note = ""
        if level == 0:
            note = " — картридж не виден аппарату"
        elif level < 15:
            note = " — мало, бледная печать объясняется этим"
        print("  тонер: %d%%%s" % (level, note))
        shown = True
    return shown


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lp", help="узел usblp (по умолчанию первый найденный)")
    ap.add_argument("--watch", action="store_true",
                    help="ждать сообщений о смене состояния")
    ap.add_argument("--seconds", type=int, default=90,
                    help="сколько ждать в режиме watch (по умолчанию 90)")
    args = ap.parse_args()

    node = find_node(args.lp)
    if not node:
        print("Узел /dev/usb/lpN не найден: либо не загружен модуль usblp,")
        print("либо устройство занял CUPS. Остановите его: systemctl stop cups")
        return 1
    if not os.access(node, os.W_OK):
        print("Нет прав на %s — запустите от root." % node)
        return 1

    try:
        fd = os.open(node, os.O_RDWR | os.O_NONBLOCK)
    except OSError as exc:
        print("%s: %s" % (node, exc))
        print("Скорее всего, узел занят CUPS: systemctl stop cups")
        return 1

    try:
        print("== опрос (%s) ==" % node)
        os.write(fd, pjl(["@PJL INFO ID", "@PJL INFO STATUS", "@PJL INFO CONFIG"]) + UEL)
        answer = read_for(fd, 5)
        if not answer.strip():
            print("  принтер не ответил — возможно, он не понимает PJL")
        else:
            for line in answer.splitlines():
                line = line.strip()
                if line and not line.startswith("@PJL"):
                    print("  %s" % line)
            print()
            report(answer)

        print()
        print("== уровень тонера ==")
        os.write(fd, pjl(["@PJL USTATUS DEVICE=ON"]))
        answer = read_for(fd, 3)
        if report(answer):
            pass
        else:
            print("  В покое аппарат молчит: отчёт приходит только при смене")
            print("  состояния. Откройте и закройте переднюю крышку —")
            print("  жду %d секунд..." % (args.seconds if args.watch else 60))
            answer = read_for(fd, args.seconds if args.watch else 60)
            if not report(answer):
                print("  ничего не пришло: либо крышку не трогали, либо этот")
                print("  аппарат уровень тонера не сообщает")

        if args.watch:
            print()
            print("== слежу за сообщениями, Ctrl+C чтобы выйти ==")
            try:
                while True:
                    chunk = read_for(fd, 10)
                    if chunk.strip():
                        report(chunk)
            except KeyboardInterrupt:
                print()
    finally:
        try:
            os.write(fd, pjl(["@PJL USTATUS DEVICE=OFF"]) + UEL)
        except OSError:
            pass
        os.close(fd)

    print()
    print("Если тонера меньше 15% или картридж давно не меняли — бледная")
    print("печать объясняется расходником, а не драйвером. Вытащите картридж,")
    print("покачайте его вдоль оси несколько раз и поставьте обратно: это")
    print("временно выравнивает остаток.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
