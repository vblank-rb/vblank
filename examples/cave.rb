#!/usr/bin/env ruby
# frozen_string_literal: true

# Cave — a lantern in the dark, and a circle that closes on you between places.
#
# The hero walks a cave with a lantern. Around them the cave is drawn as it is; past the
# lantern's reach it is nearly black, and the light goes wherever they go. Walk out of
# the cave mouth on the right and the screen closes in a circle on the hero until it is
# black, the meadow outside is put up while nobody can see it, and the circle opens again
# onto daylight. Walk back in on the left of the meadow and the same happens the other
# way, with the lantern lit again.
#
# Two verbs do all of that. `spotlight` is the light: declared once, moved with its handle.
# `iris_out` and `iris_in` close it on a point and open it again — the pair to `fade_out`
# and `fade_in`, said the same way, and `iris_shut?` is the moment to swap the scene.
#
# And as the circle opens the hero comes up out of the black, a little brighter each frame,
# their colours walked there by `color_walk` and `recolor`. A fade would raise everything by the
# same share, so their dark colours would show almost at once. A walk moves each colour one
# step at a time, so the brightest parts of the hero arrive first and the dark ones last.
#
# Notice what you never write: the console's windows, its darkening, which row of the
# screen the circle starts and stops on. The console really does all of it as it draws —
# the light costs the same however much is on screen — and none of it is in this file.
#
# Arrows walk.
#
# Run it to build examples/cave.gba:
#   ruby examples/cave.rb

require_relative "../lib/vblank"

