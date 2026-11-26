/*
 * The faces of a place (Reference#exec_fill_face): one flat face of a 3D shape, already on the screen, filled row by row
 * with a picture, in perspective and lit. A port of the JavaScript runtime's rg_faces.js, function for function
 * (rg_faces.c says how, rule for rule). A runtime feature (backends/runtime_features.rb), joined into the runtime after
 * rg_screen.hx for a game that draws a place, so it reads the screen's own state and painters as if it were written
 * there.
 *
 * The screen never asks it anything: the game calls rg_screen_face.
 */

/* Reference::FaceEdges.edge: the edge from +top+ to +bottom+ (each x, y, u, v, w, shade), or null when it crosses no
 * row's middle. +at+ is x, u, v, w and shade where it crosses its first row, +step+ each one's step a row. */
static function face_edge_of(top:Array<Int>, bottom:Array<Int>):RgFaceEdge {
  var first_row = rg_shr(rg_add(top[1], 7), 4);
  var past_row = rg_shr(rg_add(bottom[1], 7), 4);
  if (first_row >= past_row) return null;
  var along_row = rg_div(1 << 28, rg_sub(bottom[1], top[1]));
  var into = rg_mul_fix(rg_sub(rg_add(rg_mul(first_row, 16), 8), top[1]), along_row, 4);
  var parts = [rg_shl(rg_sub(bottom[0], top[0]), 12), rg_sub(bottom[2], top[2]), rg_sub(bottom[3], top[3]),
               rg_sub(bottom[4], top[4]), rg_sub(bottom[5], top[5])];
  var starts = [rg_shl(top[0], 12), top[2], top[3], top[4], top[5]];
  return new RgFaceEdge(first_row, past_row, [for (k in 0...5) rg_add(starts[k], rg_mul_fix(parts[k], into, 24))],
                        [for (part in parts) rg_mul_fix(part, along_row, 24)]);
}

/* IR::Reciprocals: 2**40 over each number of eleven bits with the top one set. */
static var FACE_RECIPROCALS:Vector<Int> = face_reciprocals_made();
static function face_reciprocals_made():Vector<Int> {
  var made = new Vector<Int>(1024);
  for (leading in 0...1024) made[leading] = Std.int(rg_floor(1099511627776.0 / (1024 + leading)));
  return made;
}

/* IR::Reciprocals.distance: the distance, with 16 bits of fraction, for one over it with 26. */
static function face_distance(w:Int):Int {
  if (w < 4096) w = 4096;
  var moved = 0;
  while ((w >> moved) >= 2048) moved++;
  return FACE_RECIPROCALS[(w >> moved) - 1024] >> (moved - 2);
}

/* Reference#place_in_perspective: the u and v, left in face_place_u and face_place_v. */
static var face_place_u:Int = 0;
static var face_place_v:Int = 0;
static function face_place_in_perspective(from:Array<Int>, steps:Array<Int>, along:Int):Void {
  var over_u = rg_add(from[1], rg_mul(steps[0], along));
  var over_v = rg_add(from[2], rg_mul(steps[1], along));
  var distance = face_distance(rg_add(from[3], rg_mul(steps[2], along)));
  face_place_u = rg_mul_fix(over_u, distance, 14);
  face_place_v = rg_mul_fix(over_v, distance, 14);
}

/* Nodes::FillFace::SPLIT_PIXELS */
static inline var FACE_SPLIT_PIXELS:Int = 8;

/* Reference#fast_change? */
static function face_fast_change(w:Int, w_step:Int):Bool {
  var change = rg_mul(w_step, FACE_SPLIT_PIXELS);
  var limit = rg_shr(w, 4);
  return change > limit || change < rg_sub(0, limit);
}

/* Reference::Shade's places: for each shading drawn with, where each colour stands in its list of colours. */
static var shading_kept:Array<Vector<Int>> = [];
static var shading_places:Array<haxe.ds.IntMap<Int>> = [];

