# Build the device-tree overlay.
#
#   make            -> sobel_stream.dtbo
#
# The name matters: PYNQ looks for a .dtbo whose basename matches the bitstream
# it is loading, so this has to sit next to sobel_stream.bit on the board.
#
# Needs dtc, the device tree compiler (apt install device-tree-compiler).

DTBO = sobel_stream.dtbo

all: $(DTBO)

$(DTBO): ch12.dtsi
	dtc -I dts -O dtb -o $@ $< -q

clean:
	rm -f $(DTBO)

.PHONY: all clean