module Cave
  # One screen of cave, 30 cells by 20, with its mouth in the right-hand wall.
  CAVE = <<~MAP
    ##############################
    ##.......####..........#######
    #.........##............######
    #..~~~..................######
    #..~~~~.......##..............
    #...~~.......####.............
    #.............##..............
    #.......................##...#
    #......##...............##...#
    #......##.....................
    #.............................
    #....................###.....#
    #...##...............###.....#
    #...##.......~~~.............#
    #...........~~~~~............#
    #............~~~.......##....#
    ##....................####..##
    ###..........##........##..###
    #####.......####..........####
    ##############################
  MAP

  # ...and the meadow outside, with the way back in on its left.
  MEADOW = <<~MAP
    ,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,
    ,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,
    ,,,,,,,,,,,,,,,,,,,,~~~~,,,,,,
    ,,,,,,,,,,,,,,,,,,,~~~~~~,,,,,
    ................,,,,~~~~,,,,,,
    .................,,,,,,,,,,,,,
    ..................,,,,,,,,,,,,
    ,,,,,,,,,,,,,......,,,,,,,,,,,
    ,,,,,,,,,,,,,,......,,,,,,,,,,
    ,,,,,,,,,,,,,,,......,,,,,,,,,
    ,,,,,,,,,,,,,,,,......,,,,,,,,
    ,,,,,,,,,,,,,,,,,......,,,,,,,
    ,,,,,,,,,,,,,,,,,,......,,,,,,
    ,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,
    ,,,,,,,,~~~,,,,,,,,,,,,,,,,,,,
    ,,,,,,,~~~~~,,,,,,,,,,,,,,,,,,
    ,,,,,,,,~~~,,,,,,,,,,,,,,,,,,,
    ,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,
    ,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,
    ,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,
  MAP

  # Where the hero walks out of one and into the other, in pixels. Coming back in, they
  # stand in the mouth itself, on row 10 of the cave, which has no rock from end to end.
  CAVE_MOUTH_X = 232
  CAVE_MOUTH_Y = 80
  MEADOW_EDGE_X = 0

  # How far the lantern reaches, and how dark the cave is past it.
  LANTERN_REACH = 36
  CAVE_DARK = 85

  GAME = VBlank.game("CAVE", consoles: %i[gba]) do
    screen :tiled

    image :rock, "#" => rgb(12, 10, 9), "." => rgb(7, 6, 5) do
      <<~ART
        .######.
        ########
        ###.####
        ########
        ####.###
        ########
        ##.#####
        .######.
      ART
    end

    image :floor, "." => rgb(14, 11, 7), "o" => rgb(18, 14, 9) do
      <<~ART
        ........
        ...o....
        ........
        ......o.
        ........
        .o......
        ........
        ....o...
      ART
    end

    image :grass, "," => rgb(6, 20, 6), "'" => rgb(10, 26, 8) do
      <<~ART
        ,,,,,,,,
        ,',,,,',
        ,,,,,,,,
        ,,,',,,,
        ,,,,,,,,
        ',,,,,',
        ,,,,,,,,
        ,,',,,,,
      ART
    end

    image :water, "~" => rgb(4, 10, 22), "-" => rgb(10, 18, 28) do
      <<~ART
        ~~~~~~~~
        ~--~~~~~
        ~~~~~~~~
        ~~~~~--~
        ~~~~~~~~
        ~~--~~~~
        ~~~~~~~~
        ~~~~~~--
      ART
    end

    # The hero's own list of colours, in order: a list made to replace them matches them by place.
    image :hero, "." => :transparent, "o" => :yellow, "#" => :red, colors: %i[transparent yellow red] do
      <<~ART
        ..oooo..
        ..oooo..
        ...oo...
        .######.
        #.####.#
        ..####..
        ..#..#..
        .##..##.
      ART
    end

    tiles :ground, "#" => :rock, "." => :floor, "," => :grass, "~" => :water, solid: ["#", "~"]
    land = background :land, tiles: :ground, map: { cave: CAVE, meadow: MEADOW }

    hero = sprite :hero, at: [24, CAVE_MOUTH_Y]
    hero.blocked_by land

    # The hero's colours, as a list of their own the game can change. `color_walk` works out the
    # steps from black to that list while the cartridge is built, and `recolor` below says
    # which step the list holds now, so walking is one number going up.
    colors :clothes, %i[transparent yellow red]
    hero.draw_with :clothes
    out_of_the_dark = color_walk :clothes, from: :black
    arrived = out_of_the_dark.length - 1 # the last step is the hero's own colours
    step = arrived

    # The lantern: everything past its reach is nearly black. It starts on the hero and
    # follows them every frame below.
    lantern = spotlight at: [28, CAVE_MOUTH_Y + 4], radius: LANTERN_REACH, dark: CAVE_DARK

    # 1 while the circle is closing on the way out of one place and into the other — the
    # flag `iris_shut?` is read with, so the scene is swapped once.
    leaving = false

    game_loop do
      unless leaving
        hero.move :left, by: 1 if held(:left)
        hero.move :right, by: 1 if held(:right)
        hero.move :up, by: 1 if held(:up)
        hero.move :down, by: 1 if held(:down)
      end
      hero.clamp_to_screen
      lantern.move_to hero.x + 4, hero.y + 4
      step += 1 if step < arrived
      recolor :clothes, out_of_the_dark, showing: step

      # Out of the cave mouth, or back in at the meadow's edge: close the circle on the hero.
      in_cave = land.showing == land.map_number(:cave)
      leaving_cave = in_cave && hero.x >= CAVE_MOUTH_X
      entering_cave = land.showing == land.map_number(:meadow) && hero.x <= MEADOW_EDGE_X
      if !leaving && (leaving_cave || entering_cave)
        leaving = true
        iris_out at: [hero.x + 4, hero.y + 4], frames: 24
      end

      # Shut: nobody can see, so put up the other place, stand the hero at its edge, and
      # open the circle onto it — daylight outside, the lantern's dark back in the cave.
      if leaving && iris_shut?
        leaving = false
        step = 0
        if land.showing == land.map_number(:cave)
          land.show_map :meadow
          hero.move_to MEADOW_EDGE_X + 8, hero.y
          iris_in frames: 24, dark: 0
        else
          land.show_map :cave
          hero.move_to CAVE_MOUTH_X - 8, CAVE_MOUTH_Y
          iris_in frames: 24, radius: LANTERN_REACH, dark: CAVE_DARK
        end
      end
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Cave::GAME.write_if_main
