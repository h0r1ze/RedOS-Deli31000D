#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Проверка: говорит ли сканер МФУ на протоколе «ASP».

У Pantum M6500 сканер живёт на vendor-специфичном интерфейсе USB и общается
32-байтовыми кадрами big-endian с сигнатурой "ASP\\x01".  Протокол описан и
реализован в свободном проекте pantum-open.  Если сканер Deli отвечает на те
же кадры — значит, тот же backend поднимет и его; если нет — сканирование
придётся искать другим путём (docs/03-scanning.md).

Скрипт только опрашивает устройство: блокирует сканер, читает блок настроек,
спрашивает про автоподатчик и отпускает.  Каретка при этом не двигается,
бумага не протягивается.

Запускать от root (или дав права на /dev/bus/usb/...).
"""

import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deli_usb as usb  # noqa: E402

MAGIC = 0x41535001  # "ASP\x01"
HEADER_LEN = 32
SETTINGS_LEN = 100

CMD_LOCK = 0
CMD_UNLOCK = 1
CMD_GET_SETTINGS = 6
CMD_ADF_STATUS = 0x0F

STATUS = {
    0: "OK",
    2: "сканер занят",
    5: "нет бумаги в автоподатчике",
    6: "замятие",
    7: "замятие",
    8: "открыта крышка",
}

SOURCE = {0x100: "планшет", 0x200: "автоподатчик", 0x400: "автоподатчик, двусторонний"}


def frame(cmd, payload=b""):
    head = struct.pack(">8I", MAGIC, cmd, 0, 0, 0, len(payload), 0, 0)
    return head + payload


def parse_frame(data):
    if len(data) < HEADER_LEN:
        raise usb.UsbError("ответ короче заголовка: %d байт" % len(data))
    magic, msg, arg0, arg1, status, length, _, _ = struct.unpack_from(">8I", data, 0)
    return {"magic": magic, "msg": msg, "arg0": arg0, "arg1": arg1,
            "status": status, "length": length}


def exchange(handle, ep_out, ep_in, cmd, payload=b"", timeout=5000, want=HEADER_LEN):
    handle.bulk_write(ep_out, frame(cmd, payload), timeout=timeout)
    return handle.bulk_read(ep_in, want, timeout=timeout)


def hexdump(data, width=16):
    out = []
    for off in range(0, len(data), width):
        chunk = data[off:off + width]
        out.append("%04x  %-*s |%s|" % (
            off, width * 3, " ".join("%02x" % b for b in chunk),
            "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)))
    return "\n".join(out)


def decode_settings(block):
    words = struct.unpack(">25I", block[:SETTINGS_LEN])
    return {
        "resolution": words[3],
        "doc_source": words[14],
        "data_type": words[15],
        "window": tuple(words[16:20]),      # top left bottom right, сотые дюйма
        "max_window": tuple(words[20:24]),
        "color_type": words[24],
    }


def probe(node, detach=False, verbose=False):
    device, interfaces = usb.parse_descriptors(node)
    print("== интерфейсы устройства ==")
    for iface in interfaces:
        print("  " + usb.describe_interface(iface))

    ifno, ep_in, ep_out = usb.find_vendor_interface(interfaces)
    pifno, _, _ = usb.find_printer_interface(interfaces)
    print()
    if pifno is not None:
        print("Интерфейс принтера: %d (его занимает usblp/CUPS, не трогаем)." % pifno)
    if ifno is None:
        print("Vendor-специфичного интерфейса с парой bulk-эндпоинтов нет.")
        print("Значит, сканер по USB так не отдаётся — см. docs/03-scanning.md.")
        return 2
    print("Кандидат на сканер: интерфейс %d, bulk out 0x%02x, bulk in 0x%02x."
          % (ifno, ep_out, ep_in))
    print()

    with usb.UsbHandle(node) as handle:
        try:
            handle.claim(ifno, detach=detach)
        except OSError as exc:
            print("Не удалось занять интерфейс %d: %s" % (ifno, exc))
            print("Если он кем-то занят, попробуйте ключ --detach.")
            return 1

        # Сбрасываем всё, что могло остаться в трубе от прошлых попыток.
        while True:
            try:
                stale = handle.bulk_read(ep_in, 4096, timeout=200)
            except OSError:
                break
            if not stale:
                break
            if verbose:
                print("сброшено %d байт мусора" % len(stale))

        print("== блокировка сканера (команда 0) ==")
        try:
            reply = exchange(handle, ep_out, ep_in, CMD_LOCK)
        except OSError as exc:
            print("Обмен не состоялся: %s" % exc)
            print("Устройство не отвечает на кадры ASP — протокол другой.")
            return 2

        if verbose:
            print(hexdump(reply))
        head = parse_frame(reply)
        if head["magic"] != MAGIC:
            print("Сигнатура ответа 0x%08x, ожидалась 0x%08x (\"ASP\\x01\")."
                  % (head["magic"], MAGIC))
            print(hexdump(reply))
            print()
            print("ВЫВОД: это не протокол ASP. Смотрите docs/03-scanning.md —"
                  " понадобится разбор дампа обмена.")
            return 2

        print("Ответ: msg=%d, status=%d (%s)"
              % (head["msg"], head["status"], STATUS.get(head["status"], "код %d" % head["status"])))
        locked = head["status"] == 0
        if not locked:
            print("Сигнатура ASP совпала, но блокировку сканер не отдал.")

        settings = None
        if locked:
            print()
            print("== блок настроек (команда 6) ==")
            try:
                reply = exchange(handle, ep_out, ep_in, CMD_GET_SETTINGS)
                head = parse_frame(reply)
                block = reply[HEADER_LEN:]
                need = head["length"] or SETTINGS_LEN
                while len(block) < need:
                    block += handle.bulk_read(ep_in, need - len(block), timeout=5000)
                if verbose:
                    print(hexdump(block[:need]))
                if need >= SETTINGS_LEN:
                    settings = decode_settings(block)
                    print("  разрешение:        %d dpi" % settings["resolution"])
                    print("  источник:          0x%03x (%s)" % (
                        settings["doc_source"],
                        SOURCE.get(settings["doc_source"], "неизвестно")))
                    print("  тип данных:        %d" % settings["data_type"])
                    print("  окно сканирования: %s (сотые дюйма)" % (settings["window"],))
                    print("  максимум:          %s" % (settings["max_window"],))
                    print("  цвет:              %d (%s)" % (
                        settings["color_type"],
                        "цветной" if settings["color_type"] == 1 else "серый"))
                else:
                    print("  блок настроек длиной %d байт — не 100, как у Pantum." % need)
            except OSError as exc:
                print("  не прочитался: %s" % exc)

            print()
            print("== автоподатчик (команда 0x0f) ==")
            try:
                reply = exchange(handle, ep_out, ep_in, CMD_ADF_STATUS)
                head = parse_frame(reply)
                if head["status"] == 0:
                    print("  автоподатчик есть, бумага %s"
                          % ("заправлена" if head["arg0"] == 1 else "не заправлена"))
                else:
                    print("  автоподатчика нет (status=%d)" % head["status"])
            except OSError as exc:
                print("  не ответил: %s" % exc)

            print()
            print("== снятие блокировки (команда 1) ==")
            try:
                reply = exchange(handle, ep_out, ep_in, CMD_UNLOCK)
                head = parse_frame(reply)
                print("  status=%d" % head["status"])
            except OSError as exc:
                print("  не ответил: %s" % exc)

    print()
    print("=" * 70)
    if settings and settings["max_window"] != (0, 0, 0, 0):
        print("ВЫВОД: сканер отвечает на ASP и отдаёт осмысленный блок настроек.")
        print("Ставьте backend: ./install-scanner.sh")
    else:
        print("ВЫВОД: сигнатура ASP совпала, но настройки выглядят пустыми.")
        print("Backend всё равно стоит попробовать: ./install-scanner.sh,")
        print("а при неудаче снимите отладку SANE_DEBUG_PANTUM=4.")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vid", default="0x300e")
    ap.add_argument("--pid", default="0x10c4")
    ap.add_argument("--detach", action="store_true",
                    help="отобрать интерфейс у драйвера ядра, если он занят")
    ap.add_argument("-v", "--verbose", action="store_true", help="hex-дампы кадров")
    args = ap.parse_args()

    vid, pid = int(args.vid, 16), int(args.pid, 16)
    devices = usb.find_devices(vid, pid)
    if not devices:
        print("Устройство %04x:%04x не найдено. Проверьте lsusb и питание МФУ."
              % (vid, pid))
        return 1
    dev = devices[0]
    print("Устройство: %s %s (серийный %s) на %s"
          % (dev["manufacturer"] or "?", dev["product"] or "?",
             dev["serial"] or "?", dev["node"]))
    if not os.access(dev["node"], os.W_OK):
        print("Нет прав на %s — запустите от root." % dev["node"])
        return 1
    print()
    try:
        return probe(dev["node"], detach=args.detach, verbose=args.verbose)
    except usb.UsbError as exc:
        print("Ошибка: %s" % exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
