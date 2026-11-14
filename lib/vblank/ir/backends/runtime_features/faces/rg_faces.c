/*
 * THE FACES OF A PLACE (Reference#exec_fill_face): one flat face of a 3D shape, already on the
 * screen, filled row by row with a picture, in perspective and lit. A runtime feature
 * (backends/runtime_features.rb): this file is included at the end of rg_screen.c, for a game that
 * draws a place, so it reads the screen's own state and painters as if it were written there. A game
 * with no place builds without it.
 *
 * The screen never asks it anything: the game calls rg_screen_face (declared in rg_faces.h).
 */
#include "rg_faces.h"

/* Reference::FaceEdge: one edge of a face, from its upper end down, as the fill walks it. The
 * numbers are x, u, v, w and shade, each where the edge crosses its first row, then each one's step. */
typedef struct { int32_t first_row, past_row, at[5], step[5]; } face_edge;

/* Reference::FaceEdges.edge: the edge from +top+ to +bottom+ (each x, y, u, v, w, shade), or 0 when
 * it crosses no row's middle. */
static int face_edge_of(const int32_t *top, const int32_t *bottom, face_edge *edge) {
  int32_t first_row = rg_shr(rg_add(top[1], 7), 4);
  int32_t past_row = rg_shr(rg_add(bottom[1], 7), 4);
  if (first_row >= past_row) return 0;
  int32_t along_row = rg_div(1 << 28, rg_sub(bottom[1], top[1]));
  int32_t into = rg_mul_fix(rg_sub(rg_add(rg_mul(first_row, 16), 8), top[1]), along_row, 4);
  int32_t parts[5] = {rg_shl(rg_sub(bottom[0], top[0]), 12), rg_sub(bottom[2], top[2]), rg_sub(bottom[3], top[3]),
                      rg_sub(bottom[4], top[4]), rg_sub(bottom[5], top[5])};
  int32_t starts[5] = {rg_shl(top[0], 12), top[2], top[3], top[4], top[5]};
  edge->first_row = first_row;
  edge->past_row = past_row;
  for (int part = 0; part < 5; part++) {
    edge->at[part] = rg_add(starts[part], rg_mul_fix(parts[part], into, 24));
    edge->step[part] = rg_mul_fix(parts[part], along_row, 24);
  }
  return 1;
}

/* IR::Reciprocals: 2**40 over each number of eleven bits with the top one set. */
static int32_t face_reciprocals[1024];

/* IR::Reciprocals.distance: the distance, with 16 bits of fraction, for one over it with 26. */
static int32_t face_distance(int32_t w) {
  if (face_reciprocals[0] == 0) {
    for (int32_t leading = 0; leading < 1024; leading++) face_reciprocals[leading] = (int32_t)((1LL << 40) / (1024 + leading));
  }
  if (w < 4096) w = 4096;
  int moved = 0;
  while ((w >> moved) >= 2048) moved++;
  return face_reciprocals[(w >> moved) - 1024] >> (moved - 2);
}

/* Reference#place_in_perspective: u and v exactly +along+ pixels into a row from +from+ (x, u/z,
 * v/z, 1/z), whose numbers step +steps+ a pixel. */
static void face_place_in_perspective(const int32_t *from, const int32_t *steps, int32_t along, int32_t *place) {
  int32_t over_u = rg_add(from[1], rg_mul(steps[0], along));
  int32_t over_v = rg_add(from[2], rg_mul(steps[1], along));
  int32_t distance = face_distance(rg_add(from[3], rg_mul(steps[2], along)));
  place[0] = rg_mul_fix(over_u, distance, 14);
  place[1] = rg_mul_fix(over_v, distance, 14);
}

/* Nodes::FillFace::SPLIT_PIXELS: how far into a long stretch it is cut where the distance changes fast. */
enum { FACE_SPLIT_PIXELS = 8 };

/* Reference#fast_change?: whether one over the distance, +w+ at a stretch's start and stepping
 * +w_step+ a pixel, changes over FACE_SPLIT_PIXELS pixels by more than a sixteenth of +w+. */
static int face_fast_change(int32_t w, int32_t w_step) {
  int32_t change = rg_mul(w_step, FACE_SPLIT_PIXELS);
  int32_t limit = rg_shr(w, 4);
  return change > limit || change < rg_sub(0, limit);
}

/* Reference::Shade's places: where each colour stands in a shading's list of colours, or -1 for a
 * colour not in it. Worked out again only when the shading drawn with changes. */
static const int32_t *shading_placed = NULL;
static int16_t shading_places[32768];

