#include "ap_int.h"
#include <stdio.h>

void leading_ones(ap_uint<8> a, ap_uint<8> &out) {
  out = 0;
  for (int i = 0; i < 8; i++) {
    if (a.range(i,i)) out = i+1;
  }
}

void number_ones(ap_uint<8> a, ap_uint<8> &out) {
  out = 0;
  for (int i = 0; i < 8; i++) {
    if (a.range(i,i)) out++;
  }
}

void project_2(ap_uint<4> pb, ap_uint<8> sw, ap_uint<8> &led) {
#pragma HLS INTERFACE ap_none port = pb
#pragma HLS INTERFACE ap_none port = sw
#pragma HLS INTERFACE ap_none port = led
#pragma HLS INTERFACE ap_ctrl_none port=return

  if (pb.range(3,3)) {
    led = sw.range(7,4) * sw.range(3,0);
  } else if (pb.range(2,2)) {
    leading_ones(sw, led);
  } else if (pb.range(1,1)) {
    number_ones(sw, led);
  } else if (pb.range(0,0)) {
    led = sw.range(7,4) + sw.range(3,0);
  } else {
    led = sw.range(7,4) - sw.range(3,0);
  }
}
