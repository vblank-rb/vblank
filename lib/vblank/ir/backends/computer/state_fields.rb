# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      module Computer
        # THE RUNTIME'S FIELDS IN THE STATE IMAGE, in the order each runtime visits them
        # (runtime/rg_state.h). The game's own fields — every global the build wrote, every list —
        # the build finds for itself (Lowering#visit_state); these are what each runtime keeps in
        # its own variables, which the C, JavaScript and Ruby runtimes each name by hand. So they
        # are listed here once, and a test plays a game on each runtime and fails naming any field
        # that runtime writes that is not here, or that is here and it does not write: the three
        # cannot drift apart, and an image written by one reads on the others.
        #
        # +count+ is how many numbers the field holds, or a Symbol for a count the game or its console
        # decides: :save_size (a byte of save memory each), :screen_cells (a pixel of the screen each),
        # :three_screens (three numbers a pixel), :run_pixels (a pixel of every run the game paints
        # into each), :runs (one a run), or a count the field before it holds (:scenery_put_up,
        # :held_tiles, four a change), the game's backgrounds (:backgrounds, 21 each), or what those
        # hold (:own_cells, a cell of each copy; :bent_lines, a screen's lines each), and the sprites
        # (:sprites_drawn and :sprites_kept, ten each; :sprite_cuts, two a slice; :sprite_places,
        # three for each sprite there is room for).
        # +with_save_memory+ marks a field only a game that reaches save memory keeps, and +feature+
        # one only a game that takes in that runtime feature keeps
        # (RuntimeFeatures; each visits its own through the visit_state hook, in the order the
        # features are joined).
        #
        # A feature with no field here keeps nothing a frame boundary needs: light works its rows out
        # again after every wait, before the next picture is read; columns paints and keeps nothing;
        # faces keeps only tables it works out from the game's colours.
        module StateFields
          Field = Data.define(:name, :count, :with_save_memory, :feature) do
            def initialize(name:, count:, with_save_memory: false, feature: nil)
              super
            end
          end

          MOST_PLAYERS = IR::Buttons::MOST_PLAYERS
          MOST_TIMERS = 32
          TIMER_NUMBERS = 5 # started, running, its rate, its frames a second, how far it has ticked
          AREAS_DEEP = 64 # the most `inside` areas open at once
          MOST_SEE_THROUGH = 16 # the most see-through layers a screen has

          FIELDS = [
            Field.new(name: "runtime.buttons.held", count: MOST_PLAYERS),
            Field.new(name: "runtime.buttons.seen", count: MOST_PLAYERS),
            Field.new(name: "runtime.buttons.pressed", count: MOST_PLAYERS),
            Field.new(name: "runtime.players.connected", count: 1),
            Field.new(name: "runtime.timers", count: MOST_TIMERS * TIMER_NUMBERS),
            Field.new(name: "runtime.timers.order", count: MOST_TIMERS + 1),
            # present, set, moved by frames, the seconds, the ticks, and the days and seconds a game set
            Field.new(name: "runtime.clock", count: 7),
            Field.new(name: "runtime.motor", count: 3), # frames left, the pattern, whether it runs
            Field.new(name: "save.memory", count: :save_size, with_save_memory: true),
            Field.new(name: "save.wiping", count: 1, with_save_memory: true),
            # The pages drawn into, shown and painted (first, second, or 2 the scenery), whether the
            # display is held, a frame begun, the kind of screen, a rebuild owed and skipped, the picture
            # touched, the backdrop, the scene shown, the scenery kept, a sprite being painted, the
            # pass's end placing writes, scenery taken down, the window's corner, and a mixed cell's
            # two shares.
            Field.new(name: "screen", count: 19),
            Field.new(name: "screen.page.first", count: :screen_cells),
            Field.new(name: "screen.page.second", count: :screen_cells),
            Field.new(name: "screen.scenery", count: :screen_cells),
            Field.new(name: "screen.without_sprites", count: :screen_cells),
            # Whether each cell is a mix, then what was painted, then what was under it.
            Field.new(name: "screen.mixes.picture", count: :three_screens),
            Field.new(name: "screen.mixes.scenery", count: :three_screens),
            # How many areas are open, then the area in force and each one around it: in force, left,
            # top, right, bottom.
            Field.new(name: "screen.areas", count: 1 + (5 * (AREAS_DEEP + 1))),
            # Each see-through layer's shares kept for an owed rebuild, then those last told: kept, and
            # the two shares.
            Field.new(name: "screen.shares", count: 2 * 3 * MOST_SEE_THROUGH),
            Field.new(name: "screen.runs.places", count: :run_pixels),
            Field.new(name: "screen.runs.painted", count: :runs),
            # The fade toward black or white and its steps; the tint's way (none, toward black or
            # white, toward a colour), toward white, its colour, steps, and whether the display mixes
            # it; a fade placed in the stack (in force, the layer's place, toward white, steps); and
            # where the fade reaches (the whole screen, inside or outside) and its rectangle.
            Field.new(name: "fades", count: 16, feature: :fades),
            # The size of the blocks things are painted in, and of those a painted screen is read in.
            Field.new(name: "pixelation", count: 2, feature: :pixelation),
            # Whether backgrounds are shown from their corners this pass and whether that pass has
            # ended, how many times scenery has been put up, and how many tile changes wait.
            Field.new(name: "tiled", count: 4, feature: :tiled),
            Field.new(name: "tiled.shown", count: :scenery_put_up, feature: :tiled), # each background put up, in order
            Field.new(name: "tiled.held", count: :held_tiles, feature: :tiled), # background, column, row, tile
            # For each background, what its name keeps: whether it has its own cells, the map they copy
            # and the background whose map it is, the scroll, shown from its corner, the colours
            # named, the box, the turn, the status bar's place, covering the sprites, and bends kept.
            Field.new(name: "tiled.backgrounds", count: :backgrounds, feature: :tiled),
            Field.new(name: "tiled.cells", count: :own_cells, feature: :tiled), # each own copy of a map, in turn
            Field.new(name: "tiled.bends", count: :bent_lines, feature: :tiled), # a screen's lines for each bend worked out
            # How many sprites were last put on screen and how many are kept for a rebuild, and
            # whether the layer over a painted picture is up.
            Field.new(name: "sprites", count: 3, feature: :sprites),
            # Each sprite: its number, picture, place, level, turn (turned, angle, size, resizes), and
            # how many slices a crowded line leaves out, then those slices, a line and a piece each.
            Field.new(name: "sprites.drawing", count: :sprites_drawn, feature: :sprites),
            Field.new(name: "sprites.drawing.cuts", count: :sprite_cuts, feature: :sprites),
            Field.new(name: "sprites.kept", count: :sprites_kept, feature: :sprites),
            Field.new(name: "sprites.kept.cuts", count: :sprite_cuts, feature: :sprites),
            # Whether each sprite was last drawn straight onto the picture, and where.
            Field.new(name: "sprites.drawn_places", count: :sprite_places, feature: :sprites),
            Field.new(name: "sprites.over_picture", count: :screen_cells, feature: :sprites)
          ].freeze

          # The fields a game's state holds besides its own, in order: those of a game that reaches
          # save memory with +save_memory+, else the rest, and of the runtime features named in
          # +features+.
          def self.kept(save_memory:, features: [])
            FIELDS.select do |field|
              (save_memory || !field.with_save_memory) && (field.feature.nil? || features.include?(field.feature))
            end
          end
        end
      end
    end
  end
end
