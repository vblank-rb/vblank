#!/usr/bin/env ruby
# frozen_string_literal: true

# Wanderers — several people at one game. Up to four players walk around a little walled
# meadow, each with the D-pad of their own controller, each drawn in a colour the game picked
# for them at random the moment they joined. There is nothing to attack and nowhere to get to:
# it is the smallest game where several people play at once, and it grows as playing together
# does (joining from another machine is next).
#
# What it shows off, all through the friendly DSL and never a hardware register:
#   * MORE THAN ONE PLAYER — `held(:left, player: 3)` reads the third player's controller. The
#     four walkers are made by a plain Ruby loop while the game is built, one pass of it per
#     seat, so each one's code reads its own player's buttons.
#   * WHO IS HERE — `players_connected` says how many players are connected now. A player counts
#     from the first time any of their buttons goes down, so a seat nobody has taken is not
#     drawn and not given a colour, and a player who lets go of everything stays.
#   * HOW MANY SEATS — `players:` says how many players the game takes on each build. A game
#     played on a computer (as C, in a web page, or as Ruby) reads sixteen controllers, and here
#     it takes four; a cartridge reads the controllers its console has. The game says four once,
#     and `most_players` hands that number back while the game is built, to make the walkers.
#   * RANDOM COLOURS EVERYBODY AGREES ON — the colours come from the game's random numbers
#     (`rand`), which start from the game's own `seed`. Nothing about them comes from outside
#     the game, so the same presses pick the same colours every time, and two machines playing
#     one match from one seed draw everybody in the same colours.
#   * RECOLOURING — every walker is the same picture; `draw_with` dresses each in its own list
#     of colours, picked by a number the game worked out.
#   * WHICH ONE IS ME — in a match over a network, each machine shows an arrow over its own
#     walker (`drawing_for_local_player` and `mark`), and the game stays the same on every machine.
#
# THE CONSOLES. It is for the Game Boy Advance and the Game Boy Color, as one player. Both
# consoles read one controller, so a cartridge for either is a one-player walk round the meadow:
# `players: { computer: 1..4, else: 1 }` says four seats on a computer and one on a cartridge,
# and `most_players` makes the matching number of walkers. They are here rather than left
# out because a game played on a computer is still built AS a console — its screen size and its
# picture rules are that console's — so the computer builds of this game are the Advance's and
# the Color's, laid out for each screen. The Super Nintendo (two controllers) is left out for now:
# its cartridge cannot yet tell whether a second controller is plugged in, so it refuses
# `players_connected`.
#
# Players do not block each other: two walkers can stand in the same place, and one walks
# straight through another. Two players may also be given the same colour, as two dice can
# land the same way.
#
# Run it to build examples/wanderers.gba and examples/wanderers.gbc:
#   ruby examples/wanderers.rb
# or play four on a computer, with a controller each (the first controller is player 1, the next
# player 2, and so on), or two at one keyboard: player 1 on the arrows, player 2 on I J K L:
#   vblank run examples/wanderers.rb

require_relative "../lib/vblank"

