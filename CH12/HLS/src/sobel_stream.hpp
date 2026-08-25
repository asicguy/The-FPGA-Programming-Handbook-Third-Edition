#ifndef SOBEL_STREAM_HPP
#define SOBEL_STREAM_HPP

#include <ap_int.h>
#include <ap_axi_sdata.h>
#include <hls_stream.h>

// ---------------------------------------------------------------------------
// Streaming Sobel filter for the AUP-ZU3 MIPI video pipeline.
//
// CH11's filter was memory-mapped: it read a whole frame out of DDR through an
// m_axi port and wrote a whole frame back. This one sits *inside* the camera
// pipeline and never touches DDR. It is spliced between axis_channel_swap and
// pixel_pack in the `mipi` hierarchy:
//
//   csi2_rx -> subset -> demosaic -> gamma_lut -> v_proc_ss (CSC)
//           -> axis_channel_swap -> [ sobel_stream ] -> pixel_pack -> VDMA
//
// which fixes the interface: the same ap_axiu<48,1,0,0> that pixel_pack_2
// already consumes.
// ---------------------------------------------------------------------------

// Maximum supported image width in pixels. Sets the depth of the two line
// buffers, which hold *beats* (two pixels each), so the depth in words is
// MAX_WIDTH/2.
#define MAX_WIDTH 1920
#define MAX_BEATS (MAX_WIDTH / 2)

// ---------------------------------------------------------------------------
// The pixel type.
//
// 48 bits carry TWO pixels: the MIPI front end runs at two pixels per clock
// (CMN_NUM_PIXELS=2, SAMPLES_PER_CLOCK=2 through demosaic, gamma and the CSC),
// which is why the filter has to produce two Sobel results per beat rather than
// one. Pixel 0 is the left-hand pixel and lives in tdata[23:0]; pixel 1 is to
// its right in tdata[47:24].
//
// Within a pixel the byte order is B, G, R from the LSB up. That is not the
// CSC's native output -- axis_channel_swap immediately upstream remaps
//
//     tdata[47:0] = {in[39:24], in[47:40], in[15:0], in[23:16]}
//
// to produce it, because it is what PYNQ's PIXEL_BGR expects: a frame read back
// through the VDMA is a (H, W, 3) uint8 array whose channel 0 is blue, which is
// exactly why the AMD base-overlay notebook writes frame[:,:,[2,1,0]] before
// handing a frame to PIL.
//
// TUSER bit 0 is start-of-frame, asserted on the first beat of the first line.
// TLAST is end-of-line, asserted on the last beat of every line. That is the
// standard AXI4-Stream video protocol every IP in this pipeline uses.
typedef ap_axiu<48, 1, 0, 0>     video_pixel;
typedef hls::stream<video_pixel> video_stream;

// Filter modes, written to the s_axilite `mode` register. 0/1/2 keep the same
// numbering as CH11 so results are directly comparable; 3 is new and only
// makes sense for video -- it lets a notebook show the unfiltered camera.
#define MODE_GRAY   0   // BGR -> luma, replicated back across all three channels
#define MODE_SOBEL  1   // BGR -> luma -> Sobel magnitude, black one-pixel border
#define MODE_INVERT 2   // BGR -> luma -> 255 - luma
#define MODE_COLOR  3   // raw camera, forwarded untouched

// ---------------------------------------------------------------------------
// Top level.
//
// img_width  : pixels per line. MUST BE EVEN and <= MAX_WIDTH -- at two pixels
//              per beat an odd width has no representation on the bus. Both
//              modes the Pcam 5C offers (1280x720 and 1920x1080) are even.
// img_height : lines per frame.
// mode       : one of MODE_* above, latched at start-of-frame so that changing
//              it from a notebook cannot tear a frame in half.
//
// The block is free-running (ap_ctrl_none): there is no ap_start to write and
// no ap_done to poll. It processes one frame per invocation and the RTL
// restarts it immediately, which is what every other IP in this pipeline does.
//
// NOTE ON THE ARGUMENT NAMES: img_width / img_height, not width / height, for
// the same reason as CH11 -- PYNQ's Register class sets self.width in its
// constructor, so an s_axilite field literally named `width` shadows it with a
// property and printing register_map recurses to death. See CH11's
// image_filter.hpp for the full trace.
// ---------------------------------------------------------------------------
void sobel_stream(video_stream &stream_in,
                  video_stream &stream_out,
                  int           img_width,
                  int           img_height,
                  int           mode);

#endif // SOBEL_STREAM_HPP
