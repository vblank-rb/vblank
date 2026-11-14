# frozen_string_literal: true

# THE FACES OF A PLACE (Reference#exec_fill_face): one flat face of a 3D shape, already on the screen,
# filled row by row with a picture, in perspective and lit. Joined into the runtime's class after
# rg_screen.rb for a game that draws a place. rg_faces.c says how, rule for rule; this is that file
# written again, method for method.
#
# The screen never asks it anything: the game calls rg_screen_face.

# Where each colour stands in a shading's list of colours, worked out once for each shading drawn with
# (rg_shading_places_of); named here so the game's shape never changes in play.
def rg_faces_setup
  @rg_shading_places = {}.compare_by_identity
end

# Reference::FaceEdge: one edge of a face, from its upper end down, as the fill walks it. Where it
# crosses a row is #rg_face_crossing, since the game's sums are the runtime's own methods.
RgFaceEdge = Data.define(:first_row, :past_row, :at, :step) do
  def crosses?(row) = row >= first_row && row < past_row
end

# Reference::FaceEdge#at: [x, u, v, w, shade] where +edge+ crosses +row+.
def rg_face_crossing(edge, row)
  rows = rg_sub(row, edge.first_row)
  at = edge.at
  step = edge.step
  [rg_add(at[0], rg_mul(step[0], rows)), rg_add(at[1], rg_mul(step[1], rows)), rg_add(at[2], rg_mul(step[2], rows)),
   rg_add(at[3], rg_mul(step[3], rows)), rg_add(at[4], rg_mul(step[4], rows))]
end

# The x alone of rg_face_crossing, which is all the walk down a face needs to choose a row's two ends.
def rg_face_crossing_x(edge, row) = rg_add(edge.at[0], rg_mul(edge.step[0], rg_sub(row, edge.first_row)))

# The most corners a face has (Nodes::FillFace::MOST_CORNERS).
RG_FACE_MOST_CORNERS = 8

# Reference::FaceEdges.edge: the edge from +top+ to +bottom+ (each x, y, u, v, w, shade), or nil
# when it crosses no row's middle.
def rg_face_edge(top, bottom)
  first_row = rg_shr(rg_add(top[1], 7), 4)
  past_row = rg_shr(rg_add(bottom[1], 7), 4)
  return nil if first_row >= past_row

  along_row = rg_div(1 << 28, rg_sub(bottom[1], top[1]))
  into = rg_mul_fix(rg_sub(rg_add(rg_mul(first_row, 16), 8), top[1]), along_row, 4)
  # Written out field by field, x then u, v, w and shade, with no block: a place's faces are many
  # and most are a few rows high, so what each costs before its first row counts as much as its rows.
  x_part = rg_shl(rg_sub(bottom[0], top[0]), 12)
  u_part = rg_sub(bottom[2], top[2])
  v_part = rg_sub(bottom[3], top[3])
  w_part = rg_sub(bottom[4], top[4])
  shade_part = rg_sub(bottom[5], top[5])
  RgFaceEdge.new(first_row, past_row,
                 [rg_add(rg_shl(top[0], 12), rg_mul_fix(x_part, into, 24)), rg_add(top[2], rg_mul_fix(u_part, into, 24)),
                  rg_add(top[3], rg_mul_fix(v_part, into, 24)), rg_add(top[4], rg_mul_fix(w_part, into, 24)),
                  rg_add(top[5], rg_mul_fix(shade_part, into, 24))],
                 [rg_mul_fix(x_part, along_row, 24), rg_mul_fix(u_part, along_row, 24), rg_mul_fix(v_part, along_row, 24),
                  rg_mul_fix(w_part, along_row, 24), rg_mul_fix(shade_part, along_row, 24)])
end

# IR::Reciprocals: 2**40 over each number of eleven bits with the top one set.
RG_FACE_RECIPROCALS = Ractor.make_shareable((1024...2048).map { |leading| (1 << 40) / leading })

