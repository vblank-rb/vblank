/*
 * The game's picture, drawn in software: the console's 240x160 screen as an array of colors,
 * and everything the game does to it.
 *
 * It is a port of the interpreter's own picture (backends/reference.rb and
 * reference/framebuffer.rb), method for method, because the interpreter is what a desktop build
 * is checked against pixel for pixel. That includes the parts that look like bookkeeping — when
 * the whole view is rebuilt, which scenery is up, what a scene takes down as it arrives — since
 * each of them decides what a pixel holds on some frame.
 *
 * A color is the console's: fifteen bits, five each of red, green and blue, red lowest. A
 * picture's pixel can carry a sixteenth bit, the one that marks a see-through pixel in the art;
 * it is kept as it is, the way the interpreter keeps it, and only a blend drops it.
 *
 * The art comes from the generated game (game.c), as the arrays declared at the bottom.
 */
#ifndef RG_SCREEN_H
#define RG_SCREEN_H

#include <stdint.h>
#include "rg_list.h"

#include "rg_console.h"

/* The kinds of screen a `screen` can name. Two of the same kind share a display; changing kind
 * replaces the whole display (see IR::SceneHandover). */
enum { RG_BITMAP = 0, RG_TILED = 1, RG_ROTOZOOM = 2 };

/* --- what the generated game calls --- */

void rg_screen_hold(int32_t held);              /* switched off until the first frame is set up */
/* A `screen` statement. +two_pages+ is 1 for a tear-free screen: two pictures, the one being
 * drawn and the one being shown, traded between frames.
 *
 * Both answer 1 when the scenery every screen drawn from tiles shows was put up again, as
 * declared, because a screen of another kind had replaced the display. The game then puts what
 * names which map each of those backgrounds shows back to the first. */
/* +backdrop+ is the colour shown wherever nothing is drawn (IR::SceneHandover#backdrop_of), or
 * below nought to leave it as a list of colours has it. */
int32_t rg_screen_set(int32_t kind, int32_t two_pages, int32_t backdrop);
int32_t rg_screen_cross_to(int32_t kind, int32_t two_pages, int32_t backdrop); /* a scene arriving on the screen it draws on */
void rg_screen_show_backdrop(int32_t color); /* a backdrop that follows a list: its colour now */
void rg_screen_paint_owed_rebuild(void);        /* rebuild the whole view, if a rebuild is owed */
/* Reference#exec_in_loop: while +on+, the end of a pass is placing the frame's writes, and a
 * background that pass put up still shows from its corner. */
void rg_screen_placing_at_pass_end(int32_t on);

void rg_screen_clear(int32_t color);
void rg_screen_fill_rect(int32_t x, int32_t y, int32_t width, int32_t height, int32_t color);
void rg_screen_pixel(int32_t x, int32_t y, int32_t color);

/* Everything drawn between these two stays inside that part of the screen; what falls outside
 * is not drawn. The area in force before comes back at the end. */
void rg_screen_inside(int32_t x, int32_t y, int32_t width, int32_t height);
void rg_screen_inside_ended(void);

/* Move the window onto the picture: screen (0, 0) shows what was drawn at (x, y). Where the
 * window is now, which a test reads back as the interpreter's camera_x and camera_y. */
void rg_screen_camera(int32_t x, int32_t y);
int32_t rg_screen_camera_x(void);
int32_t rg_screen_camera_y(void);

/* A picture painted into the picture with its top left at (x, y); and one of +count+ pictures,
 * picked by +pose+, where a number naming none paints nothing. */
void rg_screen_blit(int32_t image, int32_t x, int32_t y);
void rg_screen_blit_pose(const int32_t *poses, int32_t count, int32_t pose, int32_t x, int32_t y);

/* The patch of the picture a sprite on a painted screen is about to cover, +width+ by +height+
 * at (x, y), kept in buffer number +buffer+; and that patch painted back. */
void rg_patch_save(int32_t buffer, int32_t width, int32_t height, int32_t x, int32_t y);
void rg_patch_restore(int32_t buffer, int32_t width, int32_t height, int32_t x, int32_t y);
/* Points worked out when the game was built — the pixels of a line of text — as (dx, dy)
 * pairs, painted from (x, y). */