/* Reference::Shade#color_at: the colour +color+ becomes at +shade+ (its level in the top sixteen bits). A colour not in
 * the shading's list stays as it is. */
static function shaded_color(shading:Vector<Int>, color:Int, shade:Int):Int {
  var colors = shading[1];
  var at = shading_kept.indexOf(shading);
  if (at < 0) {
    var places = new haxe.ds.IntMap<Int>();
    var place = colors - 1;
    while (place >= 0) {
      places.set(shading[2 + place], place);
      place--;
    }
    shading_kept.push(shading);
    shading_places.push(places);
    at = shading_kept.length - 1;
  }
  var found = shading_places[at];
  if (!found.exists(color)) return color;
  return shaded_place(shading, found.get(color), shade);
}

/* Reference::Shade#pixel_color_at: the colour place +place+ of the shading's colours becomes at +shade+. */
static function shaded_place(shading:Vector<Int>, place:Int, shade:Int):Int {
  var colors = shading[1];
  var level = rg_shr(shade, 16);
  return shading[2 + shading[2 + colors + level * colors + place]];
}

/* Reference#fill_face_row: one row of a face, from +from+ to +to+ (each x, u, v, w, shade), in perspective every +spans+
 * pixels (none when nought), each pixel through +shading+ when lit. +numbers+ is, for a picture given as numbers into the
 * shading's colours, those numbers as a picture of the same size; null for any other. */
static function face_row(row:Int, from:Array<Int>, to:Array<Int>, left:Int, right:Int, art:RgArt, numbers:RgArt, spans:Int, shading:Vector<Int>):Void {
  var start = rg_shr(rg_add(from[0], (1 << 15) - 1), 16);
  var stop = rg_shr(rg_add(to[0], (1 << 15) - 1), 16);
  var count = rg_sub(stop, start);
  if (count <= 0) return;
  if (shading != null) {
    // Reference::Shade#held_row_end
    from[4] = clamp_number(from[4], 0, rg_shl(shading[0], 16) - 1);
    to[4] = clamp_number(to[4], 0, rg_shl(shading[0], 16) - 1);
  }
  var steps = [for (part in 1...5) rg_div(rg_sub(to[part], from[part]), count)];
  var first = start > left ? start : left;
  var past = stop < right ? stop : right;
  var near_at = -1;
  var near_u = 0;
  var near_v = 0;
  var far_u = 0;
  var far_v = 0;
  for (x in first...past) {
    var along = rg_sub(x, start);
    var u:Int;
    var v:Int;
    if (spans == 0) {
      u = rg_add(from[1], rg_mul(steps[0], along));
      v = rg_add(from[2], rg_mul(steps[1], along));
    } else {
      // Reference#stretch_ends
      var near_along = Std.int(along / spans) * spans;
      var far_along = near_along + spans < count ? near_along + spans : count;
      var cut = near_along + FACE_SPLIT_PIXELS;
      if (far_along > cut && face_fast_change(rg_add(from[3], rg_mul(steps[2], near_along)), steps[2])) {
        if (along < cut) far_along = cut;
        else near_along = cut;
      }
      if (near_along != near_at) {
        face_place_in_perspective(from, steps, near_along);
        near_u = face_place_u;
        near_v = face_place_v;
        face_place_in_perspective(from, steps, far_along);
        far_u = face_place_u;
        far_v = face_place_v;
        near_at = near_along;
      }
      u = rg_add(near_u, rg_mul(rg_div(rg_sub(far_u, near_u), far_along - near_along), along - near_along));
      v = rg_add(near_v, rg_mul(rg_div(rg_sub(far_v, near_v), far_along - near_along), along - near_along));
    }
    var across = rg_and(rg_shr(u, 16), art.width - 1);
    var down = rg_and(rg_shr(v, 16), art.height - 1);
    var color = picture_pixel(art, down * art.width + across);
    if (color == RG_NOT_DRAWN) continue;
    if (shading != null) {
      var shade = rg_add(from[4], rg_mul(steps[3], along));
      color = numbers != null ? shaded_place(shading, numbers.pixels[numbers.start + down * art.width + across], shade)
                              : shaded_color(shading, color, shade);
    }
    set_pixel(x, row, color);
  }
}