static int32_t shading_place_of(const int32_t *shading, int32_t color) {
  int32_t colors = shading[1];
  if (color < 0 || color >= 32768) {
    for (int32_t place = 0; place < colors; place++)
      if (shading[2 + place] == color) return place;
    return -1;
  }
  if (shading_placed != shading) {
    memset(shading_places, 0xFF, sizeof shading_places);
    for (int32_t place = colors - 1; place >= 0; place--) {
      int32_t listed = shading[2 + place];
      if (listed >= 0 && listed < 32768) shading_places[listed] = (int16_t)place;
    }
    shading_placed = shading;
  }
  return shading_places[color];
}

/* Reference::Shade#pixel_color_at: the colour place +place+ of the shading's colours becomes at
 * +shade+ (its level in the top sixteen bits). */
static int32_t shaded_place(const int32_t *shading, int32_t place, int32_t shade) {
  int32_t colors = shading[1];
  int32_t level = rg_shr(shade, 16);
  return shading[2 + shading[2 + colors + level * colors + place]];
}

/* Reference::Shade#color_at: the colour +color+ becomes at +shade+. A colour not in the shading's
 * list stays as it is. */
static int32_t shaded_color(const int32_t *shading, int32_t color, int32_t shade) {
  int32_t place = shading_place_of(shading, color);
  if (place < 0) return color;
  return shaded_place(shading, place, shade);
}

/* Reference#fill_face_row: one row of a face, from +from+ to +to+ (each x, u, v, w), in
 * perspective every +spans+ pixels (none when nought).
 *
 * +numbers+ is, for a picture given as numbers into the shading's colours, those numbers as a
 * picture of the same size (Computer::Picture#shading_array); its pixels is NULL for any other. */
static void face_row(int32_t row, int32_t *from, int32_t *to, int32_t left, int32_t right, picture art,
                     picture numbers, int32_t spans, const int32_t *shading) {
  int32_t start = rg_shr(rg_add(from[0], (1 << 15) - 1), 16);
  int32_t stop = rg_shr(rg_add(to[0], (1 << 15) - 1), 16);
  int32_t count = rg_sub(stop, start);
  if (count <= 0) return;
  if (shading) {
    /* Reference::Shade#held_row_end */
    from[4] = clamp32(from[4], 0, rg_shl(shading[0], 16) - 1);
    to[4] = clamp32(to[4], 0, rg_shl(shading[0], 16) - 1);
  }
  int32_t steps[4];
  for (int part = 0; part < 4; part++) steps[part] = rg_div(rg_sub(to[part + 1], from[part + 1]), count);
  int32_t first = start > left ? start : left;
  int32_t past = stop < right ? stop : right;
  int32_t near_at = -1, near[2], far[2];
  for (int32_t x = first; x < past; x++) {
    int32_t along = rg_sub(x, start);
    int32_t u, v;
    if (spans == 0) {
      u = rg_add(from[1], rg_mul(steps[0], along));
      v = rg_add(from[2], rg_mul(steps[1], along));
    } else {
      /* Reference#stretch_ends: exact at the multiple of +spans+ before and the next, or the end,
       * and a long stretch cut in two where the distance changes fast */
      int32_t near_along = (along / spans) * spans;
      int32_t far_along = near_along + spans < count ? near_along + spans : count;
      int32_t cut = near_along + FACE_SPLIT_PIXELS;
      if (far_along > cut && face_fast_change(rg_add(from[3], rg_mul(steps[2], near_along)), steps[2])) {
        if (along < cut) far_along = cut;
        else near_along = cut;
      }
      if (near_along != near_at) {
        face_place_in_perspective(from, steps, near_along, near);
        face_place_in_perspective(from, steps, far_along, far);
        near_at = near_along;
      }
      u = rg_add(near[0], rg_mul(rg_div(rg_sub(far[0], near[0]), far_along - near_along), along - near_along));
      v = rg_add(near[1], rg_mul(rg_div(rg_sub(far[1], near[1]), far_along - near_along), along - near_along));
    }
    int32_t across = rg_and(rg_shr(u, 16), art.width - 1);
    int32_t down = rg_and(rg_shr(v, 16), art.height - 1);
    int32_t color = art.pixels[down * art.width + across];
    if (color == RG_NOT_DRAWN) continue;
    if (shading) {
      int32_t shade = rg_add(from[4], rg_mul(steps[3], along));
      color = numbers.pixels ? shaded_place(shading, numbers.pixels[down * art.width + across], shade)
                             : shaded_color(shading, color, shade);
    }
    set_pixel(x, row, color);
  }
}

