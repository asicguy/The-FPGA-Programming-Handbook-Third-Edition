#include <cstdlib>
#include "ap_int.h"

void project_2(ap_uint<4> pb, ap_uint<8> sw, ap_uint<8> &led);

int main () {
  //Establish an initial return value. 0 = success
  int ret=0;

  ap_uint<8> led;
  ap_uint<4> pb;
  ap_uint<8> sw;
  ap_uint<8> check;
  // Call the top-level function multiple times, passing input stimuli as needed.
  for(int j=0; j < 5; j++) {
    pb = 0;
    if (j == 1) {
      pb.range(0,0) = 1;
      break;
    } else if (j == 2) {
      pb.range(1,1) = 1;
      break;
    } else if (j == 3) {
      pb.range(2,2) = 1;
      break;
    } else if (j == 4) {
      pb.range(3,3) = 1;
      break;
    }

    for(ap_uint<9> i=0; i < 256; i++){
      sw = i;
      project_2(pb, sw, led);
      check = 0;
      if (pb == 0) {
        check = sw.range(7,4) - sw.range(3,0);
      } else if (pb == 1) {
        for (int i = 0; i < 8; i++) {
          check += led.range(i,i);
        }
      } else if (pb == 2) {
        for (int i = 0; i < 8; i++) {
          check += led.range(i,i);
        }
      } else if (pb == 4) {
        for (int i = 0; i < 8; i++) {
          if (led.range(i,i)) check = i+1;
        }
      } else if (pb == 8) {
        check = sw.range(7,4) + sw.range(3,0);
      }
    }
    if (check != led) {
      ret = 1;
      printf("Test failed  !!!\n");
      std::cout << "PB = " << pb << ", SW = " << sw << ", LED = " << led << ", EXP = " << check << std::endl;
      return ret;
    }
  }
  printf("Test passed !\n");
  return ret;
}
