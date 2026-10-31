/*
 * WHAT A PAUSED GAME'S WINDOW DOES WHILE IT WAITS. Nothing in a paused game moves, so the window
 * has nothing new to show until the player does something: it sleeps until the window has an event,
 * and the player's next key, click or mouse movement wakes it at once. Dear ImGui settles a hover or
 * a click over several frames, so a few frames are drawn after each event, one a frame while they
 * last. The sleep has a timeout so that a file still owed is written, and a pause with nothing to
 * write sleeps for a good while at a time: a paused game costs the computer next to nothing.
 *
 * This is a file of its own, with nothing of SDL in it, so the policy can be tested as plain
 * arithmetic (test_native_pause.rb).
 */
#ifndef RG_PAUSE_H
#define RG_PAUSE_H

#include <stdint.h>

/* How long a pause with nothing owed sleeps before looking again, and how many frames are drawn
 * after an event. */
#define RG_PAUSE_IDLE_MS 100
#define RG_PAUSE_FRAMES_TO_SETTLE 4

/* How many drawings of the window are still owed, +owed+ being the number before this time round
 * and +event_arrived+ whether the window had any event since the last. */
static inline int rg_pause_drawings_owed(int owed, int event_arrived) {
  return event_arrived ? RG_PAUSE_FRAMES_TO_SETTLE : owed;
}

/* How many milliseconds to sleep waiting for an event. A window being drawn (a drawing still owed,
 * or a menu or window open over the picture, which are drawn every frame) or a file owed (which is
 * counted in frames) sleeps until a frame is over, +frame_left_ns+ from now, rounded up to a whole
 * millisecond; anything else sleeps for the idle time. */
static inline int rg_pause_wait_ms(int drawings_owed, int window_open, int owes_a_file, uint64_t frame_left_ns) {
  if (drawings_owed <= 0 && !window_open && !owes_a_file) return RG_PAUSE_IDLE_MS;
  return (int)((frame_left_ns + 999999u) / 1000000u);
}

#endif
