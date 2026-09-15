# Разбор неисправностей

## Печать

### Задание уходит, из принтера ничего не выезжает

Проверьте по порядку:

```sh
lpstat -t                       # очередь включена? задание не застряло?
lpstat -W completed -o          # что уже отпечаталось
tail -50 /var/log/cups/error_log
```

Если задание «completed», а бумаги нет — принтер не понял язык. Прогоните
`sudo ./tools/deli-pdl-test.sh` (см. [docs/02-printing.md](02-printing.md)).

### Очередь останавливается сама

```sh
cupsenable Deli-M3100D
lpadmin -p Deli-M3100D -o printer-error-policy=retry-job
```

Причина обычно видна в `error_log`. Частая — фильтр не запустился из-за
SELinux или прав.

### Подробный журнал CUPS

```sh
cupsctl --debug-logging
# повторить печать
tail -100 /var/log/cups/error_log
cupsctl --no-debug-logging
```

В журнале ищите строки `deli-rasterize` — фильтр сам пишет туда, с каким
устройством Ghostscript, размером бумаги и дуплексом он работает.

### SELinux

В РЕД ОС SELinux включён. Фильтру нужна правильная метка, иначе `cupsd` его
не запустит (в журнале — `Permission denied` или `filter failed`):

```sh
getenforce
restorecon -Fv /usr/lib/cups/filter/deli-rasterize
ausearch -m avc -ts recent | grep -i cups
```

`install-printer.sh` проставляет метки сам; команда выше нужна, если файл
копировали руками.

### «Ghostscript не умеет устройство pxlmono»

```sh
gs -h | tr ' ' '\n' | grep -E '^(pxl|ljet|ps2write)'
```

Если `pxlmono` в списке нет — сборка Ghostscript урезанная, ставьте PPD
PCL5e (`--pdl pcl5e`, устройство `ljet4` есть всегда). Фильтр и сам
подставит запасное устройство, но лучше выбрать PPD осознанно.

### Печатает, но криво: не тот размер, поля, дуплекс

```sh
lpoptions -p Deli-M3100D -l      # что вообще можно задать
lpoptions -d Deli-M3100D -o PageSize=A4
```

Дуплекс не сработал на PCL5 — возможно, у аппарата его нет вовсе или он
включается через PJL. Проверить, что команда вообще попала в поток:

```sh
PPD=ppd/Deli-M3100D-pcl5e.ppd filter/deli-rasterize 1 u t 1 "Duplex=DuplexNoTumble" doc.pdf \
  | head -c 40 | cat -v | grep '&l1S'
```

## Сканирование

### `scanimage -L` ничего не находит

```sh
SANE_DEBUG_DLL=3 scanimage -L 2>&1 | grep -i pantum   # backend вообще грузится?
ls -l /etc/sane.d/dll.d/pantum /etc/sane.d/pantum.conf
grep 300e /etc/sane.d/pantum.conf                     # id устройства на месте?
SANE_DEBUG_PANTUM=4 scanimage -L 2>&1 | tail -40
```

Если `dlopen` проходит, а устройство не находится — скорее всего, нет прав
на `/dev/bus/usb/...` (см. [docs/03-scanning.md](03-scanning.md), «Права
доступа») или сканер отвечает не тем протоколом.

### «Device busy»

Сканер занят другим процессом или не отпущен после прерванного скана:

```sh
fuser -v /dev/bus/usb/*/*  2>/dev/null
systemctl stop cups          # если мешает CUPS
```

Помогает и просто выключить-включить аппарат: блокировка снимается.

### Скан идёт, но картинка неправильная

Перекос, сдвиг, полосы, неверный размер области — признак того, что поля в
блоке настроек у Deli лежат не там, где у Pantum. Соберите отладку и
приложите к отчёту:

```sh
SANE_DEBUG_PANTUM=4 scanimage -d pantum --resolution 150 -o /tmp/t.pnm 2>/tmp/scan-debug.log
sudo ./tools/deli-asp-probe.py -v > /tmp/asp-probe.log
```

По этим двум файлам смещения правятся в `src/pantum.c` довольно быстро.

## Общее

### Устройство занято CUPS, и его не опросить

USB-backend CUPS забирает аппарат у модуля `usblp`, из-за чего исчезает
`/dev/usb/lp0` и перестают работать PJL-запросы:

```sh
sudo systemctl stop cups
sudo ./tools/deli-devid.py --pjl
sudo systemctl start cups
```

### Проверить, что именно видит система

```sh
sudo ./tools/deli-probe.sh -o deli-report.txt
```

Этот отчёт — то, с чего стоит начинать любой вопрос по настройке: в нём
сразу видно версии, идентификаторы, интерфейсы и состояние очередей.
