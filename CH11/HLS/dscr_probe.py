from pynq import MMIO
# Follow DPDMA channel 3's descriptor pointer into DDR and decode it.
# ZynqMP DPDMA descriptor layout (words): 0 control, 2 xfer_size,
# 3 line_size/stride, 6 addr_ext, 7 next_desc, 8 src_addr.
ch3 = MMIO(0xFD4C0000, 0x1000)
dscr = ch3.read(0x050c) or ch3.read(0x0504)
print(f"channel 3 current descriptor @ 0x{dscr:x}")

d = MMIO(dscr & ~0xFFF, 0x2000)
base = dscr & 0xFFF
w = [d.read(base + 4*i) for i in range(13)]
for i, v in enumerate(w):
    print(f"  word{i:<2} = 0x{v:08x}")

xfer   = w[2]
lsz_st = w[3]
ext    = w[6]
src    = w[8]
src_hi = (ext >> 16) & 0xFFF
full   = (src_hi << 32) | src
print()
print(f"  xfer_size      = {xfer} bytes")
print(f"  line_size      = {lsz_st & 0x3FFFF}")
print(f"  stride         = {((lsz_st >> 18) & 0x3FFF) * 16} bytes")
print(f"  SRC_ADDR       = 0x{full:x}   <-- framebuffer physical address")
