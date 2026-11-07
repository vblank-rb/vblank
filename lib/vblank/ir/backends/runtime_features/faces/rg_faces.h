/* What a game that fills the faces of a place calls (rg_faces.c). */
#ifndef RG_FACES_H
#define RG_FACES_H

#include <stdint.h>
#include "rg_list.h"

/* One face of a place, already on the screen, filled with picture +which+ of +pictures+ (the
 * game's image numbers, +picture_count+ of them): its corners the first +count+ sixes of x, y, u,
 * v, w and light in +corners+, nothing drawn outside the four edges, the picture in perspective
 * every +perspective+ pixels (none when nought), lit by +shading+ (how many levels, how many
 * colours, the colours, each level's places; a first number of nought for none). */
void rg_screen_face(const int32_t *pictures, int32_t picture_count, int32_t which, const rg_list *corners,
                    int32_t count, int32_t left, int32_t top, int32_t right, int32_t bottom, int32_t perspective,
                    const int32_t *shading);

#endif
