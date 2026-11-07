/* What a game with sprites calls (rg_sprites.c). */
#ifndef RG_SPRITES_H
#define RG_SPRITES_H

#include <stdint.h>

/* The sprites on screen this frame, set between begin and end. Each sprite has a number of its
 * own, the same every frame. First every sprite the frame draws is taken off, shown or not
 * (rg_object_take_off, with one of its pictures for its size); then each one that is shown is
 * added, back to front.
 *
 * What the end does with them is the game's, settled when it was built (rg_game_picture_sizes):
 * a game whose scenery moves, turns or sits in front of a sprite has its whole view rebuilt from
 * its layers, and taking a sprite off does nothing. Any other game keeps its scenery as it is and
 * draws the sprites straight onto it, so taking one off puts back the scenery it was covering.
 *
 * A sprite that turns or resizes is set with the two _turned ones: +angle+ in degrees clockwise
 * from upright, +size+ counted as the game counts a size (rg_game_turn_rules gives what 1.0 is),
 * both about the middle of its picture. Taking one off puts back every pixel it could have
 * covered: the whole box the display gives it when it +resizes+, and a square as wide as its
 * own diagonal when it only turns. Adding one gives +resizes+ too, because the rows of that box a
 * picture that only turns can reach decide whether it is on the screen at all. */
void rg_objects_begin(void);
void rg_object_take_off(int32_t sprite, int32_t width, int32_t height);
void rg_object_take_off_turned(int32_t sprite, int32_t image, int32_t resizes);
void rg_objects_add(int32_t sprite, int32_t image, int32_t x, int32_t y, int32_t level);
void rg_objects_add_turned(int32_t sprite, int32_t image, int32_t x, int32_t y, int32_t level, int32_t angle,
                           int32_t size, int32_t resizes);
void rg_objects_end(void);

/* Which sprite of a run the game puts in order is drawn next: the one the number +said+ names of
 * the run's +count+, as the list the game keeps the order in holds it, read as the interpreter
 * reads it. A number below nought counts back from the last, and one that still names none is a
 * fault. */
int32_t rg_place_in_ordered_run(int32_t said, int32_t count);

/* Which of a sprite's pictures it is showing, for a collision: number +pose+ of +count+, read as
 * the interpreter reads it. A number below nought counts back from the last, and one that still
 * names none is a fault. */
int32_t rg_pose_image(const int32_t *poses, int32_t count, int32_t pose);

/* Do two sprites' DRAWN pixels touch — one that is not see-through in each, on the same spot? */
int32_t rg_pixels_overlap(int32_t a_image, int32_t a_x, int32_t a_y, int32_t b_image, int32_t b_x, int32_t b_y);

#endif
