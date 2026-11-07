/* What a game with a light calls (rg_light.c). */
#ifndef RG_LIGHT_H
#define RG_LIGHT_H

#include <stdint.h>

/* A LIGHT darkens the picture everywhere outside one span of each row, as it is shown
 * (Reference#work_out_shade, Framebuffer#shade_outside). In the gap between frames,
 * rg_screen_work_out_shade asks the game where each row's span is, by calling rg_game_shade_span
 * with one row of the screen in mind, and then how dark the rest goes, by calling
 * rg_game_shade_amount:
 *
 *   row = rg_shade_line(); rg_shade_left(left); rg_shade_right(right);    rg_shade_darkness(amount);
 *
 * The span runs from left up to but not including right; a left past its right comes round the
 * edge of the screen. The amount is out of 100.
 *
 * A game whose light takes turns with the scenes it is off in calls rg_shade_switch as each frame
 * ends, before it is shown, with whether the scene that just ran has it on (1) or off (0): off
 * darkens nothing from that picture on, and on waits for the light worked out after it. */
void rg_screen_work_out_shade(void);
int32_t rg_shade_line(void);
void rg_shade_left(int32_t left);
void rg_shade_right(int32_t right);
void rg_shade_darkness(int32_t amount);
void rg_shade_switch(int32_t on);

#endif
