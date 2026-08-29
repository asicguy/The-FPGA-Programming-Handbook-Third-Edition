# Build the device-tree overlay for CH12 project 0.
#
#   make           -> camera_min.dtbo
#
# Needs the device-tree compiler. On the board it is already there; on a build
# host, `apt install device-tree-compiler`.
#
# The .dtbo must be copied to the board alongside camera_min.bit and
# camera_min.hwh, and must keep this basename -- PYNQ matches an overlay to a
# bitstream by filename.

DTC     ?= dtc
NAME    := camera_min

all: $(NAME).dtbo

$(NAME).dtbo: $(NAME).dtsi
	$(DTC) -@ -O dtb -o $@ -I dts $<

clean:
	rm -f $(NAME).dtbo

.PHONY: all clean