void rg_screen_points(int32_t x, int32_t y, int32_t color, const int16_t *points, int32_t count);
/* One digit of a live number: +starts+ holds where each of the ten digits' points begin in
 * +points+ (eleven entries). A value outside 0..9 draws nothing. */
void rg_screen_digit(int32_t value, int32_t x, int32_t y, int32_t color, const int16_t *points,
                     const int32_t *starts);

/* The picture built again from its layers before it is next shown, for a change the game made that
 * paints nothing itself (Reference#exec_scroll_rows, a bend written). */
void rg_screen_request_rebuild(void);

/* The two routines a game's light is worked out by, which the game always has (empty when it has
 * no light) and the light's runtime feature calls (rg_light.h says how). */
void rg_game_shade_span(void);
void rg_game_shade_amount(void);

/* A scene taking over: remembered, then its screen, then what comes down, and once its scenery is
 * up — or the last scene's is down — the sprites of this frame back over it. */
void rg_scene_enter(int32_t scene);
void rg_scene_take_down(int32_t brings_scenery);
void rg_scene_redraw_sprites(int32_t brings_scenery);

/* Where choice number +which+ is in a row that holds a sprite's own first and then +others+ more:
 * the lists of colors it can be drawn with, or the layers it can be put in. A number naming none
 * of the others is its own. */
static inline int32_t rg_place_of_choice(int32_t which, int32_t others) { return which >= 0 && which < others ? which + 1 : 0; }

/* TILES AND PICTURES THE GAME PAINTS FROM A LIST (a run: see rg_game_tile_runs). A run takes what
 * its list holds now: tile k is the 32 bytes from k × 32, each byte two pixels with the left one
 * in the low four bits, each four bits a place in the run's colors, and place 0 see-through. A
 * slot the game never filled reads as 0. Until its first copy a run shows nothing at all.
 * Nothing is rebuilt here; the game asks for that itself where the interpreter does. */
void rg_tiles_copy(int32_t run, const rg_list *list);
/* A pose drawn from sprite tiles the game loads takes the loaded tiles it draws (Nodes::LoadSpriteTiles). */
void rg_tile_pose_load(int32_t run, const int32_t *pieces, int32_t piece_count, const void *table, int32_t kept,
                       int32_t at, int32_t to, int32_t count);

/* A SEE-THROUGH LAYER is mixed with what is behind it as the picture is painted: so much of the
 * layer, so much of what is already there (IR::SeeThrough). How much is two amounts the game
 * may work out as it runs, so the picture asks the game for them when it needs them, by calling
 * rg_game_see_through_amounts with one layer in mind. The game answers for the layer that is
 * asked about:
 *
 *   if (rg_see_through_asked(0)) rg_see_through_answer(shows, behind);
 *
 * rg_see_through_told is the game saying, before a frame is drawn, that a layer's amounts have
 * been worked out again: the picture is rebuilt when they come to other sixteenths than the
 * ones last told. */
void rg_see_through_told(int32_t layer);
int32_t rg_see_through_asked(int32_t layer);
void rg_see_through_answer(int32_t shows, int32_t behind);
void rg_game_see_through_amounts(void);

/* Two colors for a line of text, and the test that picks which. */
static inline int32_t rg_pick_color(int32_t showing, int32_t color, int32_t picked) {
  return showing != 0 ? picked : color;
}

/* --- what the runtimes call --- */

/* The frame boundary's two parts in the picture. As a frame ends, a tear-free screen trades its
 * pages, before anything that can stop the run there. As the next begins, the picture is
 * switched on. */
void rg_screen_frame_ended(void);
void rg_screen_frame_started(void);

/* The picture as it is SHOWN, rebuilt first if a rebuild is owed: RG_SCREEN_WIDTH times
 * RG_SCREEN_HEIGHT colors, row by row, with the fade or tint in force mixed in. */
const uint16_t *rg_screen_shown(void);

/* The same page as it is STORED: no window moved over it, no fade or tint. What a test counts
 * drawn pixels in; a player never sees it. */
const uint16_t *rg_screen_stored(void);

/* 1 while the screen is tear-free, and so two pages. */
int32_t rg_screen_two_pages(void);

