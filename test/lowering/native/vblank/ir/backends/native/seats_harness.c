/*
 * Asks runtime/rg_seats.h its questions, a line of standard input each, all of one window's
 * gamepads. See test_native_seats.rb.
 *
 *   join ID        gamepad ID plugged in: prints the player it is
 *   leave ID       gamepad ID pulled out: prints nothing
 *   player ID      prints the player gamepad ID is, 0 for none
 *   several N      prints 1 when a game whose build seats N players (0 for none named) seats them
 *                  apart, 0 when every gamepad and key is player 1's
 *   key KEY        prints the console button scancode KEY presses for player 2, -1 for none
 *   count M...     prints how many players the masks M (up to 16) are handed to the runtime as;
 *                  the line ends with "."
 */
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include "rg_seats.h"

int main(void) {
  rg_seats seats = {0};
  char question[16];
  while (scanf("%15s", question) == 1) {
    if (strcmp(question, "join") == 0 || strcmp(question, "leave") == 0 || strcmp(question, "player") == 0) {
      uint32_t id;
      if (scanf("%" SCNu32, &id) != 1) return 1;
      if (question[0] == 'j') printf("%d\n", rg_seats_join(&seats, id));
      else if (question[0] == 'l') rg_seats_leave(&seats, id);
      else printf("%d\n", rg_seats_player(&seats, id));
    } else if (strcmp(question, "several") == 0) {
      int32_t most;
      if (scanf("%" SCNd32, &most) != 1) return 1;
      printf("%d\n", rg_seats_several_players(most));
    } else if (strcmp(question, "key") == 0) {
      int key;
      if (scanf("%d", &key) != 1) return 1;
      printf("%d\n", rg_seats_second_player_button(key));
    } else if (strcmp(question, "count") == 0) {
      uint32_t masks[16] = {0};
      int32_t n = 0;
      char word[16];
      while (scanf("%15s", word) == 1 && strcmp(word, ".") != 0 && n < 16) sscanf(word, "%" SCNu32, &masks[n++]);
      printf("%" PRId32 "\n", rg_seats_players_holding(masks, n));
    } else {
      return 1;
    }
  }
  return 0;
}
