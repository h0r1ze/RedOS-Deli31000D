# Шаг 2. Печать

## Как собрана цепочка

```
приложение -> CUPS -> ... -> pdftopdf -> deli-rasterize -> Ghostscript -> принтер
```

CUPS приводит любое задание к PDF и передаёт его фильтру `deli-rasterize`
(строка `*cupsFilter: "application/vnd.cups-pdf 0 deli-rasterize"` в PPD).
Фильтр читает из PPD строку `*DeliGSDevice`, запускает Ghostscript с этим
устройством и отдаёт готовый поток на stdout — дальше его забирает
USB-backend CUPS.

Отсюда два следствия. Во-первых, чтобы добавить ещё один язык печати,
достаточно нового PPD с другим `*DeliGSDevice` — код трогать не нужно.
Во-вторых, всю цепочку можно прогнать руками, без очереди печати (см. ниже).

## Установка

```sh
sudo ./install-printer.sh              # PPD выбирается по строке Device ID
sudo ./install-printer.sh --pdl pcl5e  # или задать вручную
```

Скрипт кладёт фильтр в каталог фильтров CUPS, PPD — в
`/usr/share/cups/model`, проставляет метки SELinux (`restorecon`), проверяет
PPD через `cupstestppd` и создаёт очередь `Deli-M3100D`. Адрес устройства
берётся из `lpinfo -v`; если не нашёлся — передайте `--uri`.

Проверка:

```sh
lp -d Deli-M3100D /usr/share/cups/data/testprint
lpstat -t
```

## Если язык неизвестен

Строка `CMD:` не всегда говорит правду, а иногда её и нет. Тогда — опытным
путём:

```sh
sudo systemctl stop cups
sudo ./tools/deli-pdl-test.sh
sudo systemctl start cups
```

Скрипт по очереди предлагает отправить четыре коротких задания: простой
текст, PCL5, PCL-XL и PostScript. Каждое — одна страница с надписью, какой
PPD ставить, если эта страница вышла. Смотрите на принтер:

* **вышла аккуратная страница** — язык найден, ставьте названный PPD;
* **ничего не вышло** — этот язык аппарат не понял (это нормально,
  переходите к следующему);
* **полезли листы с мусором** — язык не тот; нажмите «Отмена» на панели.

## Если аппарат растровый (GDI / ZjStream)

Так бывает у недорогих лазерных МФУ: процессора языка печати внутри нет,
хост присылает готовый растр. Тогда ни один PPD из `ppd/` не подойдёт — ни
одно из заданий `deli-pdl-test.sh` не напечатается, а в `CMD:` будет что-то
вроде `ZJS`, `GDI` или `PL`.

Что делать:

1. **Проверить IPP-over-USB.** Если в карте интерфейсов есть `07/01/04`,
   поставьте `ipp-usb` — печать и сканирование заработают без драйверов
   вовсе. Это самый быстрый путь, проверьте его первым.

2. **Попробовать фильтр ZjStream от pantum-open.** Родственные Pantum
   M6500 принимают ZjStream с картинкой JBIG1 внутри, и в проекте
   [pantum-open](https://github.com/loss-and-quick/pantum-open) есть готовый
   фильтр `rastertopantum` с описанием формата в `notes/print-protocol.md`:

   ```sh
   dnf install -y cmake gcc make cups-devel jbigkit-devel
   git clone https://github.com/loss-and-quick/pantum-open
   cd pantum-open
   cmake -S . -B build -DPANTUM_BUILD_BACKEND=OFF -DCMAKE_INSTALL_PREFIX=/usr
   cmake --build build && sudo cmake --install build
   sudo lpadmin -p Deli-ZJS -v "$(lpinfo -v | sed -n 's/^direct  *//p' | grep -i deli)" \
        -P /usr/share/cups/model/Pantum-M6500-open.ppd -E
   ```

   Совпадёт формат — страница напечатается; нет — в лотке останется пусто
   или выедет мусор, тогда очередь просто удалите (`lpadmin -x Deli-ZJS`).

3. **Посмотреть foo2zjs.** Пакет `foo2zjs` умеет несколько разновидностей
   ZjStream; его `foo2zjs-wrapper` стоит попробовать с PPD «Generic ZjStream
   Printer» из foomatic. Шанс небольшой, но проверка дешёвая.

4. **Снять дамп обмена.** Если ничего не подошло — печать с машины с
   Windows-драйвером через `usbmon`/Wireshark даст реальный поток, по
   которому видно и язык, и обвязку PJL. В pantum-open для этого есть
   `proto/usbshim.c` (перехват без root) и `proto/zjs_dump.py` (разбор
   ZjStream по чанкам).

## Отладка без очереди печати

Фильтр — обычный скрипт, его можно запускать руками:

```sh
PPD=ppd/Deli-M3100D-pclxl.ppd \
  filter/deli-rasterize 1 user test 1 "PageSize=A4 Duplex=DuplexNoTumble" doc.pdf > out.prn
file out.prn
head -c 60 out.prn | cat -v          # видно, каким языком собрано
sudo sh -c 'cat out.prn > /dev/usb/lp0'   # при остановленном CUPS
```

Если задание печатается так, а через очередь — нет, дело не в языке, а в
CUPS: права, SELinux или backend. Смотрите
[docs/04-troubleshooting.md](04-troubleshooting.md).

## Настройки задания

| опция | значения |
|-------|----------|
| `PageSize` | A4, Letter, Legal, A5, A6, B5 (JIS), Executive, `Custom.ШxВ` |
| `Resolution` | 300dpi, 600dpi, 1200dpi |
| `Duplex` | None, DuplexNoTumble (длинная сторона), DuplexTumble (короткая) |

```sh
lp -d Deli-M3100D -o PageSize=A4 -o Duplex=DuplexNoTumble -o Resolution=600dpi файл.pdf
lpoptions -d Deli-M3100D -o PageSize=A4          # значения по умолчанию
```

Дуплекс для PCL-XL включает сам Ghostscript (`-dDuplex`), для PCL5 это
делает фильтр: `ljet4` команду дуплекса не выдаёт, поэтому `ESC&l1S` (или
`ESC&l2S`) вставляется в поток сразу после сброса `ESC E`. Если аппарат
двусторонней печати не умеет, команда просто игнорируется.

Копии размножает `pdftopdf` выше по цепочке — фильтр их намеренно не
трогает, иначе каждая копия печаталась бы дважды.
