# frozen_string_literal: true

require "test_helper"
require "stringio"

# How fast the PlayStation draws a view of many small rooms, measured in Beetle PSX
# (Diagnostics::PS1Profiler). A first-person game of rooms (the old 3D games of the console's day)
# walks from the room it stands in through each doorway it can see, and draws every room it found
# with a call of its own, far first, each held to the window its doorway makes on the screen. A
# view down a corridor is many such calls, each of a few faces, and the console's own games drew
# one at thirty pictures a second.
class TestPS1ManyRoomsPace < Minitest::Test
  ROOMS = 17
  # The rooms drawn in perspective, nearest first; those past it are drawn straight.
  IN_PERSPECTIVE = 8
  # The corners of every room: four where each room meets the next, and four at the far end.
  CORNERS = (ROOMS + 1) * 4

  BLOCKS = <<~ART
    ################
    #......##......#
    #......##......#
    #......##......#
    #......##......#
    #......##......#
    #......##......#
    ################
    ################
    ###......##.....
    ###......##.....
    ###......##.....
    ###......##.....
    ###......##.....
    ###......##.....
    ################
  ART

  # A wall two wholes square shows its picture four times each way.
  WALL = Ractor.make_shareable([[0, 0], [64, 0], [64, 64], [0, 64]])

  # A corridor of ROOMS rooms, each two wholes wide, high and long, with walls and a floor, a ceiling
  # in every fourth room, and a wall at its end: about 55 faces. The viewer stands in the first room
  # and sways a little left and right, looking down it.
  CORRIDOR = VBlank.game("MANY ROOMS", consoles: %i[ps1]) do
    screen :bitmap, tear_free: true
    image :stone, "#" => rgb(8, 8, 9), "." => rgb(20, 20, 22) do
      BLOCKS
    end
    image :ground, "#" => rgb(6, 10, 4), "." => rgb(10, 16, 6) do
      BLOCKS
    end

    faces_of = Array.new(ROOMS) { [] }
    place :corridor do
      # Where a room meets the next: four corners, top left and round to the right.
      planes = (0..ROOMS).map do |k|
        [[-1.0, 1.0], [1.0, 1.0], [1.0, -1.0], [-1.0, -1.0]].map { |x, y| point(x, y, k * 2.0) }
      end
      ROOMS.times do |i|
        top_left, top_right, bottom_right, bottom_left = planes[i]
        far_top_left, far_top_right, far_bottom_right, far_bottom_left = planes[i + 1]
        faces_of[i] << face(top_left, far_top_left, far_bottom_left, bottom_left, picture: :stone, on_picture: WALL)
        faces_of[i] << face(far_top_right, top_right, bottom_right, far_bottom_right, picture: :stone, on_picture: WALL)
        faces_of[i] << face(far_bottom_left, far_bottom_right, bottom_right, bottom_left, picture: :ground, on_picture: WALL)
        faces_of[i] << face(top_left, top_right, far_top_right, far_top_left, picture: :ground, on_picture: WALL) if (i % 4).zero?
      end
      faces_of[ROOMS - 1] << face(*planes[ROOMS], picture: :stone, on_picture: WALL)
    end

    starts = faces_of.each_with_object([0]) { |faces, at| at << (at.last + faces.length) }
    face_start = table :face_start, starts
    face_number = table :face_number, faces_of.flatten
    spot_x = list :spot_x, capacity: CORNERS, full_of: 0
    spot_y = list :spot_y, capacity: CORNERS, full_of: 0
    spot_behind = list :spot_behind, capacity: CORNERS, full_of: 0
    win_left = list :win_left, capacity: ROOMS, full_of: 0
    win_top = list :win_top, capacity: ROOMS, full_of: 0
    win_right = list :win_right, capacity: ROOMS, full_of: 0
    win_bottom = list :win_bottom, capacity: ROOMS, full_of: 0
    # With the setting, each room is drawn with the faces of the two rooms nearer than the one before it
    # as well, as a game whose rooms list more faces than can be seen through a doorway does. Seen
    # down the corridor those rooms lie round the doorway the room is seen through, wholly outside its
    # window, and are passed over before they are tested for which way they face or sent.
    neighbours = setting :neighbours, false
    drawn = list :drawn, capacity: 16

    eye = viewer :eye, at: [0.0, 0.0, 0.5]
    phase = var :phase, 0
    seen = var :seen, 1
    open = var :open, 1
    left = var :left, 0
    top = var :top, 0
    right = var :right, 0
    bottom = var :bottom, 0
    behind = var :behind, 0
    at = var :at, 0
    first = var :first, 0
    past = var :past, 0
    each_face = var :each_face, 0

    eye.turn :right, by: 12
    game_loop do
      if phase < 24
        eye.turn :left, by: 1
      else
        eye.turn :right, by: 1
      end
      phase += 1
      phase = 0 if phase == 48

      # Every room's eight corners put on the screen first, as a game of rooms does before it walks:
      # the four where a room meets the one before, and the four where it meets the next.
      repeat(ROOMS) do |room|
        repeat(8) do |c|
          corner = screen_spot :corridor, (room * 4) + c, seen_by: eye
          spot_x[(room * 4) + c] = corner.x
          spot_y[(room * 4) + c] = corner.y
          spot_behind[(room * 4) + c] = 0
          spot_behind[(room * 4) + c] = 1 if corner.behind?
        end
      end

      # The walk: each room's window is the box round its doorway's corners, inside the window of the
      # room before; the first doorway it cannot see through ends it.
      win_left[0] = 0
      win_top[0] = 0
      win_right[0] = screen_width
      win_bottom[0] = screen_height
      seen = 1
      open = 1
      repeat(ROOMS - 1) do |j|
        if open == 1
          left = screen_width
          top = screen_height
          right = 0
          bottom = 0
          behind = 0
          # The points are declared a doorway at a time, four each, so doorway k's are k * 4 on.
          4.times do |c|
            if spot_behind[((j + 1) * 4) + c] == 1
              behind += 1
            else
              left = spot_x[((j + 1) * 4) + c] if spot_x[((j + 1) * 4) + c] < left
              right = spot_x[((j + 1) * 4) + c] if spot_x[((j + 1) * 4) + c] > right
              top = spot_y[((j + 1) * 4) + c] if spot_y[((j + 1) * 4) + c] < top
              bottom = spot_y[((j + 1) * 4) + c] if spot_y[((j + 1) * 4) + c] > bottom
            end
          end
          if behind > 0
            left = win_left[j]
            top = win_top[j]
            right = win_right[j]
            bottom = win_bottom[j]
          end
          left = win_left[j] if left < win_left[j]
          top = win_top[j] if top < win_top[j]
          right = win_right[j] if right > win_right[j]
          bottom = win_bottom[j] if bottom > win_bottom[j]
          if left < right && top < bottom
            win_left[j + 1] = left
            win_top[j + 1] = top
            win_right[j + 1] = right
            win_bottom[j + 1] = bottom
            seen += 1
          else
            open = 0
          end
        end
      end

      # The rooms seen, far first, each its own drawing held to its window.
      repeat(seen) do |back|
        at = seen - 1 - back
        repeat(drawn.length) { drawn.pop }
        if neighbours
          first = at - 3
          first = 0 if first < 0
          past = at - 1
          past = 0 if past < 0
          each_face = face_start[first]
          repeat(face_start[past] - face_start[first]) do
            drawn.push face_number[each_face]
            each_face += 1
          end
        end
        each_face = face_start[at]
        repeat(face_start[at + 1] - face_start[at]) do
          drawn.push face_number[each_face]
          each_face += 1
        end
        window = [win_left[at], win_top[at], win_right[at], win_bottom[at]]
        if at < IN_PERSPECTIVE
          draw_place :corridor, seen_by: eye, faces: drawn, window: window, perspective: :every_8_pixels
        else
          draw_place :corridor, seen_by: eye, faces: drawn, window: window, perspective: :none
        end
      end
    end
  end

  # The bar the console's own games set: a new picture every two frames or better, every pass.
  def test_a_corridor_of_many_rooms_runs_at_thirty_a_second
    result = profile

    assert_operator result.passes_by_frames.keys.max, :<=, 2, result.passes_by_frames.inspect
  end

  # ...with room to spare in the second frame for what a real game of rooms does besides: its own walk
  # through the rooms it can see, and their doors and things. This scene is lighter than the heaviest
  # view of such a game, so it ends each pass a third of a frame or more before the second blank: a
  # pass that ran closer than that here ran past it there.
  MOST_LINES_PAST_BLANK = VBlank::Diagnostics::PS1Profiler::FRAME_LINES / 3

  def test_a_corridor_of_many_rooms_leaves_room_in_its_second_frame
    past = profile.lines_past_blank.fetch(2, [0])

    assert_operator past.max, :<=, MOST_LINES_PAST_BLANK, "lines past the first blank: #{past.minmax}"
  end

  # A face wholly outside the window it is drawn through is passed over once it is cut, before it is tested for
  # which way it faces or sent: drawing each room with two more rooms' faces, nearly three times the
  # faces, most of them outside its window, costs under a third again of the processor's time.
  def test_faces_outside_a_rooms_window_cost_under_a_third_again
    own = profile
    with_neighbours = profile(neighbours: true)

    assert_operator busy_frames(with_neighbours), :<, busy_frames(own) * 4 / 3.0
  end

  # How much of a frame the processor was at work for, a pass.
  private def busy_frames(result) = (1 - result.idle_share) * result.frames / result.passes

  private def profile(**settings)
    rom = CORRIDOR.build_rom(console: :ps1, settings: settings, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, frames: 48)
  end
end