# IR::Reciprocals.distance: the distance, with 16 bits of fraction, for one over it with 26.
def rg_face_distance(w)
  w = 4096 if w < 4096
  moved = w.bit_length - 11
  RG_FACE_RECIPROCALS[(w >> moved) - 1024] >> (moved - 2)
end

# Nodes::FillFace::SPLIT_PIXELS: how far into a long stretch it is cut where the distance changes fast.
RG_FACE_SPLIT_PIXELS = 8

# Reference#fast_change?: whether one over the distance, +w+ at a stretch's start and stepping
# +w_step+ a pixel, changes over RG_FACE_SPLIT_PIXELS pixels by more than a sixteenth of +w+.
def rg_face_fast_change?(w, w_step)
  change = rg_mul(w_step, RG_FACE_SPLIT_PIXELS)
  limit = rg_shr(w, 4)
  change > limit || change < rg_sub(0, limit)
end

# Where each colour stands in +shading+'s list of colours, by colour, worked out once for each
# shading drawn with; the first place of a colour listed twice. A lit pixel's colour is looked up
# here (Reference::Shade#color_at), and a colour not in the list stays as it is.
def rg_shading_places_of(shading)
  @rg_shading_places[shading] ||= (0...shading[1]).reverse_each.to_h { |place| [shading[2 + place], place] }
end

