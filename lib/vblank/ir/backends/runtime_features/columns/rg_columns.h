/* What a game that draws stretched columns calls (rg_columns.c). */
#ifndef RG_COLUMNS_H
#define RG_COLUMNS_H

#include <stdint.h>

/* Column +slice+ of a picture, stretched to +height+ rows from +top+ and painted +width+ pixels
 * across from +x+. */
void rg_screen_column(int32_t image, int32_t slice, int32_t x, int32_t top, int32_t height, int32_t width);

#endif
