/* What a game with a fade or a tint calls (rg_fades.c). */
#ifndef RG_FADES_H
#define RG_FADES_H

#include <stdint.h>

/* A fade toward black (0) or white (1), in sixteenths of the display or, when +walked+, in
 * 256ths of a walk through the colors (see Backends::FadeSteps). */
void rg_screen_fade(int32_t toward_white, int32_t steps, int32_t walked);
/* The same fade PLACED IN THE STACK: what is behind the layer it names fades, and that layer and
 * everything in front of it are left as drawn. +layer_place+ is how far forward that layer is
 * among the layers the game declared, or RG_NO_LAYER when it is none of them, and then
 * everything fades. Each thing gives how far forward such a layer can be and still leave it as
 * drawn (RG_BG_FADE_PLACE, rg_game_sprite_fade_places). */
void rg_screen_fade_under(int32_t layer_place, int32_t toward_white, int32_t steps, int32_t walked);
/* The same fade HELD TO A RECTANGLE: inside it (+reaches+ RG_FADE_INSIDE) or everywhere but it
 * (RG_FADE_OUTSIDE), the rest of the screen as drawn. The rectangle is +left+, +top+, +right+
 * and +bottom+ in screen pixels, the right and bottom one past the last pixel. Always the
 * display's own fade, in sixteenths (see IR::Fading). */
#define RG_FADE_WHOLE_SCREEN 0
#define RG_FADE_INSIDE 1
#define RG_FADE_OUTSIDE 2
void rg_screen_fade_in_area(int32_t reaches, int32_t left, int32_t top, int32_t right, int32_t bottom,
                            int32_t toward_white, int32_t steps);
/* A tint toward +color+, in 256ths. On the plain bitmap screen the display mixes it in as
 * it draws, at eight bits a channel; on every other screen the game writes the tinted colors
 * itself. That follows the screen up, so a tint kept across a change of screen changes with it. */
void rg_screen_tint(int32_t color, int32_t steps);
/* How far +amount+ (a percentage, or with +fraction_bits+ >= 0 a fraction of one) is, in steps. */
int32_t rg_fade_steps(int32_t amount, int32_t fraction_bits, int32_t walked);

#endif