# Reference#fill_face_row: one row of a face, from +from+ to +to+ (each x, u, v, w, shade), in
# perspective every +spans+ pixels (none when nought), each pixel through +shading+ when lit.
# +numbers+ is, for a picture given as numbers into the shading's colours, the image of those
# numbers; nil for any other.
#
# NOTHING IS MADE FOR A PIXEL. Every object this makes is one Ruby's garbage collector clears away
# later, and a place of a few thousand faces fills hundreds of thousands of pixels a picture: with a
# pair of arrays made for each one, most of a game's time went on clearing them. So each
# end's numbers and each step are plain variables, and where the C has a routine for a spot in
# perspective (rg_face_place_in_perspective, which would hand back two numbers in an array) its sums
# are written out here, at each end of a stretch. A stretch's step across the picture is worked out
# once for the stretch, which is the same division the C does at every pixel of it.
#
# A ROW PAINTED PLAIN. What rg_set_pixel asks of every pixel (a plain layer handed over, a mix, a
# placed fade, the picture without sprites kept beside, the cell on the screen and in the area) is
# the same for every pixel of a row, and for nearly every row the answer is "none" (rg_painting_plain?).
# Then the row is held to the screen and the area once, before the loop, and each pixel is stored
# straight into its cell, which is marked as no mix where the picture keeps mixes: the cells and
# colours rg_set_pixel would give. Any other row paints through rg_set_pixel, pixel by pixel. The
# shading's places are fetched once a row too, and the shift and mask that find a pixel of the
# picture are written in place: YJIT makes each small method a call of its own, several a pixel.
def rg_face_row(row, from, to, left, right, image, numbers, spans, shading)
  start = rg_shr(rg_add(from[0], (1 << 15) - 1), 16)
  stop = rg_shr(rg_add(to[0], (1 << 15) - 1), 16)
  count = rg_sub(stop, start)
  return if count <= 0

  first = start > left ? start : left
  past = stop < right ? stop : right
  plain = rg_painting_plain?
  if plain
    area = @rg_area
    top, bottom = rg_kept_span(row, row + 1, RG_SCREEN_HEIGHT, area.top, area.bottom, area.in_force)
    return if top >= bottom

    first, past = rg_kept_span(first, past, RG_SCREEN_WIDTH, area.left, area.right, area.in_force)
    return if first >= past

    target = @rg_target
    is_mixed = rg_mixes_of(target)&.is_mixed
    row_at = row * RG_SCREEN_WIDTH
  end
  if shading # Reference::Shade#held_row_end
    from[4] = rg_clamp_wide(from[4], 0, (shading[0] << 16) - 1)
    to[4] = rg_clamp_wide(to[4], 0, (shading[0] << 16) - 1)
    shading_colors = shading[1]
    places = rg_shading_places_of(shading)
  end
  art, at, art_width, art_height = rg_picture_of(image)
  across_mask = art_width - 1
  down_mask = art_height - 1
  numbered, numbered_at, = rg_picture_of(numbers) if numbers
  from_u = from[1]
  from_v = from[2]
  from_w = from[3]
  from_shade = from[4]
  step_u = rg_div(rg_sub(to[1], from_u), count)
  step_v = rg_div(rg_sub(to[2], from_v), count)
  step_w = rg_div(rg_sub(to[3], from_w), count)
  step_shade = rg_div(rg_sub(to[4], from_shade), count)
  # STEPPED, NOT MULTIPLIED. A pixel's u, v and shade are the row's (or the stretch's) start plus a
  # step for every pixel along, wrapped as the game's numbers wrap. Adding the step once a pixel and
  # wrapping the sum gives that same number, since a wrap keeps the low 32 bits of a sum whichever
  # way it was added up; and a stretch of perspective is worked out only as the pixel walk leaves the
  # last one, since every pixel of one has the same ends.
  along = first - start
  if spans.zero?
    u = rg_add(from_u, rg_mul(step_u, along))
    v = rg_add(from_v, rg_mul(step_v, along))
    u_step = step_u
    v_step = step_v
  else
    u = v = u_step = v_step = 0
  end
  shade = rg_add(from_shade, rg_mul(step_shade, along)) if shading
  stretch_past = along # the along the stretch in use ends before: none is in use yet
  painted = false
  x = first
  while x < past
    if along >= stretch_past && !spans.zero?
      # Reference#stretch_ends
      near_along = (along / spans) * spans
      far_along = near_along + spans
      far_along = count if far_along > count
      cut = near_along + RG_FACE_SPLIT_PIXELS
      if far_along > cut && rg_face_fast_change?(rg_add(from_w, rg_mul(step_w, near_along)), step_w)
        if along < cut
          far_along = cut
        else
          near_along = cut
        end
      end
      # Reference#place_in_perspective, at the stretch's near end and at its far one
      distance = rg_face_distance(rg_add(from_w, rg_mul(step_w, near_along)))
      near_u = rg_mul_fix(rg_add(from_u, rg_mul(step_u, near_along)), distance, 14)
      near_v = rg_mul_fix(rg_add(from_v, rg_mul(step_v, near_along)), distance, 14)
      distance = rg_face_distance(rg_add(from_w, rg_mul(step_w, far_along)))
      far_u = rg_mul_fix(rg_add(from_u, rg_mul(step_u, far_along)), distance, 14)
      far_v = rg_mul_fix(rg_add(from_v, rg_mul(step_v, far_along)), distance, 14)
      u_step = rg_div(rg_sub(far_u, near_u), far_along - near_along)
      v_step = rg_div(rg_sub(far_v, near_v), far_along - near_along)
      u = rg_add(near_u, rg_mul(u_step, along - near_along))
      v = rg_add(near_v, rg_mul(v_step, along - near_along))
      stretch_past = far_along
    end
    across = (u >> 16) & across_mask
    down = (v >> 16) & down_mask
    color = art[at + (down * art_width) + across]
    unless color == RG_NOT_DRAWN
      # Reference::Shade#color_at, or #pixel_color_at for a picture of numbers: the colour's place
      # in the shading's list becomes, at the pixel's level (the top sixteen bits of its shade), the
      # colour the level's row of places names.
      if shading
        place = numbers ? numbered[numbered_at + (down * art_width) + across] : places[color]
        color = shading[2 + shading[2 + shading_colors + ((shade >> 16) * shading_colors) + place]] unless place.nil?
      end
      if plain
        target[row_at + x] = color & 0xFFFF
        is_mixed[row_at + x] = 0 if is_mixed
        painted = true
      else
        rg_set_pixel(x, row, color)
      end
    end
    x += 1
    along += 1
    u += u_step
    u = rg_i32(u) if u > RG_INT32_MAX || u < RG_INT32_MIN
    v += v_step
    v = rg_i32(v) if v > RG_INT32_MAX || v < RG_INT32_MIN
    if shading
      shade += step_shade
      shade = rg_i32(shade) if shade > RG_INT32_MAX || shade < RG_INT32_MIN
    end
  end
  @rg_picture_touched = true if painted
