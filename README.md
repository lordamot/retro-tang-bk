# BK Nano

**БК-0011М с контроллером AZBK** - домашний компьютер «Электроника
БК-0011М» (К1801ВМ1 на 4 МГц, 128 КБ, БЕЙСИК и БОС в ПЗУ) вместе с
контроллером **AZBK** MAXIOL'а таким, каким его видит программа: 32 МБ
памяти с окнами, 256-цветный экран 1024x768 с тремя слоями, блиттер, два
AY, Covox, звуковой DMA, дисковый контроллер на образах с SD-карты,
EEPROM, часы - **без сети** - на **Tang Nano 20K** с платой **BL616**
(M0S Dock) рядом.  Цель - чтобы шёл **Dangerous Dave in the Haunted
Mansion** (порт grf для БК0011М+AZBK, 2025).  Сделано по образцу и на
основе [ZS-256 Nano](https://github.com/lordamot/tang-zs256), через него
[Korvet Nano](https://github.com/lordamot/tang-korvet),
[PK8000 Nano](https://github.com/lordamot/tang-pk8000) и
[UKNC Nano](https://github.com/lordamot/tang-uknc) (аппаратная часть -
Алексей Гуров, линия 2.x - Сергей Лемешев и Claude Code): оттуда взяты
связь с BL616, HDMI-кодер со звуком, контроллер SDRAM, инструменты и
метод.  Процессор - модель 1801ВМ1 Vslav'а в обёртке Sorgelig'а
(MiSTer BK0011M, GPL v2).  Поведение контроллера - по исходникам
эмулятора GID (BKemu 4.6) и описаниям на forum.maxiol.com.  Собрано так,
чтобы быть ядром [Tang Ultima](https://github.com/lordamot/tang-ultima).
Версия - в файле `VERSION`, история - в `CHANGELOG.md`, лицензия - MIT
(`LICENCE.md`).  *English below.*

## Что умеет

- К1801ВМ1 на 4 МГц (8 МГц из меню), 177716 в обе стороны, СТОП, АР2,
  прерывания 60/274/100/174.
- Память AZBK: 16 окон по 4 КБ над 32 МБ (177300-177352), трансляция
  слова 177716 БК-0011М и режимов СМК (177130), страницы ПЗУ, тени; за
  окном, которое контроллер не занял, - собственная память БК.
- Экран AZBK: 1024x768 при 60 Гц по HDMI; режимы 177230 (1/2/4/8 бит
  на точку, три слоя, растяжение, прокрутка, палитра 338 ячеек) и
  штатные 177662/177664 БК.
- Блиттер (177270/177272), два YM2149 (177172-177175 и 177714), Covox
  (177200-177212), звуковой DMA (PCM и IMA ADPCM, 44100 Гц), динамик.
- Дисковый контроллер AZ (177220-177226): устройства из образов
  `.img`/`.bkd`/`.dsk` с карты, таблица устройств, EEPROM, часы,
  файловые команды; **сети нет** - команды HOF и IP отвечают как
  контроллер без кабеля.
- Клавиатура USB как коды КОИ-7 с РУС/ЛАТ и СТР, джойстик USB на 177714.
- Меню по **F12**: четыре устройства AZ0-AZ3, сброс (он же холодный сброс AZ),
  «Hardware» (частота, джойстик, громкость), «About», «Debug»,
  сохранение настроек.

Чего нет: сети (намеренно), снимка экрана (команда 044 отвечает
ошибкой), RS-232, режима БК-0010 (ПЗУ загружаются, режим не проверен).
**AZ RAM только 8Mb!**
Состояние и порядок - в `.claude/docs/progress.md`.

## Что нужно

- Tang Nano 20K, плата BL616 (M0S Dock), SD-карта FAT32, USB-клавиатура,
  USB-джойстик по желанию.
- Семь проводов между платами - распиновка **как в исходном MiSTeryNano**,
  как у машин-родственников:

```
Tang Nano 20K   BL616
42              io10   MISO
41              io11   MOSI
56              io12   CSN
54              io13   SCK
51              io14   IRQ
GND             GND
+5              +5
```

Звук I²S - на выводах 71 (BCK), 72 (WS), 73 (DIN), 74 (разрешение
усилителя); по HDMI звук идёт сам.  Кнопка S1 - сброс.

## Карта

Папка `soft/azbk/` целиком - на карту как `/bk/` (`make card` собирает
её в `build/card/bk/`):

- `/bk/AZ.INI` - конфигурация контроллера в формате MAXIOL'а: `[ROM]`
  слоты ПЗУ, `[LOGO]` заставка, `[DISKS]` образы устройств D0..D31,
  `[BOOT]` устройство загрузки.
- `/bk/ROM/` - набор ПЗУ (AZBOOT, AZLIB, AZ337, ПЗУ БК-0011М и БК-0010,
  SETUP).
- `/bk/DISKS/` - образы дисков; сюда же кладётся образ Dangerous Dave
  (он скачивается после регистрации на hof.maxiol.com) и прописывается
  в `AZ.INI` как `Dn=`, либо выбирается в меню.
- `/bk/eeprom.dat` - настройки контроллера (их пишет SETUP).
- `/bk/bk.ini` - настройки меню («Save settings»).

Под Tang Ultima всё то же лежит в той же папке `/bk/`.

## Как прошить

**BL616** - через его загрузчик: удерживая **BOOT**, подключить USB (или
нажать **RST**), отпустить BOOT; плата появится как последовательный
порт.  Дальше либо BLDevCube (чип BL616/BL618, вкладка MCU, файл
`bin/bl616.bin`, адрес `0x00000000`, скорость 2000000, Create & Download),
либо из этого репозитория:

```sh
make flash-mcu COMX=/dev/ttyACM0
```

После прошивки нажать RST.

**Tang Nano 20K** - через openFPGALoader (или Gowin Programmer):

```sh
openFPGALoader -b tangnano20k -f bin/tang.fs     # во флеш
make flash-fpga-flash                            # то же из репозитория
```

и **выключить-включить питание**: после записи во флеш плата продолжает
работать со старой прошивкой, пока её не перезапустить.

## Как пользоваться

Включить.  AZBOOT при первом старте пищит и перезапускает машину сам
(так задумано), потом рисует экран BIOS, ждёт сеть (её нет - секунда
попыток) и грузит устройство из `[BOOT]` - по умолчанию ANDOS с
`WRKANDOS2.IMG`.  **F12** открывает меню; курсор - по пунктам,
влево/вправо - значение, пробел или Enter - выбрать, ESC - закрыть.
Раскладка: буквы, цифры, Enter, пробел - как есть; левый Ctrl - РУС,
Win - ЛАТ, правый Ctrl - СУ, Alt - АР2, Caps Lock - СТР; Esc - КТ, F1
ПОВТ, F2 ВС, F3 ГРАФ, F5 -!->, F6 ИНД СУ, F7 БЛОК РЕД, F8 ШАГ, F9 СБР
(очистка), F10 или Pause - СТОП, F11 - кнопка сброса; Ins/Del - |-->
и |<--, Home/PgUp/End/PgDn - диагональные стрелки; Alt+Win переключает
экран БК между чёрно-белым 512 и цветным 256, Alt+левый Ctrl возвращает
палитры (горячие клавиши контроллера).  Вся раскладка - картинкой:
`keyboard-ru.pdf` (`make keyboard`).

## Как собрать

```sh
make toolchain    # один раз, ~8 ГБ в tools/
make lint         # Verilator, секунды
make sim          # машина целиком; RUN_MS=4000 - до экрана BIOS (минуты)
make frames       # то же, кадры экрана в sim/out/*.ppm
make bitstream    # прошивка ПЛИС -> bin/tang.fs, с проверкой временных ограничений
make fw           # прошивка BL616 -> build/fw/bl616.bin
make soft-image   # тесты звука (soft/src/) на копии ANDOS -> build/SNDTEST.IMG
```

---

# BK Nano (English)

The **БК-0011М with an AZBK controller** - Elektronika's home computer
of 1990 (a К1801ВМ1 at 4 MHz, 128 KB, BASIC and BOS in ROM) together
with MAXIOL's **AZBK** as its software sees it: 32 MB behind a window
mapper, a 256-colour 1024x768 display with three layers, a blitter,
two AYs, a Covox, a sound DMA, a disk controller on images from the SD
card, an EEPROM, a clock - **without the network** - on a **Tang Nano
20K** with a **BL616** board (M0S Dock) beside it.  The aim is that
**Dangerous Dave in the Haunted Mansion** (grf's port for БК0011М+AZBK,
2025) runs.  Modelled on and built from
[ZS-256 Nano](https://github.com/lordamot/tang-zs256) and through it
[Korvet Nano](https://github.com/lordamot/tang-korvet),
[PK8000 Nano](https://github.com/lordamot/tang-pk8000) and
[UKNC Nano](https://github.com/lordamot/tang-uknc) (hardware by Alexey
Gurov; the 2.x line by Sergei Lemeshev and Claude Code): the BL616 link,
the HDMI encoder with audio, the SDRAM controller, the tools and the
method are taken from there.  The CPU is Vslav's 1801VM1 model in
Sorgelig's wrapper (MiSTer BK0011M, GPL v2).  The controller's
behaviour is GID's emulator (BKemu 4.6) and the descriptions on
forum.maxiol.com.  Built to be a core of
[Tang Ultima](https://github.com/lordamot/tang-ultima).  The version is
in `VERSION`, the history in `CHANGELOG.md`, the licence is MIT
(`LICENCE.md`).

## Features

- The К1801ВМ1 at 4 MHz (8 from the menu), 177716 both ways, СТОП, АР2,
  vectors 60/274/100/174.
- The AZBK memory: sixteen 4 KB windows over 32 MB (177300-177352), the
  translation of the БК-0011М's 177716 word and the SMK modes (177130),
  the ROM pages, shadows; the BK's own memory behind a window the
  controller leaves alone.
- The AZBK display: 1024x768 at 60 Hz over HDMI; the modes of 177230
  (1/2/4/8 bits a pixel, three layers, stretching, scrolling, a
  338-entry palette) and the BK's own 177662/177664.
- The blitter (177270/177272), two YM2149s (177172-177175 and 177714),
  the Covox (177200-177212), the sound DMA (PCM and IMA ADPCM at 44100
  Hz), the speaker.
- The AZ disk controller (177220-177226): units from `.img`/`.bkd`/`.dsk`
  images on the card, the units table, the EEPROM, the clock, the file
  commands; **no network** - the HOF and IP commands answer as a
  controller without a cable.
- A USB keyboard as КОИ-7 codes with РУС/ЛАТ and СТР, a USB joystick on
  177714.
- A menu on **F12**: four units AZ0-AZ3, Reset (the AZ's cold reset too),
  "Hardware" (CPU speed, joystick, volume), About, Debug, settings saved
  to the card.

Not there: the network (on purpose), the screenshot command (044 answers
an error), RS-232, the БК-0010 mode (its ROMs load, the mode is
untried).
**AZ RAM is 8Mb only!**
`.claude/docs/progress.md` has the state.

## What you need

- A Tang Nano 20K, a BL616 board (M0S Dock), a FAT32 SD card, a USB
  keyboard; a USB joystick if wanted.
- Seven wires between the boards - the **stock MiSTeryNano pinout**, as
  the siblings wire it (table above).  I²S audio on pins 71 (BCK), 72
  (WS), 73 (DIN), 74 (amplifier enable); HDMI carries the sound itself.
  S1 is reset.

## The card

The whole of `soft/azbk/` goes onto the card as `/bk/` (`make card`
stages it as `build/card/bk/`): `AZ.INI` (the controller's
configuration in MAXIOL's format: `[ROM]` slots, `[LOGO]`, `[DISKS]`
units D0..D31, `[BOOT]`), `ROM/` (the ROM set), `DISKS/` (the images;
Dangerous Dave's goes here too - it is downloaded after registering at
hof.maxiol.com - and is named in `AZ.INI` as a `Dn=` or picked in the
menu), `eeprom.dat` (the controller's settings, written by SETUP),
`bk.ini` (the menu's settings).  Under Tang Ultima it is the same `/bk/`.

## How to flash

**BL616**, through its bootloader: hold **BOOT**, plug in USB (or press
**RST**), release BOOT; the board shows up as a serial port.  Then either
BLDevCube (chip BL616/BL618, MCU tab, file `bin/bl616.bin`, address
`0x00000000`, baud 2000000, Create & Download) or, from this repository:

```sh
make flash-mcu COMX=/dev/ttyACM0
```

Press RST afterwards.

**Tang Nano 20K**, with openFPGALoader (or the Gowin Programmer):

```sh
openFPGALoader -b tangnano20k -f bin/tang.fs     # to flash
make flash-fpga-flash                            # the same from the repository
```

then **power-cycle the board**: after a write to flash it keeps running
the old bitstream until it is restarted.

## How to use it

Power on.  AZBOOT beeps and restarts the machine on its first pass
(that is how it works), then draws the BIOS screen, waits for the
network (there is none: about a second of retries) and boots the
`[BOOT]` unit - ANDOS from `WRKANDOS2.IMG` by default.  **F12** opens
the menu; cursor keys move, left and right step a value, Space or Enter
selects, ESC closes.  Keys: letters, digits, Enter and Space as they
are; Left Ctrl РУС, Win ЛАТ, Right Ctrl СУ, Alt АР2, Caps Lock СТР; Esc
КТ, F1 ПОВТ, F2 ВС, F3 ГРАФ, F5 -!->, F6 ИНД СУ, F7 БЛОК РЕД, F8 ШАГ,
F9 СБР (clear), F10 or Pause СТОП, F11 the reset key; Ins/Del |--> and
|<--, Home/PgUp/End/PgDn the diagonal arrows; Alt+Win switches the BK's
screen between its monochrome 512 and colour 256 views, Alt+Left Ctrl
puts the legacy palettes back (the controller's hotkeys).  The whole
map as a picture: `keyboard-en.pdf` (`make keyboard`).

## How to build

```sh
make toolchain    # once, ~8 GB into tools/
make lint         # Verilator, seconds
make sim          # the whole machine; RUN_MS=4000 for the BIOS screen (minutes)
make frames       # the same, with the screen as sim/out/*.ppm
make bitstream    # the FPGA bitstream -> bin/tang.fs, through the timing gate
make fw           # the BL616 firmware -> build/fw/bl616.bin
make soft-image   # the sound tests (soft/src/) on a copy of ANDOS -> build/SNDTEST.IMG
```

## Acknowledgements

MAXIOL (the AZBK, its firmware and its documentation on
forum.maxiol.com), GID (the BKemu emulator whose AZBK model this
follows), grf (Dangerous Dave for the БК), Vslav (the 1801VM1 model) and
Sorgelig (its wrapper and the MiSTer BK0011M core), MikeJ and Sorgelig
(the YM2149), Till Harbaum (MiSTeryNano, whose firmware and MCU link all
of this runs on), Alexey Gurov (UKNC Nano's hardware).  Authors of this
repository: Sergei Lemeshev and Claude Code.
