#!/usr/bin/env ruby
# frozen_string_literal: true

# Two Rooms — a stone room with a doorway, and a brick room through it.
#
# Cube 3D draws every face of its place on every frame. A game made of many rooms cannot afford
# that: most of its rooms are hidden behind walls. So this game works out for itself which rooms
# it can see, and draws only those, the way the old first-person games did:
#
# - The room you stand in is always seen.
# - The room beyond the doorway is seen only through the doorway. The game asks where each corner
#   of the doorway lands on the screen (`screen_spot`), and the box round those corners is the
#   WINDOW the far room is seen through. If the doorway is behind you, the far room is not drawn
#   at all.
# - The far room is drawn first, held to its window (`window:`), and then the near room over it.
#   Each room's faces are a list of face numbers the game keeps (`faces:`).
#
# Fly with A (ahead) and B (back), turn with LEFT and RIGHT. Fly through the doorway and the rooms
# change places: the brick room is the near one, and the stone room is seen through the doorway.
# Build it:
#   ruby examples/two_rooms.rb

require_relative "../lib/vblank"

module TwoRooms
  # A wall picture 16 by 16 pixels: blocks with a line of mortar round each.
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

  # The four corners of a whole picture, top left first and round to the right.
  WHOLE = Ractor.make_shareable([[0, 0], [16, 0], [16, 16], [0, 16]])

  # Where the doorway's sides are, across and up. The doorway is in the wall between the rooms,
  # two wholes ahead of where you start.
  DOOR_LEFT = -0.5
  DOOR_RIGHT = 0.5
  DOOR_TOP = 0.5
  BETWEEN = 2.0

  # The rooms, as numbers the game keeps in a variable.
  STONE = 0
  BRICK = 1

  GAME = VBlank.game("TWO ROOMS", consoles: %i[gba]) do
    screen :bitmap, tear_free: true
    image :stone, "#" => rgb(8, 8, 9), "." => rgb(20, 20, 22) do
      BLOCKS
    end
    image :brick, "#" => rgb(14, 12, 10), "." => rgb(24, 8, 4) do
      BLOCKS
    end
    image :ground, "#" => rgb(6, 10, 4), "." => rgb(10, 16, 6) do
      BLOCKS
    end

    # The face numbers of each room, and the doorway's four corners, filled in by the place.
    stone_faces = []
    brick_faces = []
    doorway = []

    place :rooms do
      # Each face's corners go round clockwise as seen from inside its room.
      wall = lambda do |picture, *corners|
        face(*corners.map { |x, y, z| point(x, y, z) }, picture: picture, on_picture: WHOLE)
      end

      # The stone room: four wholes across, from two wholes behind you to the doorway's wall.
      stone_faces << wall.call(:stone, [-2.0, 1.0, BETWEEN], [DOOR_LEFT, 1.0, BETWEEN], [DOOR_LEFT, -1.0, BETWEEN],
                               [-2.0, -1.0, BETWEEN])
      stone_faces << wall.call(:stone, [DOOR_RIGHT, 1.0, BETWEEN], [2.0, 1.0, BETWEEN], [2.0, -1.0, BETWEEN],
                               [DOOR_RIGHT, -1.0, BETWEEN])
      stone_faces << wall.call(:stone, [DOOR_LEFT, 1.0, BETWEEN], [DOOR_RIGHT, 1.0, BETWEEN],
                               [DOOR_RIGHT, DOOR_TOP, BETWEEN], [DOOR_LEFT, DOOR_TOP, BETWEEN])
      stone_faces << wall.call(:stone, [-2.0, 1.0, -2.0], [-2.0, 1.0, BETWEEN], [-2.0, -1.0, BETWEEN], [-2.0, -1.0, -2.0])
      stone_faces << wall.call(:stone, [2.0, 1.0, BETWEEN], [2.0, 1.0, -2.0], [2.0, -1.0, -2.0], [2.0, -1.0, BETWEEN])
      stone_faces << wall.call(:stone, [2.0, 1.0, -2.0], [-2.0, 1.0, -2.0], [-2.0, -1.0, -2.0], [2.0, -1.0, -2.0])
      stone_faces << wall.call(:ground, [-2.0, -1.0, BETWEEN], [2.0, -1.0, BETWEEN], [2.0, -1.0, -2.0], [-2.0, -1.0, -2.0])

      # The brick room: three wholes across, from the doorway's wall four wholes on.
      brick_faces << wall.call(:brick, [-1.5, 1.0, 6.0], [1.5, 1.0, 6.0], [1.5, -1.0, 6.0], [-1.5, -1.0, 6.0])
      brick_faces << wall.call(:brick, [-1.5, 1.0, BETWEEN], [-1.5, 1.0, 6.0], [-1.5, -1.0, 6.0], [-1.5, -1.0, BETWEEN])
      brick_faces << wall.call(:brick, [1.5, 1.0, 6.0], [1.5, 1.0, BETWEEN], [1.5, -1.0, BETWEEN], [1.5, -1.0, 6.0])
      brick_faces << wall.call(:brick, [1.5, 1.0, BETWEEN], [DOOR_RIGHT, 1.0, BETWEEN], [DOOR_RIGHT, -1.0, BETWEEN],
                               [1.5, -1.0, BETWEEN])
      brick_faces << wall.call(:brick, [DOOR_LEFT, 1.0, BETWEEN], [-1.5, 1.0, BETWEEN], [-1.5, -1.0, BETWEEN],
                               [DOOR_LEFT, -1.0, BETWEEN])
      brick_faces << wall.call(:brick, [DOOR_RIGHT, 1.0, BETWEEN], [DOOR_LEFT, 1.0, BETWEEN],
                               [DOOR_LEFT, DOOR_TOP, BETWEEN], [DOOR_RIGHT, DOOR_TOP, BETWEEN])
      brick_faces << wall.call(:ground, [-1.5, -1.0, 6.0], [1.5, -1.0, 6.0], [1.5, -1.0, BETWEEN], [-1.5, -1.0, BETWEEN])

      # The doorway's corners. No face joins them: the doorway is a hole.
      doorway.concat([[DOOR_LEFT, DOOR_TOP], [DOOR_RIGHT, DOOR_TOP], [DOOR_RIGHT, -1.0], [DOOR_LEFT, -1.0]]
                       .map { |x, y| point(x, y, BETWEEN) })
    end

    stone = list :stone_faces, capacity: stone_faces.length
    stone_faces.each { |number| stone.push number }
    brick = list :brick_faces, capacity: brick_faces.length
    brick_faces.each { |number| brick.push number }

    eye = viewer :eye, at: [0.0, 0.0, 0.0]

    # What the game worked out this frame: which room you are in, the window the other room is
    # seen through, and how many rooms it drew.
    here = var :here, STONE
    left = var :left, 0
    top = var :top, 0
    right = var :right, 0
    bottom = var :bottom, 0
    behind = var :behind, 0
    rooms_drawn = var :rooms_drawn, 0

    game_loop do
      eye.turn :left, by: 2 if held(:left)
      eye.turn :right, by: 2 if held(:right)
      eye.move :ahead, by: 0.05 if held(:a)
      eye.move :back, by: 0.05 if held(:b)

      here = BRICK
      here = STONE if eye.spot[2] < BETWEEN

      # Where each of the doorway's corners lands, from where the viewer is now.
      corners = doorway.map { |point| screen_spot :rooms, point, seen_by: eye }

      # The box round the doorway's corners on the screen. A corner behind you means you are in
      # the doorway, so the other room is seen through the whole screen; all four behind you means
      # the doorway is behind you, and the other room is not seen.
      left = screen_width
      top = screen_height
      right = 0
      bottom = 0
      behind = 0
      corners.each do |corner|
        if corner.behind?
          behind += 1
        else
          left = corner.x if corner.x < left
          right = corner.x if corner.x > right
          top = corner.y if corner.y < top
          bottom = corner.y if corner.y > bottom
        end
      end
      if behind > 0
        left = 0
        top = 0
        right = screen_width
        bottom = screen_height
      end

      clear_screen :black
      rooms_drawn = 1
      if behind < 4 && left < right && top < bottom
        rooms_drawn = 2
        if here == STONE
          draw_place :rooms, seen_by: eye, faces: brick, window: [left, top, right, bottom]
        else
          draw_place :rooms, seen_by: eye, faces: stone, window: [left, top, right, bottom]
        end
      end
      if here == STONE
        draw_place :rooms, seen_by: eye, faces: stone
      else
        draw_place :rooms, seen_by: eye, faces: brick
      end

      # How many rooms this frame drew, in the corner.
      draw_number rooms_drawn, 4, 4, :white, digits: 1
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

TwoRooms::GAME.write_if_main
