# frozen_string_literal: true

# THE FACES OF A PLACE (Reference#exec_fill_face): one flat face of a 3D shape, already on the screen,
# filled row by row with a picture, in perspective and lit. Joined into the runtime's class after
# rg_screen.rb for a game that draws a place. rg_faces.c says how, rule for rule; this is that file
# written again, method for method.
#
# The screen never asks it anything: the game calls rg_screen_face.

# Where each colour stands in a shading's list of colours, worked out once for each shading drawn with
# (rg_shaded_color); named here so the game's shape never changes in play.
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
  edge.at.each_with_index.map { |start, part| rg_add(start, rg_mul(edge.step[part], rows)) }
end

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
  parts = [rg_shl(rg_sub(bottom[0], top[0]), 12), *(2..5).map { |field| rg_sub(bottom[field], top[field]) }]
  starts = [rg_shl(top[0], 12), *top[2..5]]
  RgFaceEdge.new(first_row: first_row, past_row: past_row,
                 at: starts.zip(parts).map { |start, part| rg_add(start, rg_mul_fix(part, into, 24)) },
                 step: parts.map { |part| rg_mul_fix(part, along_row, 24) })
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

# Reference::Shade#color_at: the colour +color+ becomes at +shade+ (its level in the top sixteen
# bits). A colour not in the shading's list stays as it is. Where each colour stands in the list is
# worked out once for each shading drawn with.
def rg_shaded_color(shading, color, shade)
  colors = shading[1]
  places = @rg_shading_places[shading] ||= (0...colors).reverse_each.to_h { |place| [shading[2 + place], place] }
  place = places[color]
  return color if place.nil?

  rg_shaded_place(shading, place, shade)
end

# Reference::Shade#pixel_color_at: the colour place +place+ of the shading's colours becomes at
# +shade+.
def rg_shaded_place(shading, place, shade)
  colors = shading[1]
  level = rg_shr(shade, 16)
  shading[2 + shading[2 + colors + (level * colors) + place]]
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
def rg_face_row(row, from, to, left, right, image, numbers, spans, shading)
  start = rg_shr(rg_add(from[0], (1 << 15) - 1), 16)
  stop = rg_shr(rg_add(to[0], (1 << 15) - 1), 16)
  count = rg_sub(stop, start)
  return if count <= 0

  if shading # Reference::Shade#held_row_end
    from[4] = rg_clamp_wide(from[4], 0, (shading[0] << 16) - 1)
    to[4] = rg_clamp_wide(to[4], 0, (shading[0] << 16) - 1)
  end
  art, at, art_width, art_height = rg_picture_of(image)
  numbered, numbered_at, = rg_picture_of(numbers) if numbers
  from_u = from[1]
  from_v = from[2]
  from_w = from[3]
  from_shade = from[4]
  step_u = rg_div(rg_sub(to[1], from_u), count)
  step_v = rg_div(rg_sub(to[2], from_v), count)
  step_w = rg_div(rg_sub(to[3], from_w), count)
  step_shade = rg_div(rg_sub(to[4], from_shade), count)
  near_at = -1
  near_u = near_v = stretch_step_u = stretch_step_v = 0
  first = start > left ? start : left
  past = stop < right ? stop : right
  (first...past).each do |x|
    along = rg_sub(x, start)
    if spans.zero?
      u = rg_add(from_u, rg_mul(step_u, along))
      v = rg_add(from_v, rg_mul(step_v, along))
    else
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
      unless near_along == near_at
        # Reference#place_in_perspective, at the stretch's near end and at its far one
        distance = rg_face_distance(rg_add(from_w, rg_mul(step_w, near_along)))
        near_u = rg_mul_fix(rg_add(from_u, rg_mul(step_u, near_along)), distance, 14)
        near_v = rg_mul_fix(rg_add(from_v, rg_mul(step_v, near_along)), distance, 14)
        distance = rg_face_distance(rg_add(from_w, rg_mul(step_w, far_along)))
        far_u = rg_mul_fix(rg_add(from_u, rg_mul(step_u, far_along)), distance, 14)
        far_v = rg_mul_fix(rg_add(from_v, rg_mul(step_v, far_along)), distance, 14)
        stretch_step_u = rg_div(rg_sub(far_u, near_u), far_along - near_along)
        stretch_step_v = rg_div(rg_sub(far_v, near_v), far_along - near_along)
        near_at = near_along
      end
      u = rg_add(near_u, rg_mul(stretch_step_u, along - near_along))
      v = rg_add(near_v, rg_mul(stretch_step_v, along - near_along))
    end
    across = rg_and(rg_shr(u, 16), art_width - 1)
    down = rg_and(rg_shr(v, 16), art_height - 1)
    color = art[at + (down * art_width) + across]
    next if color == RG_NOT_DRAWN

    if shading
      shade = rg_add(from_shade, rg_mul(step_shade, along))
      color = if numbers
                rg_shaded_place(shading, numbered[numbered_at + (down * art_width) + across], shade)
              else
                rg_shaded_color(shading, color, shade)
              end
    end
    rg_set_pixel(x, row, color)
  end
end

# Reference#exec_fill_face: one face already on the screen, filled with its picture, each pixel
# through +shading+ unless it is [0] (Computer::Picture#shading_array).
def rg_screen_face(pictures, picture_count, picture, corner_list, corner_count, left, top, right, bottom, spans,
                   shading)
  corner_count = RG_FACE_MOST_CORNERS if corner_count > RG_FACE_MOST_CORNERS
  return if corner_count < 3

  shading = nil if shading[0].zero?
  corners = Array.new(corner_count) do |k|
    corner = Array.new(6) { |field| rg_list_get(corner_list, (k * 6) + field) }
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
  (first...past).each do |row|
    from = nil
    to = nil
    crossing = 0
    edges.each do |edge|
      next unless edge.crosses?(row)

      at = rg_face_crossing(edge, row)
      crossing += 1
      # the leftmost is the first of the leftmost, the rightmost the last of the rightmost
      from = at if from.nil? || at[0] < from[0]
      to = at if to.nil? || at[0] >= to[0]
    end
    rg_face_row(row, from, to, left, right, image, numbers, spans, shading) if crossing >= 2
  end
end