/* The most corners a face has (Nodes::FillFace::MOST_CORNERS). */
enum { FACE_MOST_CORNERS = 8 };

/* Reference#exec_fill_face: one face already on the screen, filled with its picture. The corners
 * come six numbers each (x and y in sixteenths of a pixel, u and v in picture pixels with sixteen
 * fraction bits, one over the distance with 26, and the light, 0 to 0xFFFF), and nothing outside
 * left, top, right and bottom is drawn. A +shading+ of [0] draws the picture as it is; any other
 * is its levels, its colours and each level's places (Computer::Picture#shading_array), and every
 * pixel is drawn in the colour its blended light's level gives. The picture's number is held to the ends of the list of pictures, and the count
 * to FACE_MOST_CORNERS. In perspective (+spans+ not nought) u and v become u and v over the
 * distance (Reference::FaceEdges.in_perspective) before the edges are walked. */
void rg_screen_face(const int32_t *pictures, int32_t picture_count, int32_t which, const rg_list *corner_list,
                    int32_t corner_count, int32_t left, int32_t top, int32_t right, int32_t bottom, int32_t spans,
                    const int32_t *shading) {
  if (corner_count > FACE_MOST_CORNERS) corner_count = FACE_MOST_CORNERS;
  if (corner_count < 3) return;
  if (shading[0] == 0) shading = NULL;
  int32_t corners[FACE_MOST_CORNERS][6];
  for (int32_t k = 0; k < corner_count; k++) {
    for (int32_t field = 0; field < 6; field++) corners[k][field] = rg_list_get(corner_list, k * 6 + field);
    /* Reference::Shade#shaded_corner: the light held to 0..LIGHTEST, times the levels */
    if (shading) corners[k][5] = rg_mul(clamp32(corners[k][5], 0, 0xFFFF), shading[0]);
    if (spans != 0) {
      corners[k][2] = rg_mul_fix(corners[k][2], corners[k][4], 28);
      corners[k][3] = rg_mul_fix(corners[k][3], corners[k][4], 28);
    }
  }
  int32_t image = pictures[clamp32(which, 0, picture_count - 1)];
  if (left < 0) left = 0;
  if (top < 0) top = 0;
  if (right > RG_SCREEN_WIDTH) right = RG_SCREEN_WIDTH;
  if (bottom > RG_SCREEN_HEIGHT) bottom = RG_SCREEN_HEIGHT;
  face_edge edges[FACE_MOST_CORNERS];
  int count = 0;
  for (int32_t k = 0; k < corner_count; k++) {
    const int32_t *a = corners[k], *b = corners[(k + 1) % corner_count];
    if (a[1] == b[1]) continue;
    if (a[1] < b[1] ? face_edge_of(a, b, &edges[count]) : face_edge_of(b, a, &edges[count])) count++;
  }
  if (count == 0) return;
  int32_t first = INT32_MAX, past = INT32_MIN;
  for (int e = 0; e < count; e++) {
    if (edges[e].first_row < first) first = edges[e].first_row;
    if (edges[e].past_row > past) past = edges[e].past_row;
  }
  if (first < top) first = top;
  if (past > bottom) past = bottom;
  picture art = picture_of(image);
  /* After the levels' places, a lit fill lists, for each of its pictures, the image of its numbers
   * into the shading's colours, or -1 for a picture of colours. */
  picture numbers = {NULL, 0, 0};
  if (shading) {
    int32_t numbered = shading[2 + shading[1] + shading[0] * shading[1] + clamp32(which, 0, picture_count - 1)];
    if (numbered >= 0) numbers = picture_of(numbered);
  }
  for (int32_t row = first; row < past; row++) {
    int32_t from[5] = {INT32_MAX, 0, 0, 0, 0}, to[5] = {INT32_MIN, 0, 0, 0, 0};
    int crossing = 0;
    for (int e = 0; e < count; e++) {
      const face_edge *edge = &edges[e];
      if (row < edge->first_row || row >= edge->past_row) continue;
      int32_t rows = rg_sub(row, edge->first_row);
      int32_t at[5];
      for (int part = 0; part < 5; part++) at[part] = rg_add(edge->at[part], rg_mul(edge->step[part], rows));
      crossing++;
      /* the leftmost is the first of the leftmost, the rightmost the last of the rightmost */
      if (at[0] < from[0]) memcpy(from, at, sizeof at);
      if (at[0] >= to[0]) memcpy(to, at, sizeof at);
    }
    if (crossing >= 2) face_row(row, from, to, left, right, art, numbers, spans, shading);
  }
}
