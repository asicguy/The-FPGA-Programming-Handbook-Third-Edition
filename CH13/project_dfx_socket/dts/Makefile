# Build the device-tree overlay for CH13.
#
#   make           -> dfx_socket.dtbo
#
# Needs the device-tree compiler. On the board it is already there; on a build
# host, `apt install device-tree-compiler`.
#
# The .dtbo must be copied to the board alongside dfx_socket.bit and
# dfx_socket.hwh, and must keep this basename -- PYNQ matches an overlay to a
# bitstream by filename.

DTC     ?= dtc
NAME    := dfx_socket

all: $(NAME).dtbo

$(NAME).dtbo: $(NAME).dtsi
	$(DTC) -@ -O dtb -o $@ -I dts $<

clean:
	rm -f $(NAME).dtbo

.PHONY: all clean