module Wanderers
  # The most players a computer build seats. A cartridge seats one.
  SEATS_ON_A_COMPUTER = 4
  SPEED = 1 # pixels a frame
  SIZE  = 8 # a walker is one 8x8 tile

  # The colours a walker can be given, one picked at random as its player joins.
  COLORS = %i[red green blue yellow cyan magenta orange white].freeze

  # What a player's colour number holds before they join: no colour picked yet.
  NOT_PICKED = -1

  # WHERE EVERYTHING GOES, worked out from the size of the screen the game is built for — the
  # Advance's 240×160 or the Color's 160×144. The meadow fills the screen inside a one-tile
  # wall, and the four players start in a square in the middle, a tile apart.
  Layout = Data.define(:width, :height) do
    def floor_x = (8..(width - 8 - SIZE))
    def floor_y = (8..(height - 8 - SIZE))

    def starts
      middle_x = width / 2
      middle_y = height / 2
      [[middle_x - 16, middle_y - 16], [middle_x + 8, middle_y - 16],
       [middle_x - 16, middle_y + 8], [middle_x + 8, middle_y + 8]]
    end

    # The map, a row of characters for each row of tiles: wall all round, grass inside, and a
    # flower here and there.
    def meadow
      cols = width / 8
      rows = height / 8
      (0...rows).map do |row|
        (0...cols).map do |col|
          if row.zero? || col.zero? || row == rows - 1 || col == cols - 1 then "#"
          elsif ((row * 7) + (col * 3)) % 11 == 0 then "*"
          else "."
          end
        end.join
      end
    end
  end

  # A little walker: a round head with two eyes, a body, and two legs. '#' is the walker's own
  # colour and 'o' its eyes; '.' is see-through.
  WALKER_ART = <<~ART
    ..####..
    .######.
    .#o##o#.
    .######.
    ..####..
    .######.
    .#....#.
    .#....#.
  ART

  # The arrow over this machine's own walker, pointing down at it.
  YOU_ARROW_ART = <<~ART
    ........
    .######.
    .######.
    ..####..
    ..####..
    ...##...
    ...##...
    ........
  ART

  GAME = VBlank.game("WANDERERS", consoles: %i[gba gbc], players: { computer: 1..SEATS_ON_A_COMPUTER, else: 1 }) do
    screen :tiled # a background for the meadow, and the console's own sprites for the walkers
    here = Layout.new(width: screen_width, height: screen_height)

    # How many walkers this build makes: four on a computer, one on a cartridge. It is the number
    # `players:` gives this build, so no line below reads a player the build does not seat.
    seats = most_players

    # Whether to mark which walker is this machine's own. A test that wants every machine of a match
    # to show one picture turns it off, since that mark is the one thing that differs.
    show_you_mark = setting :you_mark, true

    # The random numbers start here. Every build of the game starts from the same seed, so the
    # same presses always pick the same colours; a match played across several machines will
    # hand them all one seed, and they will all agree.
    seed 7

    # --- the meadow, out of three 8x8 tiles and a map ---
    image :wall, "#" => :gray, "." => rgb(9, 9, 9) do
      <<~ART
        ########
        #......#
        ########
        ...####.
        ########
        .####...
        ########
        #......#
      ART
    end
    image :grass, "." => rgb(3, 10, 3), "," => rgb(5, 14, 5) do
      <<~ART
        ........
        ..,.....
        ........
        .....,..
        ........
        .,......
        ........
        ......,.
      ART
    end
    image :flower, "." => rgb(3, 10, 3), "o" => rgb(28, 20, 24), "y" => rgb(30, 26, 8) do
      <<~ART
        ........
        ...o....
        ..oyo...
        ...o....
        ........
        ........
        ........
        ........
      ART
    end
    tiles :meadow, "#" => :wall, "." => :grass, "*" => :flower
    background :meadow, tiles: :meadow, map: here.meadow

    # --- the walkers: one picture, worn in different colours ---
    # `colors:` is the walker's own list, see-through first. A list given to `draw_with` swaps
    # colours BY PLACE, so a list whose second colour is red draws the walker's body red and
    # keeps its eyes black.
    image :walker, "." => :transparent, "#" => :gray, "o" => :black,
                   colors: %i[transparent gray black] do
      WALKER_ART
    end
    outfits = COLORS.map do |color|
      colors :"walker_#{color}", [:transparent, color, :black]
      :"walker_#{color}"
    end

    # One walker for each seat, hidden until its player joins, and one colour number for each,
    # holding NOT_PICKED until then. Each walker is named by its player's number and shows the one
    # walker image, so a bot or a test reads the first player's as `game.sprite(:walker1)`.
    walkers = (1..seats).map do |player|
      sprite :"walker#{player}", image: :walker, at: here.starts[player - 1], shown: false
    end
    colors_picked = (1..seats).map { |player| var(:"hue#{player}", NOT_PICKED) }

    # Which walker is mine: a little arrow over it, on this machine only. Who "me" is is different
    # on each machine of a match, so it may only change what is drawn: the block is held to drawing,
    # and nothing the game remembers can depend on it. A `mark` has no place of its own to remember;
    # it is shown over its walker, wherever the walker is, while the `if` around it holds. A
    # cartridge seats one player, so it has no arrow to show.
    if show_you_mark && seats > 1
      image :you_arrow, "#" => :white, "." => :transparent do
        YOU_ARROW_ART
      end
      drawing_for_local_player do |me|
        walkers.each.with_index(1) { |walker, player| mark over: walker, with: :you_arrow if me == player }
      end
    end

    game_loop do
      # Plain Ruby, run while the game is built: the loop body is written out once for each
      # seat, with `player` a fixed number in each copy.
      walkers.each.with_index(1) do |walker, player|
        picked = colors_picked[player - 1]

        if players_connected >= player
          # Just joined: pick a colour from the game's random numbers, once.
          picked.store!(rand(0...COLORS.size)) if picked < 0
          walker.draw_with outfits, showing: picked
          walker.show

          # Walk with this player's own D-pad. Nobody blocks anybody: there is no test
          # against the other walkers at all.
          walker.move :left,  by: SPEED if held(:left, player: player)
          walker.move :right, by: SPEED if held(:right, player: player)
          walker.move :up,    by: SPEED if held(:up, player: player)
          walker.move :down,  by: SPEED if held(:down, player: player)
          walker.x.clamp! here.floor_x.min, here.floor_x.max # keep inside the wall
          walker.y.clamp! here.floor_y.min, here.floor_y.max
        else
          walker.hide
        end
      end
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Wanderers::GAME.write_if_main
