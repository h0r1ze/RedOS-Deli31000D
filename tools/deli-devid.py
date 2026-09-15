#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Что МФУ само про себя рассказывает по USB.

Две вещи решают, каким драйвером печатать:

  * строка IEEE-1284 Device ID — поле CMD: перечисляет языки печати, которые
    аппарат понимает (PCL, PCLXL, POSTSCRIPT, ZJS, PJL ...);
  * ответы на запросы PJL — модель, состояние, объём памяти.

Скрипт читает первое из sysfs (а если usblp не подключён — управляющим
запросом GET_DEVICE_ID) и по желанию задаёт вторые.
"""

import argparse
import os
import select
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deli_usb as usb  # noqa: E402  (рядом с этим файлом)

UEL = b"\x1b%-12345X"


def device_id_from_sysfs():
    """Строка Device ID через usblp: /sys/class/usbmisc/lpN/device/ieee1284_id."""
    results = []
    base = "/sys/class/usbmisc"
    if not os.path.isdir(base):
        return results
    for name in sorted(os.listdir(base)):
        if not name.startswith("lp"):
            continue
        path = os.path.join(base, name, "device", "ieee1284_id")
        try:
            with open(path) as fh:
                results.append((name, fh.read().strip()))
        except OSError:
            continue
    return results


def device_id_from_usb(node, ifno, detach=False):
    """Управляющий запрос GET_DEVICE_ID (класс принтера, bRequest 0)."""
    with usb.UsbHandle(node) as handle:
        handle.claim(ifno, detach=detach)
        raw = handle.control(0xA1, 0, 0, ifno << 8, 1024)
    if len(raw) < 2:
        raise usb.UsbError("устройство вернуло %d байт" % len(raw))
    length = (raw[0] << 8) | raw[1]
    return raw[2:length].decode("latin-1").strip()


def parse_device_id(text):
    fields = {}
    for part in text.split(";"):
        if ":" not in part:
            continue
        key, value = part.split(":", 1)
        fields[key.strip().upper()] = value.strip()
    return fields


def verdict(fields):
    """Вывод о том, каким путём печатать, по полю CMD:."""
    cmd = fields.get("CMD") or fields.get("COMMAND SET") or ""
    langs = [x.strip().upper() for x in cmd.replace(",", " ").split()]
    lines = []
    if not langs:
        return ["CMD: пустое — по строке Device ID язык печати определить нельзя,"
                "  проверяйте практикой: tools/deli-pdl-test.sh"]
    lines.append("CMD: %s" % cmd)
    if any(x.startswith("PCLXL") or x == "PCL6" for x in langs):
        lines.append("  -> аппарат принимает PCL-XL: ppd/Deli-M3100D-pclxl.ppd")
    if any(x == "PCL" or x.startswith("PCL5") for x in langs):
        lines.append("  -> аппарат принимает PCL5: ppd/Deli-M3100D-pcl5e.ppd")
    if any("POSTSCRIPT" in x or x == "PS" for x in langs):
        lines.append("  -> аппарат принимает PostScript: ppd/Deli-M3100D-ps.ppd")
    if any(x in ("ZJS", "ZJSTREAM", "GDI", "PL", "URF") for x in langs):
        lines.append("  -> растровый (ZjStream/GDI) язык: обычным PPD не обойтись,"
                     " смотрите docs/02-printing.md, раздел про ZjStream")
    if not any(k in cmd.upper() for k in ("PCL", "POSTSCRIPT", "PS", "ZJS", "GDI", "URF")):
        lines.append("  -> знакомых языков в списке нет; см. docs/02-printing.md")
    return lines


def pjl_query(path, commands, timeout=4.0):
    """Отправляет запросы PJL в /dev/usb/lpN и собирает ответ."""
    payload = UEL + b"@PJL\r\n"
    for cmd in commands:
        payload += cmd.encode("latin-1") + b"\r\n"
    payload += UEL

    fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
    try:
        os.write(fd, payload)
        chunks, deadline = [], timeout
        while True:
            ready, _, _ = select.select([fd], [], [], deadline)
            if not ready:
                break
            try:
                data = os.read(fd, 4096)
            except BlockingIOError:
                break
            if not data:
                break
            chunks.append(data)
            deadline = 1.0  # первый ответ ждём дольше, продолжение — коротко
        return b"".join(chunks).decode("latin-1")
    finally:
        os.close(fd)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vid", default="0x300e", help="USB vendor id (по умолчанию 0x300e)")
    ap.add_argument("--pid", default="0x10c4", help="USB product id (по умолчанию 0x10c4)")
    ap.add_argument("--pjl", action="store_true", help="дополнительно опросить принтер по PJL")
    ap.add_argument("--lp", help="узел usblp для PJL (по умолчанию первый найденный)")
    ap.add_argument("--detach", action="store_true",
                    help="отобрать интерфейс у usblp, если он занят "
                         "(очередь CUPS на это время лучше остановить)")
    args = ap.parse_args()

    vid, pid = int(args.vid, 16), int(args.pid, 16)

    print("== IEEE-1284 Device ID ==")
    text = None
    for name, value in device_id_from_sysfs():
        print("%s: %s" % (name, value))
        if ("MFG:DELI" in value.upper() or "DELI" in value.upper()) and text is None:
            text = value
    if text is None:
        devices = usb.find_devices(vid, pid)
        if not devices:
            print("Устройство %04x:%04x не найдено." % (vid, pid))
            return 1
        node = devices[0]["node"]
        _, interfaces = usb.parse_descriptors(node)
        ifno, _, _ = usb.find_printer_interface(interfaces)
        if ifno is None:
            print("У устройства нет интерфейса класса принтера.")
            return 1
        try:
            text = device_id_from_usb(node, ifno, detach=args.detach)
            print("через GET_DEVICE_ID (интерфейс %d): %s" % (ifno, text))
        except OSError as exc:
            print("GET_DEVICE_ID не удался: %s" % exc)
            print("Интерфейс, скорее всего, занят usblp или CUPS. Попробуйте:")
            print("  systemctl stop cups && %s --detach" % sys.argv[0])
            return 1

    fields = parse_device_id(text)
    print()
    print("== разбор ==")
    for key in ("MFG", "MDL", "CMD", "CLS", "DES", "SN"):
        if key in fields:
            print("%-4s %s" % (key, fields[key]))
    print()
    for line in verdict(fields):
        print(line)

    if args.pjl:
        path = args.lp
        if not path:
            candidates = [os.path.join("/dev/usb", n) for n in sorted(os.listdir("/dev/usb"))
                          if n.startswith("lp")] if os.path.isdir("/dev/usb") else []
            path = candidates[0] if candidates else None
        print()
        print("== PJL ==")
        if not path:
            print("Узел /dev/usb/lpN не найден: модуль usblp не загружен "
                  "или устройство занято CUPS.")
        else:
            try:
                answer = pjl_query(path, ["@PJL INFO ID", "@PJL INFO CONFIG",
                                          "@PJL INFO STATUS", "@PJL INFO VARIABLES"])
                print(answer.strip() or "(принтер ничего не ответил)")
            except OSError as exc:
                print("%s: %s" % (path, exc))
                print("Если устройство держит CUPS — systemctl stop cups и повторить.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
