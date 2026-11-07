/*
 * THE FACES OF A PLACE (Reference#exec_fill_face): one flat face of a 3D shape, already on the
 * screen, filled row by row with a picture, in perspective and lit. A runtime feature
 * (backends/runtime_features.rb), joined into the runtime's script after rg_screen.js for a game that
 * draws a place, so it reads the screen's own state and painters as if it were written there.
 * rg_faces.c says how, rule for rule; this is that file written again, function for function.
 *
 * The screen never asks it anything: the game calls rg_screen_face.
 */

/* Reference::FaceEdges.edge: the edge from +top+ to +bottom+ (each x, y, u, v, w, shade), or null
 * when it crosses no row's middle. +at+ is x, u, v, w and shade where it crosses its first row,
 * +step+ each one's step a row. */
function face_edge_of(top, bottom) {
  const first_row = rg_shr(rg_add(top[1], 7), 4);
  const past_row = rg_shr(rg_add(bottom[1], 7), 4);
  if (first_row >= past_row) return null;
  const along_row = rg_div(1 << 28, rg_sub(bottom[1], top[1]));
  const into = rg_mul_fix(rg_sub(rg_add(rg_mul(first_row, 16), 8), top[1]), along_row, 4);
  const parts = [rg_shl(rg_sub(bottom[0], top[0]), 12), rg_sub(bottom[2], top[2]), rg_sub(bottom[3], top[3]),
                 rg_sub(bottom[4], top[4]), rg_sub(bottom[5], top[5])];
  const starts = [rg_shl(top[0], 12), top[2], top[3], top[4], top[5]];
  return {
    first_row, past_row,
    at: parts.map((part, k) => rg_add(starts[k], rg_mul_fix(part, into, 24))),
    step: parts.map((part) => rg_mul_fix(part, along_row, 24)),
  };
}

/* IR::Reciprocals: 2**40 over each number of eleven bits with the top one set. */
const FACE_RECIPROCALS = Array.from({ length: 1024 }, (_, leading) => Math.floor(2 ** 40 / (1024 + leading)));

/* IR::Reciprocals.distance: the distance, with 16 bits of fraction, for one over it with 26. */
function face_distance(w) {
  if (w < 4096) w = 4096;
  let moved = 0;
  while ((w >> moved) >= 2048) moved++;
  return FACE_RECIPROCALS[(w >> moved) - 1024] >> (moved - 2);
}

/* Reference#place_in_perspective */
function face_place_in_perspective(from, steps, along) {
  const over_u = rg_add(from[1], rg_mul(steps[0], along));
  const over_v = rg_add(from[2], rg_mul(steps[1], along));
  const distance = face_distance(rg_add(from[3], rg_mul(steps[2], along)));
  return [rg_mul_fix(over_u, distance, 14), rg_mul_fix(over_v, distance, 14)];
}

/* Reference::Shade's places: for each shading drawn with, where each colour stands in its list of
 * colours. */
const SHADING_PLACES = new WeakMap();

/* Reference::Shade#color_at: the colour +color+ becomes at +shade+ (its level in the top sixteen
 * bits). A colour not in the shading's list stays as it is. */
function shaded_color(shading, color, shade) {
  const colors = shading[1];
  let places = SHADING_PLACES.get(shading);
  if (!places) {
    places = new Map();
    for (let place = colors - 1; place >= 0; place--) places.set(shading[2 + place], place);
    SHADING_PLACES.set(shading, places);
  }
  const place = places.get(color);
  if (place === undefined) return color;
  return shaded_place(shading, place, shade);
}

/* Reference::Shade#pixel_color_at: the colour place +place+ of the shading's colours becomes at
 * +shade+. */
function shaded_place(shading, place, shade) {
  const colors = shading[1];
  const level = rg_shr(shade, 16);
  return shading[2 + shading[2 + colors + level * colors + place]];
}

/* Reference#fill_face_row: one row of a face, from +from+ to +to+ (each x, u, v, w, shade), in
 * perspective every +spans+ pixels (none when nought), each pixel through +shading+ when lit.
 * +numbers+ is, for a picture given as numbers into the shading's colours, those numbers as a
 * picture of the same size; null for any other. */
