# BK Nano - the БК-0011М with an AZBK controller on the Tang Nano 20K.
#
# Everything this needs lives under tools/, fetched by `make toolchain`;
# nothing is installed on the host.  Both halves build here: the
# bitstream through Gowin's headless shell, the firmware through the
# Bouffalo SDK; the design lints and simulates besides.
# .claude/docs/build.md says what each of these does and does not prove.
#
#   make toolchain   fetch the toolchain into tools/  (~8 GB, once)
#   make lint        Verilator over the whole design - the fast check
#   make sim         run the machine from the AZBOOT ROM (RUN_MS=1500)
#   make wave        the same, dumping a VCD, then open it (WAVE_MS=2)
#   make frames      the same, writing video frames as .ppm (PPM_FROM=1200)
#   make bitstream   build the FPGA bitstream with Gowin -> bin/tang.fs
#                    (refuses a layout that fails the timing gate)
#   make timing      the timing gate alone, on the last PnR report
#   make menu-test   the OSD menu on the host: forms, keys, layout
#   make az-test     the controller's boot on the host: AZ.INI, the ROMs over the link
#   make fw          build the BL616 firmware -> build/fw/bl616.bin
#   make soft        assemble the sound tests in soft/src/ (tools/macro11)
#   make soft-image  put them on a copy of ANDOS: build/SNDTEST.IMG
#   make keyboard    the PC-to-БК key map as keyboard-ru.pdf and keyboard-en.pdf
#   make card        say what goes onto the SD card, and stage it in build/card
#   make flash-fpga  openFPGALoader the shipped bitstream to SRAM
#   make flash-mcu   flash the firmware over UART (COMX=/dev/ttyACM0)
#   make clean       remove build/ and sim/out/

ROOT     := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
TOOLS    := $(ROOT)/tools
OSS      := $(TOOLS)/oss-cad-suite
BUILD    := $(ROOT)/build

GOWIN    := $(TOOLS)/gowin
GWSH     := $(GOWIN)/bin/gw_sh
# gw_sh ships its own Qt and its own libstdc++, and on a current Linux both
# fight the system's.  tools/fetch.sh moves the stale duplicates into
# _shadowed/; these three variables do the rest.
GWENV    := LD_LIBRARY_PATH="$(GOWIN)/lib:$(GOWIN)/bin" \
            QT_QPA_PLATFORM=offscreen \
            QT_PLUGIN_PATH="$(GOWIN)/plugins/qt"
VERILATOR:= $(OSS)/bin/verilator
GTKWAVE  := $(OSS)/bin/gtkwave
OFL      := $(OSS)/bin/openFPGALoader
BLFLASH  := $(TOOLS)/bouffalo_sdk/tools/bflb_tools/bouffalo_flash_cube/BLFlashCommand-ubuntu
PYTHON   := python3

# The design's file list comes out of the Gowin project file, so it can
# never drift from what the IDE builds.
RTL      := $(shell $(PYTHON) $(TOOLS)/srcs.py)
STUBS    := sim/stubs/gowin_ip_sim.v sim/stubs/sdram_model.v sim/stubs/sd_card_sim.v
TB       := sim/tb/tb_top.v
SIMBIN   := $(BUILD)/sim/obj/tb_top
SIMBINW  := $(BUILD)/sim/objw/tb_top_w

VFLAGS   := -Wno-fatal --timing -j 16 -O3 -CFLAGS -O2 --x-assign fast --x-initial fast

# AZBOOT reaches its "Press KT" prompt within a second of machine time.
RUN_MS   ?= 1500
PPM_MAX  ?= 4
PPM_FROM ?= 1200
WAVE_MS  ?= 2

COMX     ?= /dev/ttyACM0
BAUDRATE ?= 2000000
FW_BIN   ?= bin/bl616.bin

# The BL616 firmware: -DM0S_DOCK=1 picks the SPI pinout in mnano/spi.c
# that matches this board's wiring; CONFIG_BT_STACK_CLI=0 drops a BLE
# shell that will not build against this SDK.
FW_BOARD := bl616dk -DCMAKE_C_FLAGS=-DM0S_DOCK=1 -DCONFIG_BT_STACK_CLI=0
FW_OUT   := mnano/build/build_out/misterynano_fw_bl616.bin

