# frozen_string_literal: true

# The player's ship and its single shot — one part of the shmup, in its own file.
#
# It's a plain Ruby object. The only thing that makes it "part of the game" is that it
# takes the build (what VBlank.build hands your block as `self`) and calls the DSL
# verbs on it — build.sprite, build.held, build.var — the same verbs you'd write at the
# top level, just spelled `build.` here because inside this object `self` is the Player,
# not the build. No base class, no magic.
module Shmup
  class Player
    SPEED = 2
    SHOT_SPEED = 4
    NOSE = 6 # where the shot leaves the ship (its horizontal centre, roughly)
    SAFE = 60 # frames after losing a ship that the next one cannot be hit

    # `#` is the hull and `=` the cockpit.
    SHIP = <<~ART
      .......##.......
      .......##.......
      ......####......
      ......####......
      .....######.....
      .....######.....
      ....###==###....
      ....###==###....
      ...####==####...
      ...####==####...
      ..############..
      ..############..
      .##############.
      .##############.
      ################
      ################
    ART

    SHOT = <<~ART
      ..####..
      ..####..
      ..####..
      ..####..
      ..####..
      ..####..
      ..####..
      ..####..
    ART

    # The ship's two looks: level, and leaning into a turn, its wing tips drawn in.
    BANKED = SHIP.lines.map { |row| row.sub(/\A#/, ".").sub(/#(\n?)\z/, '.\1') }.join.freeze

    def initialize(build)
      @build = build
      # The ship's own list of colours, in order. Other lists swap them by place, so the
      # warm pulse's second colour lands on the hull and its third on the cockpit.
      build.colors :hull, [:transparent, :cyan, :white]
      build.image(:ship_art, "." => :transparent, "#" => :cyan, "=" => :white, colors: :hull) { SHIP + BANKED }
      build.image(:shot, "." => :transparent, "#" => :white) { SHOT }
      # The ship is four tiles of sprite memory, which its one pose is drawn from, top left
      # first. The game loads them from either look of its art, so turning is four tiles
      # copied from the cartridge and nothing else: the pose, and the sprite showing it, are
      # the same whichever look is in the tiles (see `sprite_tiles` in .claude/dsl/sprites.md).
      @ship_tiles = build.sprite_tiles(:ship_tiles, count: 4, colors: :hull)
      build.image(:ship, tiles_from: :ship_tiles, pieces: [[0, 0, 0], [8, 0, 1], [0, 8, 2], [8, 8, 3]])
      # A pose drawn from tiles the game loads has no pixels until it runs, so the ship is
      # tested for touching by its box.
      @ship = build.sprite(:ship, at: [112, 132])
      @look = build.var(:ship_look, -1) # which look is in the tiles: 0 level, 1 banked
      show_look 0
      @shot = build.sprite(:shot, at: [0, 0], shown: false)
      @shot_live = build.var(:shot_live, 0) # 1 while a shot is in flight
      @safe = build.var(:ship_safe, 0)      # frames left that the ship cannot be hit
    end

    # Other parts test collisions against these, and read where the ship is.
    attr_reader :ship, :shot, :shot_live

    # Whether anything can hurt the ship right now — a test, for the parts that hurt it.
    def hittable = (@safe <= 0)

    # A ship was lost: the next one cannot be hit for a moment.
    def hurt
      @safe = SAFE
    end

    # Steer, keep on screen, fire, and fly the shot — one frame's worth.
    def update
      @ship.move :left,  by: SPEED if @build.held(:left)
      @ship.move :right, by: SPEED if @build.held(:right)
      @ship.clamp_to_screen # keep the ship on screen — it works out its own size
      if @build.held(:left) || @build.held(:right)
        show_look 1
      else
        show_look 0
      end

      glow_while_safe
      fire_when_ready
      fly_the_shot
    end

    # Let an enemy that got shot take the shot out of play, so the player can fire again.
    def reclaim_shot
      @shot.hide
      @shot_live = 0
    end

    private

    # Load the look numbered +look+ into the ship's tiles, unless they hold it already: four
    # tiles of the art, from that look's first tile on.
    def show_look(look)
      if @look != look
        @look = look
        @ship_tiles.copy_from :ship_art, at: look * 4, count: 4, to: 0
      end
    end

    # While the ship cannot be hit it pulses warm, and then it is its own colours again.
    # The pulse steps every four frames, so `(@safe >> 2) & 3` walks through the four
    # lists and round again; the ship's picture is the same picture throughout.
    def glow_while_safe
      if @safe > 0
        @safe -= 1
        @ship.draw_with WARM, showing: (@safe >> 2) & 3
      else
        @ship.draw_with :own
      end
    end

    def fire_when_ready
      if @shot_live == 0
        if @build.pressed(:a)
          @shot.move_to @ship.x + NOSE, @ship.y - 6
          @shot.show
          @shot_live = 1
        end
      end
    end

    def fly_the_shot
      if @shot_live == 1
        @shot.move 0, -SHOT_SPEED # travel up
        reclaim_shot if @shot.above_top? # gone off the top: ready to fire again
      end
    end
  end
end