function face_row(row, from, to, left, right, art, numbers, spans, shading) {
  const start = rg_shr(rg_add(from[0], (1 << 15) - 1), 16);
  const stop = rg_shr(rg_add(to[0], (1 << 15) - 1), 16);
  const count = rg_sub(stop, start);
  if (count <= 0) return;
  if (shading) {
    // Reference::Shade#held_row_end
    from[4] = clamp_number(from[4], 0, rg_shl(shading[0], 16) - 1);
    to[4] = clamp_number(to[4], 0, rg_shl(shading[0], 16) - 1);
  }
  const steps = [1, 2, 3, 4].map((part) => rg_div(rg_sub(to[part], from[part]), count));
  const first = start > left ? start : left;
  const past = stop < right ? stop : right;
  let near_at = -1;
  let near = null;
  let far = null;
  for (let x = first; x < past; x++) {
    const along = rg_sub(x, start);
    let u;
    let v;
    if (spans === 0) {
      u = rg_add(from[1], rg_mul(steps[0], along));
      v = rg_add(from[2], rg_mul(steps[1], along));
    } else {
      // Reference#place_between
      const near_along = Math.floor(along / spans) * spans;
      const far_along = near_along + spans < count ? near_along + spans : count;
      if (near_along !== near_at) {
        near = face_place_in_perspective(from, steps, near_along);
        far = face_place_in_perspective(from, steps, far_along);
        near_at = near_along;
      }
      u = rg_add(near[0], rg_mul(rg_div(rg_sub(far[0], near[0]), far_along - near_along), along - near_along));
      v = rg_add(near[1], rg_mul(rg_div(rg_sub(far[1], near[1]), far_along - near_along), along - near_along));
    }
    const across = rg_and(rg_shr(u, 16), art.width - 1);
    const down = rg_and(rg_shr(v, 16), art.height - 1);
    let color = art.pixels[art.start + down * art.width + across];
    if (color === RG_NOT_DRAWN) continue;
    if (shading) {
      const shade = rg_add(from[4], rg_mul(steps[3], along));
      color = numbers ? shaded_place(shading, numbers.pixels[numbers.start + down * art.width + across], shade)
                      : shaded_color(shading, color, shade);
    }
    set_pixel(x, row, color);
  }
}

/* The most corners a face has (Nodes::FillFace::MOST_CORNERS). */
const FACE_MOST_CORNERS = 8;

/* Reference#exec_fill_face */
function rg_screen_face(pictures, picture_count, picture, corner_list, corner_count, left, top, right, bottom, spans,
                        shading) {
  if (corner_count > FACE_MOST_CORNERS) corner_count = FACE_MOST_CORNERS;
  if (corner_count < 3) return;
  if (shading[0] === 0) shading = null;
  const corners = [];
  for (let k = 0; k < corner_count; k++) {
    const corner = [0, 1, 2, 3, 4, 5].map((field) => rg_list_get(corner_list, k * 6 + field));
    // Reference::Shade#shaded_corner: the light held to 0..LIGHTEST, times the levels
    if (shading) corner[5] = rg_mul(clamp_number(corner[5], 0, 0xFFFF), shading[0]);
    if (spans !== 0) {
      // Reference::FaceEdges.in_perspective
      corner[2] = rg_mul_fix(corner[2], corner[4], 28);
      corner[3] = rg_mul_fix(corner[3], corner[4], 28);
    }
    corners.push(corner);
  }
  const image = pictures[clamp_number(picture, 0, picture_count - 1)];
  if (left < 0) left = 0;
  if (top < 0) top = 0;
  if (right > RG_SCREEN_WIDTH) right = RG_SCREEN_WIDTH;
  if (bottom > RG_SCREEN_HEIGHT) bottom = RG_SCREEN_HEIGHT;
  const edges = [];
  for (let k = 0; k < corner_count; k++) {
    const a = corners[k];
    const b = corners[(k + 1) % corner_count];
    if (a[1] === b[1]) continue;
    const edge = a[1] < b[1] ? face_edge_of(a, b) : face_edge_of(b, a);
    if (edge) edges.push(edge);
  }
  if (edges.length === 0) return;
  let first = 2147483647;
  let past = -2147483648;
  for (const edge of edges) {
    if (edge.first_row < first) first = edge.first_row;
    if (edge.past_row > past) past = edge.past_row;
  }
  if (first < top) first = top;
  if (past > bottom) past = bottom;
  const art = picture_of(image);
  // After the levels' places, a lit fill lists, for each of its pictures, the image of its numbers
  // into the shading's colours, or -1 for a picture of colours.
  let numbers = null;
  if (shading) {
    const numbered = shading[2 + shading[1] + shading[0] * shading[1] + clamp_number(picture, 0, picture_count - 1)];
    if (numbered >= 0) numbers = picture_of(numbered);
  }
  for (let row = first; row < past; row++) {
    let from = [2147483647, 0, 0, 0, 0];
    let to = [-2147483648, 0, 0, 0, 0];
    let crossing = 0;
    for (const edge of edges) {
      if (row < edge.first_row || row >= edge.past_row) continue;
      const rows = rg_sub(row, edge.first_row);
      const at = edge.at.map((start, part) => rg_add(start, rg_mul(edge.step[part], rows)));
      crossing++;
      // the leftmost is the first of the leftmost, the rightmost the last of the rightmost
      if (at[0] < from[0]) from = at;
      if (at[0] >= to[0]) to = at;
    }
    if (crossing >= 2) face_row(row, from, to, left, right, art, numbers, spans, shading);
  }
}