/* The most corners a face has (Nodes::FillFace::MOST_CORNERS). */
static inline var FACE_MOST_CORNERS:Int = 8;

/* Reference#exec_fill_face */
static function rg_screen_face(pictures:Vector<Int>, picture_count:Int, picture:Int, corner_list:RgList, corner_count:Int, left:Int, top:Int,
                               right:Int, bottom:Int, spans:Int, shading_given:Vector<Int>):Void {
  if (corner_count > FACE_MOST_CORNERS) corner_count = FACE_MOST_CORNERS;
  if (corner_count < 3) return;
  var shading = shading_given[0] == 0 ? null : shading_given;
  var corners:Array<Array<Int>> = [];
  for (k in 0...corner_count) {
    var corner = [for (field in 0...6) rg_list_get(corner_list, k * 6 + field)];
    // Reference::Shade#shaded_corner: the light held to 0..LIGHTEST, times the levels
    if (shading != null) corner[5] = rg_mul(clamp_number(corner[5], 0, 0xFFFF), shading[0]);
    if (spans != 0) {
      // Reference::FaceEdges.in_perspective
      corner[2] = rg_mul_fix(corner[2], corner[4], 28);
      corner[3] = rg_mul_fix(corner[3], corner[4], 28);
    }
    corners.push(corner);
  }
  var image = pictures[clamp_number(picture, 0, picture_count - 1)];
  if (left < 0) left = 0;
  if (top < 0) top = 0;
  if (right > RG_SCREEN_WIDTH) right = RG_SCREEN_WIDTH;
  if (bottom > RG_SCREEN_HEIGHT) bottom = RG_SCREEN_HEIGHT;
  var edges:Array<RgFaceEdge> = [];
  for (k in 0...corner_count) {
    var a = corners[k];
    var b = corners[(k + 1) % corner_count];
    if (a[1] == b[1]) continue;
    var edge = a[1] < b[1] ? face_edge_of(a, b) : face_edge_of(b, a);
    if (edge != null) edges.push(edge);
  }
  if (edges.length == 0) return;
  var first = RG_INT32_MAX;
  var past = RG_INT32_MIN;
  for (edge in edges) {
    if (edge.first_row < first) first = edge.first_row;
    if (edge.past_row > past) past = edge.past_row;
  }
  if (first < top) first = top;
  if (past > bottom) past = bottom;
  var art = picture_of(image);
  // After the levels' places, a lit fill lists, for each of its pictures, the image of its numbers into the shading's
  // colours, or -1 for a picture of colours.
  var numbers:RgArt = null;
  if (shading != null) {
    var numbered = shading[2 + shading[1] + shading[0] * shading[1] + clamp_number(picture, 0, picture_count - 1)];
    if (numbered >= 0) numbers = picture_of(numbered);
  }
  for (row in first...past) {
    var from = [RG_INT32_MAX, 0, 0, 0, 0];
    var to = [RG_INT32_MIN, 0, 0, 0, 0];
    var crossing = 0;
    for (edge in edges) {
      if (row < edge.first_row || row >= edge.past_row) continue;
      var rows = rg_sub(row, edge.first_row);
      var at = [for (part in 0...5) rg_add(edge.at[part], rg_mul(edge.step[part], rows))];
      crossing++;
      // the leftmost is the first of the leftmost, the rightmost the last of the rightmost
      if (at[0] < from[0]) from = at;
      if (at[0] >= to[0]) to = at;
    }
    if (crossing >= 2) face_row(row, from, to, left, right, art, numbers, spans, shading);
  }
}
