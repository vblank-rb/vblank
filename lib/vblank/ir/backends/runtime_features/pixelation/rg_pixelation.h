/* What a game that pixelates calls (rg_pixelation.c). */
#ifndef RG_PIXELATION_H
#define RG_PIXELATION_H

#include <stdint.h>

/* The picture shown in flat blocks of +size+ pixels each way from now on, 1 being the picture as
 * drawn; a size past either end of the sizes there are stops at that end. Nothing drawn changes.
 * The blocks are fixed to the screen, one starting at every column and row that is a multiple of
 * the size, and each shows the color at its top left corner. Which things go into blocks was
 * settled when the game was built (RG_BG_IN_BLOCKS, rg_game_sprite_blocks). */
void rg_screen_pixelate(int32_t size);

#endif
