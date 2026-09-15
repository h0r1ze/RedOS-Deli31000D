#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Минимальный доступ к USB через usbdevfs, без сторонних модулей.

Пакета python3-pyusb в базовой поставке РЕД ОС нет, поэтому весь обмен с
устройством идёт напрямую через ioctl на /dev/bus/usb/BBB/DDD.  Здесь только
то, что нужно диагностике: найти устройство, разобрать дескрипторы, занять
интерфейс и сделать bulk/control-обмен.
"""

import array
import ctypes
import fcntl
import os
import struct

# --- коды ioctl (linux/usbdevice_fs.h) ---------------------------------------

_IOC_NRBITS, _IOC_TYPEBITS, _IOC_SIZEBITS = 8, 8, 14
_IOC_NONE, _IOC_WRITE, _IOC_READ = 0, 1, 2


def _IOC(direction, typ, nr, size):
    return (direction << 30) | (size << 16) | (ord(typ) << 8) | nr


class _CtrlTransfer(ctypes.Structure):
    _fields_ = [
        ("bRequestType", ctypes.c_ubyte),
        ("bRequest", ctypes.c_ubyte),
        ("wValue", ctypes.c_uint16),
        ("wIndex", ctypes.c_uint16),
        ("wLength", ctypes.c_uint16),
        ("timeout", ctypes.c_uint32),
        ("data", ctypes.c_void_p),
    ]


class _BulkTransfer(ctypes.Structure):
    _fields_ = [
        ("ep", ctypes.c_uint),
        ("len", ctypes.c_uint),
        ("timeout", ctypes.c_uint),
        ("data", ctypes.c_void_p),
    ]


class _Ioctl(ctypes.Structure):
    _fields_ = [
        ("ifno", ctypes.c_int),
        ("ioctl_code", ctypes.c_int),
        ("data", ctypes.c_void_p),
    ]


USBDEVFS_CONTROL = _IOC(_IOC_READ | _IOC_WRITE, "U", 0, ctypes.sizeof(_CtrlTransfer))
USBDEVFS_BULK = _IOC(_IOC_READ | _IOC_WRITE, "U", 2, ctypes.sizeof(_BulkTransfer))
USBDEVFS_CLAIMINTERFACE = _IOC(_IOC_READ, "U", 15, 4)
USBDEVFS_RELEASEINTERFACE = _IOC(_IOC_READ, "U", 16, 4)
USBDEVFS_IOCTL = _IOC(_IOC_READ | _IOC_WRITE, "U", 18, ctypes.sizeof(_Ioctl))
USBDEVFS_DISCONNECT = _IOC(_IOC_NONE, "U", 22, 0)
USBDEVFS_CLEAR_HALT = _IOC(_IOC_READ, "U", 21, 4)

SYSFS_USB = "/sys/bus/usb/devices"


class UsbError(Exception):
    pass


# --- поиск устройства --------------------------------------------------------


def _read_attr(path):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return None


def find_devices(vid, pid):
    """Все устройства с заданными VID/PID: список словарей с путями и адресом."""
    found = []
    if not os.path.isdir(SYSFS_USB):
        return found
    for name in sorted(os.listdir(SYSFS_USB)):
        base = os.path.join(SYSFS_USB, name)
        if not os.path.exists(os.path.join(base, "idVendor")):
            continue
        if _read_attr(os.path.join(base, "idVendor")) != "%04x" % vid:
            continue
        if _read_attr(os.path.join(base, "idProduct")) != "%04x" % pid:
            continue
        busnum = _read_attr(os.path.join(base, "busnum"))
        devnum = _read_attr(os.path.join(base, "devnum"))
        if not busnum or not devnum:
            continue
        found.append(
            {
                "sysfs": base,
                "bus": int(busnum),
                "dev": int(devnum),
                "node": "/dev/bus/usb/%03d/%03d" % (int(busnum), int(devnum)),
                "manufacturer": _read_attr(os.path.join(base, "manufacturer")),
                "product": _read_attr(os.path.join(base, "product")),
                "serial": _read_attr(os.path.join(base, "serial")),
            }
        )
    return found


# --- разбор дескрипторов -----------------------------------------------------


def parse_descriptors(node):
    """Читает дескрипторы прямо из узла usbdevfs и разбирает интерфейсы.

    Возвращает (device, [interface, ...]); у каждого интерфейса есть список
    эндпоинтов с адресом и типом передачи.
    """
    with open(node, "rb") as fh:
        blob = fh.read()

    device, interfaces, current = {}, [], None
    pos = 0
    while pos + 2 <= len(blob):
        length = blob[pos]
        if length < 2 or pos + length > len(blob):
            break
        dtype = blob[pos + 1]
        chunk = blob[pos : pos + length]
        if dtype == 0x01 and length >= 18:  # device
            (device["bcdUSB"], device["bDeviceClass"], device["bDeviceSubClass"],
             device["bDeviceProtocol"], device["bMaxPacketSize0"],
             device["idVendor"], device["idProduct"]) = struct.unpack_from(
                "<HBBBBHH", chunk, 2)
        elif dtype == 0x04 and length >= 9:  # interface
            current = {
                "bInterfaceNumber": chunk[2],
                "bAlternateSetting": chunk[3],
                "bNumEndpoints": chunk[4],
                "bInterfaceClass": chunk[5],
                "bInterfaceSubClass": chunk[6],
                "bInterfaceProtocol": chunk[7],
                "endpoints": [],
            }
            interfaces.append(current)
        elif dtype == 0x05 and length >= 7 and current is not None:  # endpoint
            current["endpoints"].append(
                {
                    "bEndpointAddress": chunk[2],
                    "bmAttributes": chunk[3],
                    "wMaxPacketSize": struct.unpack_from("<H", chunk, 4)[0],
                    "direction": "in" if chunk[2] & 0x80 else "out",
                    "type": ("control", "isoc", "bulk", "interrupt")[chunk[3] & 0x03],
                }
            )
        pos += length
    return device, interfaces


def describe_interface(iface):
    cls = iface["bInterfaceClass"]
    name = {0x07: "принтер", 0xFF: "vendor-specific", 0x08: "mass storage",
            0x0B: "smart card", 0x03: "HID"}.get(cls, "класс 0x%02x" % cls)
    proto = ""
    if cls == 0x07:
        proto = {1: " (однонаправленный)", 2: " (двунаправленный)",
                 4: " (IPP-over-USB)"}.get(iface["bInterfaceProtocol"], "")
    eps = " ".join(
        "0x%02x/%s/%s" % (e["bEndpointAddress"], e["type"], e["direction"])
        for e in iface["endpoints"]
    )
    return "интерфейс %d alt %d: %02x/%02x/%02x — %s%s; эндпоинты: %s" % (
        iface["bInterfaceNumber"], iface["bAlternateSetting"],
        iface["bInterfaceClass"], iface["bInterfaceSubClass"],
        iface["bInterfaceProtocol"], name, proto, eps or "нет")


def find_vendor_interface(interfaces):
    """Первый vendor-specific интерфейс с парой bulk-эндпоинтов.

    Именно так расположен сканер у Pantum M6500 (там это интерфейс 1) — но
    номер интерфейса у перемаркированных аппаратов другой, поэтому его
    приходится искать, а не задавать константой.
    """
    for iface in interfaces:
        if iface["bInterfaceClass"] != 0xFF:
            continue
        ep_in = ep_out = None
        for ep in iface["endpoints"]:
            if ep["type"] != "bulk":
                continue
            if ep["direction"] == "in" and ep_in is None:
                ep_in = ep["bEndpointAddress"]
            elif ep["direction"] == "out" and ep_out is None:
                ep_out = ep["bEndpointAddress"]
        if ep_in is not None and ep_out is not None:
            return iface["bInterfaceNumber"], ep_in, ep_out
    return None, None, None


def find_printer_interface(interfaces):
    """Интерфейс класса 07 (принтер) и его bulk-эндпоинты."""
    for iface in interfaces:
        if iface["bInterfaceClass"] != 0x07:
            continue
        ep_in = ep_out = None
        for ep in iface["endpoints"]:
            if ep["type"] != "bulk":
                continue
            if ep["direction"] == "in" and ep_in is None:
                ep_in = ep["bEndpointAddress"]
            elif ep["direction"] == "out" and ep_out is None:
                ep_out = ep["bEndpointAddress"]
        return iface["bInterfaceNumber"], ep_in, ep_out
    return None, None, None


# --- обмен -------------------------------------------------------------------


class UsbHandle:
    def __init__(self, node):
        self.fd = os.open(node, os.O_RDWR)
        self.claimed = []

    def close(self):
        for ifno in list(self.claimed):
            try:
                self.release(ifno)
            except OSError:
                pass
        os.close(self.fd)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def claim(self, ifno, detach=False):
        if detach:
            req = _Ioctl(ifno=ifno, ioctl_code=USBDEVFS_DISCONNECT, data=None)
            try:
                fcntl.ioctl(self.fd, USBDEVFS_IOCTL, req)
            except OSError:
                pass  # драйвера на интерфейсе просто нет
        buf = array.array("I", [ifno])
        fcntl.ioctl(self.fd, USBDEVFS_CLAIMINTERFACE, buf)
        self.claimed.append(ifno)

    def release(self, ifno):
        buf = array.array("I", [ifno])
        fcntl.ioctl(self.fd, USBDEVFS_RELEASEINTERFACE, buf)
        if ifno in self.claimed:
            self.claimed.remove(ifno)

    def clear_halt(self, ep):
        buf = array.array("I", [ep])
        fcntl.ioctl(self.fd, USBDEVFS_CLEAR_HALT, buf)

    def bulk_write(self, ep, data, timeout=5000):
        buf = ctypes.create_string_buffer(bytes(data), len(data))
        req = _BulkTransfer(ep=ep, len=len(data), timeout=timeout,
                            data=ctypes.cast(buf, ctypes.c_void_p))
        return fcntl.ioctl(self.fd, USBDEVFS_BULK, req)

    def bulk_read(self, ep, length, timeout=5000):
        buf = ctypes.create_string_buffer(length)
        req = _BulkTransfer(ep=ep, len=length, timeout=timeout,
                            data=ctypes.cast(buf, ctypes.c_void_p))
        got = fcntl.ioctl(self.fd, USBDEVFS_BULK, req)
        return buf.raw[:got]

    def control(self, request_type, request, value, index, length, timeout=5000):
        buf = ctypes.create_string_buffer(length)
        req = _CtrlTransfer(bRequestType=request_type, bRequest=request,
                            wValue=value, wIndex=index, wLength=length,
                            timeout=timeout,
                            data=ctypes.cast(buf, ctypes.c_void_p))
        got = fcntl.ioctl(self.fd, USBDEVFS_CONTROL, req)
        return buf.raw[:got]