.PHONY: all toolchain lint sim wave frames fw clean bitstream card soft soft-image keyboard \
        flash-fpga flash-fpga-flash flash-mcu help menu-test az-test timing palette

all: lint

help:
	@sed -n '2,24p' $(firstword $(MAKEFILE_LIST)) | sed 's/^# \?//'

#-----------------------------------------------------------------------
# Toolchain
#-----------------------------------------------------------------------
toolchain:
	$(TOOLS)/fetch.sh

$(VERILATOR):
	@echo "toolchain missing - run: make toolchain" >&2; exit 1

#-----------------------------------------------------------------------
# Lint and simulation
#-----------------------------------------------------------------------
lint: $(VERILATOR)
	$(VERILATOR) --lint-only $(VFLAGS) --top-module top $(RTL) $(STUBS)
	@echo "lint: ok"

$(SIMBIN): $(TB) $(STUBS) $(RTL) $(VERILATOR)
	@mkdir -p $(BUILD)/sim
	$(VERILATOR) --binary $(VFLAGS) -Wno-lint -Wno-style \
	  --top-module tb_top -o tb_top --Mdir $(BUILD)/sim/obj \
	  $(TB) $(STUBS) $(RTL)

$(SIMBINW): $(TB) $(STUBS) $(RTL) $(VERILATOR)
	@mkdir -p $(BUILD)/sim
	$(VERILATOR) --binary $(VFLAGS) -Wno-lint -Wno-style --trace \
	  --trace-structs --trace-max-array 256 \
	  --top-module tb_top -o tb_top_w --Mdir $(BUILD)/sim/objw \
	  $(TB) $(STUBS) $(RTL)

sim: $(SIMBIN)
	@mkdir -p sim/out
	$(SIMBIN) +RUN_MS=$(RUN_MS) $(SIMARGS)

wave: $(SIMBINW)
	@mkdir -p sim/out
	$(SIMBINW) +VCD +RUN_MS=$(WAVE_MS) $(SIMARGS)
	@ls -la sim/out/tb_top.vcd
	$(GTKWAVE) sim/out/tb_top.vcd &