end

# Reference#exec_fill_face: one face already on the screen, filled with its picture, each pixel
# through +shading+ unless it is [0] (Computer::Picture#shading_array).
def rg_screen_face(pictures, picture_count, picture, corner_list, corner_count, left, top, right, bottom, spans,
                   shading)
  corner_count = RG_FACE_MOST_CORNERS if corner_count > RG_FACE_MOST_CORNERS
  return if corner_count < 3

  shading = nil if shading[0].zero?
  # The corners' numbers are read straight from the list's slots when the list holds them all, and
  # else through rg_list_get, which stops the game at the first it does not hold.
  held = corner_list.length >= corner_count * 6
  front = corner_list.front
  capacity = corner_list.capacity
  corners = Array.new(corner_count) do |k|
    corner = if held
               slot = front + (k * 6)
               [corner_list.item(slot % capacity), corner_list.item((slot + 1) % capacity),
                corner_list.item((slot + 2) % capacity), corner_list.item((slot + 3) % capacity),
                corner_list.item((slot + 4) % capacity), corner_list.item((slot + 5) % capacity)]
             else
               Array.new(6) { |field| rg_list_get(corner_list, (k * 6) + field) }
             end
    # Reference::Shade#shaded_corner: the light held to 0..LIGHTEST, times the levels
    corner[5] = rg_mul(rg_clamp_wide(corner[5], 0, 0xFFFF), shading[0]) if shading
    unless spans.zero? # Reference::FaceEdges.in_perspective
      corner[2] = rg_mul_fix(corner[2], corner[4], 28)
      corner[3] = rg_mul_fix(corner[3], corner[4], 28)
    end
    corner
  end
  image = pictures[rg_clamp_wide(picture, 0, picture_count - 1)]
  left = 0 if left.negative?
  top = 0 if top.negative?
  right = RG_SCREEN_WIDTH if right > RG_SCREEN_WIDTH
  bottom = RG_SCREEN_HEIGHT if bottom > RG_SCREEN_HEIGHT
  edges = corner_count.times.filter_map do |k|
    a = corners[k]
    b = corners[(k + 1) % corner_count]
    next if a[1] == b[1]

    a[1] < b[1] ? rg_face_edge(a, b) : rg_face_edge(b, a)
  end
  return if edges.empty?

  # After the levels' places, a lit fill lists, for each of its pictures, the image of its numbers
  # into the shading's colours, or -1 for a picture of colours.
  numbers = nil
  if shading
    numbered = shading[2 + shading[1] + (shading[0] * shading[1]) + rg_clamp_wide(picture, 0, picture_count - 1)]
    numbers = numbered unless numbered.negative?
  end
  first = [edges.map(&:first_row).min, top].max
  past = [edges.map(&:past_row).max, bottom].min
  # Each row's two ends are chosen by their x alone, and only those two edges' crossings are worked
  # out whole: a row costs no array for an edge that is not one of its ends.
  edge_count = edges.length
  row = first - 1
  while (row += 1) < past
    from_edge = to_edge = nil
    from_x = to_x = 0
    crossing = 0
    k = 0
    while k < edge_count
      edge = edges[k]
      k += 1
      next unless edge.crosses?(row)

      x = rg_face_crossing_x(edge, row)
      crossing += 1
      # the leftmost is the first of the leftmost, the rightmost the last of the rightmost
      if from_edge.nil? || x < from_x
        from_edge = edge
        from_x = x
      end
      if to_edge.nil? || x >= to_x
        to_edge = edge
        to_x = x
      end
    end
    next if crossing < 2

    rg_face_row(row, rg_face_crossing(from_edge, row), rg_face_crossing(to_edge, row), left, right, image, numbers,
                spans, shading)
  end
end
