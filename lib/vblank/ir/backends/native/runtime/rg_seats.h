/*
 * WHICH PLAYER EACH GAMEPAD AND KEY IS, in the desktop window (rg_sdl.c). A game for more than
 * one player reads player 2, 3 and 4's buttons (`held(:left, player: 2)`), so the window gives
 * those players something to press. Only a game whose `players:` seats two or more is played this
 * way (rg_seats_several_players); any other plays as it always did, every gamepad and key player 1's,
 * so a second gamepad, or one the computer reports twice, is never a player the game does not read.
 *
 * Each gamepad is a player. A gamepad plugged in takes the lowest player nobody's gamepad has, from
 * player 1 up, and keeps that player for as long as it stays plugged in. So the first gamepad is
 * player 1, as it always was, and the second is player 2. A gamepad pulled out leaves its player
 * free, and the next one plugged in takes it: pull out player 2's gamepad and plug it in again, and
 * it is player 2 again, while player 3 stayed player 3 throughout.
 *
 * The keyboard is player 1, with the keys it has always had (and whatever the player chose). Its
 * right hand has a second, fixed set for player 2: I J K L for the pad, O for A, U for B, 7 and 9
 * for L and R, 8 for Select and 0 for Start. Those keys sit away from player 1's (the arrows, and
 * Z X A S on the left), away from the window's own hotkeys, and in the shape of the arrows and the
 * face buttons beside them. A key player 1 or a hotkey has, whether by VBlank's layout, by the game
 * (computer_keys) or by the player's settings file, stays that: player 2's set only has the keys
 * nobody else has.
 *
 * Players 3 and 4 are gamepads only. Four people round one keyboard do not fit, and many keyboards
 * cannot report more than a few keys down at once: a third set would lose presses as soon as two
 * players held a direction and a button each.
 *
 * Nothing here is SDL's, so it is tested as plain C (test_native_seats.rb). Keys are SDL scancodes,
 * USB numbers, as rg_window.h keeps them; IR::ComputerControls::SECOND_PLAYER_KEYS is the same
 * layout by name, and the test holds the two to each other.
 */
#ifndef RG_SEATS_H
#define RG_SEATS_H

#include <stdint.h>

/* As many gamepads as have a player at once. */
#define RG_SEATS_MOST 8

/* Whether a game whose build seats +most_players+ (rg_game_seats, 0 for none named) gives each
 * gamepad a player of its own and player 2 keys. */
static inline int rg_seats_several_players(int32_t most_players) { return most_players > 1; }

/* The gamepads plugged in and each one's player: +ids+ is the window's number for the gamepad,
 * and +players+ its player from 1, 0 where the place is empty. Starts zeroed. */
typedef struct {
  uint32_t ids[RG_SEATS_MOST];
  int players[RG_SEATS_MOST];
} rg_seats;

/* The player gamepad +id+ is: 0 when it has none. */
static inline int rg_seats_player(const rg_seats *seats, uint32_t id) {
  for (int i = 0; i < RG_SEATS_MOST; i++)
    if (seats->players[i] && seats->ids[i] == id) return seats->players[i];
  return 0;
}

/* Gamepad +id+ plugged in: it takes the lowest player no gamepad has, and that player is returned.
 * A gamepad already seated keeps its player. 0 when every place is taken. */
static inline int rg_seats_join(rg_seats *seats, uint32_t id) {
  int had = rg_seats_player(seats, id);
  if (had) return had;
  int player = 1;
  for (int taken = 1; taken;) {
    taken = 0;
    for (int i = 0; i < RG_SEATS_MOST; i++)
      if (seats->players[i] == player) taken = 1;
    if (taken) player++;
  }
  for (int i = 0; i < RG_SEATS_MOST; i++) {
    if (seats->players[i]) continue;
    seats->ids[i] = id;
    seats->players[i] = player;
    return player;
  }
  return 0;
}

/* Gamepad +id+ pulled out: its player is free for the next one. */
static inline void rg_seats_leave(rg_seats *seats, uint32_t id) {
  for (int i = 0; i < RG_SEATS_MOST; i++)
    if (seats->players[i] && seats->ids[i] == id) seats->players[i] = 0;
}

/* Player 2's keys: the console button (in rg_runtime.h's order: a, b, select, start, right, left,
 * up, down, r, l) each key presses, by scancode. */
static inline int rg_seats_second_player_button(int key) {
  switch (key) {
  case 18: return 0; /* O: A */
  case 24: return 1; /* U: B */
  case 37: return 2; /* 8: Select */
  case 39: return 3; /* 0: Start */
  case 15: return 4; /* L: Right */
  case 13: return 5; /* J: Left */
  case 12: return 6; /* I: Up */
  case 14: return 7; /* K: Down */
  case 38: return 8; /* 9: R */
  case 36: return 9; /* 7: L */
  default: return -1;
  }
}

/* How many players to hand the runtime: up to the last of +masks+ (+most+ of them) holding a
 * button, and at least 1. The runtime keeps a player connected once it has been handed one. */
static inline int32_t rg_seats_players_holding(const uint32_t *masks, int32_t most) {
  int32_t count = 1;
  for (int32_t player = 0; player < most; player++)
    if (masks[player]) count = player + 1;
  return count;
}

#endif