/* How many times the whole view has been built again from its scenery and sprites since the game
 * began. A test reads it to see that a screen standing still is not rebuilt every frame. */
int32_t rg_screen_repaints_painted(void);

/* The sprites the game last put on screen (Reference#sprites), back to front: how many, and
 * each by its place among them. A row holds whose the sprite is and which picture it shows, both
 * as the number of a name (rg_game_sprite_names, rg_game_image_pictures), and where it is. They
 * stand until the game next sets its sprites, however many frames that is. */
typedef struct { int32_t name, picture, x, y; } rg_drawn_sprite;
int32_t rg_screen_drawn_count(void);
rg_drawn_sprite rg_screen_drawn_sprite(int32_t place);

/* --- the art, from the generated game --- */

/* Sprite pictures: each image is three numbers in rg_game_images (where its pixels start in
 * rg_game_image_pixels, its width and its height). A pixel is the fifteen bits of colour the
 * picture stores, or RG_NOT_DRAWN where what is behind shows, so sixteen signed bits hold every
 * one. A sprite drawn with another list of colors has a picture of its own for each list, made
 * when the game is built. */
#define RG_NOT_DRAWN (-1)
extern const int16_t rg_game_image_pixels[];
/* The +count+ image pixels the picture is drawn from, as an array that can be written: a copy of
 * rg_game_image_pixels, made the first time this is asked, which the picture is drawn from from
 * then on. For an image read from the file the game is handed as it starts (rg_start_file_fill_picture). */
int16_t *rg_screen_image_pixels_to_fill(int32_t count);
extern const int32_t rg_game_images[];
#define RG_IMAGE_FIELDS 3
/* The most sprites a game may have; the build refuses more. */
#define RG_MAX_SPRITES 512
/* For each sprite, by its number: which see-through layer it was declared in, counting through
 * rg_game_see_through, or RG_SOLID. */
#define RG_SOLID (-1)
extern const int32_t rg_game_sprite_see_through[];
/* For each sprite, by its number: the furthest forward a placed fade's layer can be and still
 * leave it as drawn, as RG_BG_FADE_PLACE gives for a background. */
extern const int32_t rg_game_sprite_fade_places[];
/* What a run says a sprite it drew by. For each sprite, by its number: the number of the name the
 * game declared it under, or RG_NO_NAME for one it named nothing for, such as a letter of text.
 * And for each image, by its number: the number of the name the author gave the picture, the
 * same whatever colors the image is that picture in. */
#define RG_NO_NAME (-1)
extern const int32_t rg_game_sprite_names[];
extern const int32_t rg_game_image_pictures[];
/* A SPRITE IN BLOCKS is put into them a box at a time, and the boxes are the ones a console
 * draws it as: a pose trimmed to what it draws, a big picture cut into pieces (Backends::SpriteCut,
 * which the build asks). For each sprite, by its number, rg_game_sprite_blocks is RG_NOT_IN_BLOCKS
 * for one the game leaves as drawn whatever the size, or where its boxes start in
 * rg_game_sprite_boxes. There: how many pictures it can show, and for each the number of the
 * picture's name (as rg_game_image_pictures has it), how many boxes it is drawn as, and each box
 * as its left, top, width and height inside the picture, the one in front first. A sprite that
 * turns or resizes is put into blocks whole and has no pictures listed. */
#define RG_NOT_IN_BLOCKS (-1)
extern const int32_t rg_game_sprite_blocks[];
extern const int32_t rg_game_sprite_boxes[];
/* THE PIECES A CONSOLE'S SPRITE TABLE HOLDS each image as, for a console that draws only so many
 * on a line (RG_SPRITE_PIECES_A_LINE; Backends::SpriteLines). The first number is how tall a piece
 * is; then, for each image by its number, where its pieces start in this array; and there, how
 * many there are, then each one's across and down inside the picture, the one in front first. Only
 * the first number for a console that draws every piece. */
extern const int32_t rg_game_image_pieces[];

/* Each layer the game can be seen through is RG_ST_FIELDS numbers in rg_game_see_through: 1 when
 * both its amounts are numbers written in the program, 1 when it was given one amount (how much
 * of what is behind shows, the layer taking the rest of a whole) rather than two, and 1 when any
 * sprite was declared in it. */
