/*
 * Asks runtime/rg_pause.h its two questions, a line of standard input each. See test_native_pause.rb.
 *
 *   owed OWED EVENT   how many drawings of the window are owed after a time round the pause's wait,
 *                     OWED being the number before it and EVENT 1 when the window had an event
 *
 *   wait OWED OPEN OWES LEFT_NS
 *                     how many milliseconds the pause sleeps waiting for an event: OWED drawings
 *                     owed, OPEN 1 when the menu or a window over the picture is open, OWES 1 when
 *                     a file is owed, and LEFT_NS nanoseconds of the frame left
 */
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include "rg_pause.h"

int main(void) {
  char question[16];
  while (scanf("%15s", question) == 1) {
    if (strcmp(question, "owed") == 0) {
      int owed, event;
      if (scanf("%d %d", &owed, &event) != 2) return 1;
      printf("%d\n", rg_pause_drawings_owed(owed, event));
    } else if (strcmp(question, "wait") == 0) {
      int owed, open, owes;
      uint64_t left;
      if (scanf("%d %d %d %" SCNu64, &owed, &open, &owes, &left) != 4) return 1;
      printf("%d\n", rg_pause_wait_ms(owed, open, owes, left));
    } else {
      return 1;
    }
  }
  return 0;
}