# Frames as .ppm, decoded back out of the TMDS stream: 1024x768.
frames: $(SIMBIN)
	@mkdir -p sim/out
	$(SIMBIN) +VIDEO_PPM +RUN_MS=$(RUN_MS) +PPM_MAX=$(PPM_MAX) \
	  +PPM_FROM=$(PPM_FROM) $(SIMARGS)
	@ls -la sim/out/*.ppm 2>/dev/null || echo "no frames produced"

# the palette RAM's contents, regenerated from the emulator's table
palette:
	$(PYTHON) $(TOOLS)/palette.py

#-----------------------------------------------------------------------
# FPGA bitstream
#-----------------------------------------------------------------------
bitstream:
	@test -x $(GWSH) || { \
	  echo "gowin missing - run: make toolchain" >&2; exit 1; }
	$(PYTHON) $(TOOLS)/gowin_tcl.py > tang/build.tcl
	cd tang && $(GWENV) $(GWSH) build.tcl
	@$(PYTHON) $(TOOLS)/timing_check.py || { \
	  echo "bitstream NOT copied to bin/: the layout fails the timing gate" >&2; \
	  echo "(.claude/rules/timing.md; make timing to see it again)" >&2; exit 1; }
	@mkdir -p bin
	@rm -f bin/tang.fs && cp tang/impl/pnr/bk.fs bin/tang.fs
	@echo
	@echo "bitstream: bin/tang.fs"
	@ls -l bin/tang.fs
	@echo "resources and timing:"
	@grep -iE "Timing Constraints|Logic|Register|BSRAM|PLL" \
	    tang/impl/pnr/bk.rpt.txt 2>/dev/null | head -12 || true

timing:
	$(PYTHON) $(TOOLS)/timing_check.py

#-----------------------------------------------------------------------
# MCU firmware
#-----------------------------------------------------------------------
fw:
	@test -d $(TOOLS)/bouffalo_sdk || { \
	  echo "bouffalo_sdk missing - run: make toolchain" >&2; exit 1; }
	@test -x $(TOOLS)/toolchain_gcc_t-head_linux/bin/riscv64-unknown-elf-gcc || { \
	  echo "riscv toolchain missing - run: make toolchain" >&2; exit 1; }
	$(MAKE) -C mnano \
	  CROSS_COMPILE=$(TOOLS)/toolchain_gcc_t-head_linux/bin/riscv64-unknown-elf- \
	  BL_SDK_BASE=$(TOOLS)/bouffalo_sdk \
	  BOARD='$(FW_BOARD)' \
	  PATH="$(TOOLS)/cmake/bin:$(TOOLS)/bin:$$PATH"
	@mkdir -p $(BUILD)/fw bin
	@cp $(FW_OUT) $(BUILD)/fw/bl616.bin
	@echo
	@echo "firmware: build/fw/bl616.bin"
	@ls -l $(BUILD)/fw/bl616.bin

# The OSD menu on the host (mnano/menu_test.c): menu.c with its SDL host
# switch, u8g2 drawing into a bitmap, FatFs with no card.  Walks every
# form and leaves each screen under build/menu/ as text and PNG.
FATFS_SRC := $(TOOLS)/bouffalo_sdk/components/fs/fatfs
# -O0: this host's gcc 15.2 dies with an internal error at -O1 and above
# on ff.c (13 Sep 2026), and a test needs no optimiser
HOST_OPT  ?= -O0
MENU_TEST_SRC := mnano/menu_test.c mnano/menu.c \
  $(wildcard mnano/u8g2/csrc/*.c) mnano/u8g2/sys/bitmap/common/u8x8_d_bitmap.c \
  $(FATFS_SRC)/ff.c $(FATFS_SRC)/ffunicode.c

# The controller's boot on the host (mnano/az_test.c): FatFs on an
# in-memory FAT32 volume filled from soft/azbk/, az_boot() run against
# it, the ROM set checked in a model of the SDRAM.
AZ_TEST_SRC := mnano/az_test.c mnano/azbk.c $(FATFS_SRC)/ff.c $(FATFS_SRC)/ffunicode.c
az-test: $(AZ_TEST_SRC) mnano/azbk.h
	@mkdir -p $(BUILD)/menu
	@$(CC) $(HOST_OPT) -w -DSDL -Imnano -I$(FATFS_SRC) -o $(BUILD)/menu/az_test $(AZ_TEST_SRC)
	$(BUILD)/menu/az_test

menu-test: $(MENU_TEST_SRC) mnano/menu.h VERSION
	@test -d $(FATFS_SRC) || { echo "bouffalo_sdk missing - run: make toolchain" >&2; exit 1; }
	@mkdir -p $(BUILD)/menu
	rm -f $(BUILD)/menu/*.txt $(BUILD)/menu/*.png
	@$(CC) $(HOST_OPT) -w -DSDL -DCORE_VERSION='"$(shell head -1 VERSION)"' \
	  -Imnano -Imnano/u8g2/csrc -I$(FATFS_SRC) -o $(BUILD)/menu/menu_test $(MENU_TEST_SRC)
	$(BUILD)/menu/menu_test $(BUILD)/menu
	$(PYTHON) $(TOOLS)/osd_png.py $(BUILD)/menu/*.txt

#-----------------------------------------------------------------------
# The sound tests: soft/src/*.mac, one program a device, assembled with
# the macro11 that make toolchain fetches, linked as headerless ANDOS
# programs (tools/binlink.py) and put on a copy of the package's ANDOS
# disk with their load address in the directory (tools/andosput.py):
# build/SNDTEST.IMG, for the card or for +D0= in the simulation.
#-----------------------------------------------------------------------
MACRO11  := $(TOOLS)/macro11/macro11
SOFTSRC  := spktest aytest ay714 covtest dmatest memtest
SOFTBINS := $(foreach s,$(SOFTSRC),$(BUILD)/soft/$(s).bin)
SOFTIMG  := $(BUILD)/SNDTEST.IMG

soft: $(SOFTBINS)

$(BUILD)/soft/tones.mac: tools/tonegen.py
	@mkdir -p $(BUILD)/soft
	$(PYTHON) tools/tonegen.py $@

# macro11 opens an .INCLUDE relative to its working directory, so the
# sources are copied next to the generated tones.mac and assembled there.
$(BUILD)/soft/%.obj: soft/src/%.mac soft/src/bk.mac $(BUILD)/soft/tones.mac
	@test -x $(MACRO11) || { \
	  echo "macro11 missing - run: make toolchain" >&2; exit 1; }
	@mkdir -p $(BUILD)/soft
	@cp soft/src/$*.mac soft/src/bk.mac $(BUILD)/soft/
	cd $(BUILD)/soft && $(MACRO11) -o $*.obj -l $*.lst $*.mac

$(BUILD)/soft/%.bin: $(BUILD)/soft/%.obj tools/binlink.py
	$(PYTHON) tools/binlink.py $< $@

soft-image: $(SOFTIMG)

# The key map on a picture of the БК's keyboard, in both languages
# (tools/keyboard_pdf.py: Pillow only, the mapping is mnano/bk.c's).
keyboard: keyboard-ru.pdf keyboard-en.pdf
keyboard-%.pdf: tools/keyboard_pdf.py prompts/bk-keyboard.png
	$(PYTHON) tools/keyboard_pdf.py --lang $* --out $@

$(SOFTIMG): $(SOFTBINS) tools/andosput.py soft/azbk/DISKS/WRKANDOS2.IMG
	$(PYTHON) tools/andosput.py $@ --base soft/azbk/DISKS/WRKANDOS2.IMG \
	  $(foreach s,$(SOFTSRC),$(shell echo $(s) | tr a-z A-Z)=$(BUILD)/soft/$(s).bin)
	@cp $@ soft/azbk/DISKS/SNDTEST.IMG    # the package carries it, so it is kept current
	@echo "$@: type SPKTEST, AYTEST, AY714, COVTEST or DMATEST at the A> line"

#-----------------------------------------------------------------------
# The card: soft/azbk/ is the AZBK's card as the emulator ships it, and
# it goes under /bk/ on the SD card whole.
#-----------------------------------------------------------------------
card:
	@mkdir -p $(BUILD)/card/bk
	@cp -r soft/azbk/. $(BUILD)/card/bk/
	@echo
	@echo "copy build/card/bk onto the SD card (FAT32) as /bk:"
	@echo "  /bk/AZ.INI          the controller's configuration: ROMs, disks, boot unit"
	@echo "  /bk/ROM/*.ROM       the ROM set (AZBOOT, AZLIB*, AZ337, SETUP, the BK's own)"
	@echo "  /bk/DISKS/*.IMG     the disk images AZ.INI names; dave.img (the operator's copy) and"
	@echo "                      SNDTEST.IMG (the sound tests) are picked as AZ0 in the OSD"
	@echo "  /bk/eeprom.dat      the controller's settings (SETUP writes it)"
	@echo "and the OSD's Save settings writes /bk/bk.ini."
	@echo "Under ../tang-ultima the same folder is used, as /bk/."

#-----------------------------------------------------------------------
# Flashing
#-----------------------------------------------------------------------
flash-fpga:
	$(OFL) -b tangnano20k bin/tang.fs

flash-fpga-flash:
	$(OFL) -b tangnano20k -f -r bin/tang.fs

# The BL616 flashes over its own UART bootloader: hold BOOT, tap RESET,
# release BOOT, then say which port that put on the host.
flash-mcu:
	@test -x $(BLFLASH) || { \
	  echo "bouffalo_sdk missing - run: make toolchain" >&2; exit 1; }
	@test -f $(FW_BIN) || { \
	  echo "no firmware at $(FW_BIN)" >&2; exit 1; }
	@test -w $(COMX) || { \
	  echo "cannot write $(COMX) - is the board in boot mode, and are" >&2; \
	  echo "you in the 'dialout' group?  See .claude/docs/build.md." >&2; \
	  exit 1; }
	@mkdir -p $(BUILD)/flash
	@printf '[cfg]\nerase = 1\nskip_mode = 0x0, 0x0\nboot2_isp_mode = 0\n\n[FW]\nfiledir = %s\naddress = 0x000000\n' \
	  "$(abspath $(FW_BIN))" > $(BUILD)/flash/bl616.ini
	@echo "flashing $(abspath $(FW_BIN)) -> $(COMX)"
	$(BLFLASH) --interface=uart --baudrate=$(BAUDRATE) --port=$(COMX) \
	  --chipname=bl616 --config=$(BUILD)/flash/bl616.ini

clean:
	rm -rf $(BUILD) sim/out mnano/build mnano/build_out