enum { RG_ST_AMOUNTS_WRITTEN, RG_ST_ONE_AMOUNT, RG_ST_HOLDS_A_SPRITE, RG_ST_FIELDS };
extern const int32_t rg_game_see_through[];
/* The most see-through layers a game may have; the build refuses more. */
#define RG_MAX_SEE_THROUGH 16

/* Tiles, as colors, with RG_SEE_THROUGH where the layer behind shows. No color is that number,
 * since a tile's color is fifteen bits. */
#define RG_SEE_THROUGH 0xFFFFu
extern const uint16_t rg_game_tile_pixels[];
/* The +count+ tile pixels the picture is drawn from, as an array that can be written: a copy of
 * rg_game_tile_pixels, made the first time this is asked, which the picture is drawn from from then
 * on. For a tile read from the file the game is handed as it starts (rg_start_file_fill_picture),
 * which rg_runtime.c fills whether or not the game has scenery to draw them. */
uint16_t *rg_screen_tile_pixels_to_fill(int32_t count);

/* A layer's place in the stack where a thing named none (RG_BG_FADE_PLACE, rg_game_sprite_fade_places). */
#define RG_NO_LAYER (-1)

/* Each run of tiles the game paints from a list is RG_RUN_FIELDS numbers in rg_game_tile_runs. A
 * run a background shows holds how many tiles it has, and its width and height are nought. A run
 * that is a sprite's picture holds the picture's width and height, and its tiles are the
 * picture's, left to right and then top to bottom. RG_RUN_PLACES is where the run's pixels are
 * kept among every run's, as places in its colors.
 *
 * A painted picture is an image like any other, once for each list of colors a sprite is drawn
 * with. RG_RUN_IMAGES of them are listed in rg_game_run_images from entry RG_RUN_FIRST_IMAGE on,
 * each RG_RUN_IMAGE_FIELDS numbers: the image, and the sixteen colors its places show, the first
 * being RG_NOT_DRAWN. */
enum { RG_RUN_TILES, RG_RUN_WIDTH, RG_RUN_HEIGHT, RG_RUN_PLACES, RG_RUN_FIRST_IMAGE, RG_RUN_IMAGES, RG_RUN_PLANES, RG_RUN_FIELDS };
enum { RG_RUN_IMAGE_FIELDS = 17 };
extern const int32_t rg_game_tile_runs[];
extern const int32_t rg_game_run_images[];

/* [how many backgrounds, how many depths the picture is built at, how many backgrounds every
 * screen drawn from tiles shows, 1 for a game whose whole view is rebuilt from its layers, how
 * many layers it can be seen through, 1 for a game that shows more than one kind of screen, the
 * biggest block a picture can be shown in (Backends::Blocks), how many runs of tiles it paints
 * from lists, how many pixels those runs hold between them, how many images it has, 1 for a game
 * whose sprites are shown over a painted screen] */
enum {
  RG_SIZE_BACKGROUNDS, RG_SIZE_DEPTHS, RG_SIZE_ALWAYS_UP, RG_SIZE_REBUILT_WHOLE, RG_SIZE_SEE_THROUGH,
  RG_SIZE_SCREEN_KINDS_CHANGE, RG_SIZE_LARGEST_BLOCK, RG_SIZE_RUNS, RG_SIZE_RUN_PIXELS, RG_SIZE_IMAGES,
  RG_SIZE_SPRITES_OVER_PICTURE
};
extern const int32_t rg_game_picture_sizes[];

/* The game's own: places its sprites over a painted screen again, as a two-page screen publishes
 * the page just finished (Reference#advance_frame). Nothing in a game without such sprites. */
void rg_game_sprites_over_picture(void);

/* sin(d) in 256ths for d = 0..449, the table every backend turns a picture by (IR::Affine), and
 * the four numbers that turn it into a matrix: what a size of 1.0 is (Build::SCALE_ONE), what
 * the matrix calls 1.0 (Affine::ONE_TH), the largest number it holds (Affine::MAX) and the
 * smallest size (Affine::MIN_SCALE). */
extern const int32_t rg_game_sines[];
extern const int32_t rg_game_turn_rules[];

#endif
