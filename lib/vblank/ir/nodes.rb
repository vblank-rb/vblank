# frozen_string_literal: true

module VBlank
  module IR
    # ONE CLASS PER KIND OF NODE. Each declares what it is and what operands it carries, and
    # gets a real reader for each of them — so asking a pixel for its width is a
    # NoMethodError at the line that asked, not a nil that travels.
    #
    # +operands+ declares the names AND what each one must hold. A tag of :value marks a
    # wrapped operand, which may be a number known while authoring or one the game works
    # out as it runs; every other tag names an author-time literal of a stated type. The
    # names give accessors and the tags are what {Verifier} checks, so the two cannot
    # drift — they are the same declaration.
    #
    # The behaviour every node shares (children, parent, walking, categories) is mixed in
    # from {Node} and names no kind, so nothing here is known to it.
    module Nodes

      class Abs
        include Node
        kind :abs
        category :var
        operands var: :name
      end

      class Add
        include Node
        kind :add
        category :var
        operands var: :name, operand: :value
      end

      class After
        include Node
        kind :after
        category :control
        operands counter: :name, frames: :int
      end

      # A grid of tiles. +map+ is the grid showing when the program starts. +maps+ is every
      # grid this background can be handed (the first of them being +map+), for a background
      # declared with several — a room per map, a floor per map — and empty for one declared
      # with a single map, which can never change. See ShowMap.
      #
      # +scene+ is the game state this belongs to, where it was declared inside one, and
      # nil for scenery every screen shows. It carries the same fact an Object's +scene+
      # does and for the same reason: a target with a finite number of places to put a
      # layer needs to know which layers are wanted AT THE SAME TIME, and two scenes that
      # take turns never are. See IR::Stacking#screenfuls.
      #
      # +palettes+ is every list of colours this background's tiles were drawn from, each once,
      # and +recolors+ the other ways they can be drawn, in the order BackgroundColors counts
      # them: each one a list for every entry of +palettes+, at the same place, which that
      # list's tiles are then drawn from instead. Both are empty for a background only ever
      # drawn in its own colours. A tile keeps its own places whichever list it reads, the
      # way Object's operand of the same name works for one picture. +palette_names+ is the
      # name each of +palettes+ was declared under, at the same place, nil where its tiles were
      # given the colours themselves: two lists named apart are two lists even when they hold
      # the same colours, so a tile finds its own by #drawn_lists.
      #
      # +choice+ names the variables that hold which of +maps+ is showing, empty where there is
      # only one. A background that belongs to a scene is put up as declared each time that
      # scene takes over, so every one of them goes back to 0, the first map, at that moment:
      # left alone they would name the map chosen on the last visit while the cells hold the
      # first, and choosing that map again would be taken as already done.
      #
      # +sets+, on a background whose maps draw from more than one SET of tiles, names each
      # set; +set_starts+ is where each one's tiles begin in +tiles+, and +map_sets+ gives which
      # set each of +maps+ draws from. A map's cells only ever name tiles of its own set. A
      # target that has room for only one set at a time brings a map's set in with the map;
      # one that draws every tile by name needs none of this. All three are absent on a
      # background drawn from one set.
      class Background
        include Node
        kind :background
        category :draw
        # +bar_top+ makes it a STATUS BAR: fixed to the screen from that row down to the bottom,
        # in front of every other background and behind every sprite, never scrolled (see
        # PlaceBar for how it moves). Absent on every other background.
        #
        # +above_row+ shows it only on the rows of the screen above that row. Below it the background
        # is not drawn at all and what is behind shows. Absent on every other background.
        #
        # +boxed+, on a background the game holds to a box (BoxBackground), names the variable that
        # holds whether it is held to one now. It goes back to 0, shown everywhere, as the scene the
        # background belongs to takes over, as +choice+ does. Absent on every other background.
        #
        # +follows+, on a background drawn with a list of colours the game changes (ColorList),
        # names that list. Its +recolors+ are then the sets the list can hold, counted as the list
        # counts them, and its colours are what the list holds: a target whose backgrounds and
        # sprites read one table of colours can draw it from the list's own place in that table.
        # Absent on every other background.
        operands name: :name, tiles: :list, map: :list, maps: :list, choice: :list, tile_w: :int,
                 tile_h: :int, layer: :name, scene: :name, affine: :flag, recolors: :list, palettes: :list,
                 palette_names: :list, sets: :list, set_starts: :list, map_sets: :list, bar_top: :int,
                 above_row: :int, boxed: :name, follows: :name

        # Each of +palettes+ as a tile drawn from it gives which list it was drawn from
        # (Bitmap#list_drawn_from): its name and its colours.
        def drawn_lists = palettes.each_with_index.map { |colors, at| [palette_names&.at(at), colors] }

        # Which of #drawn_lists is drawn with the list it +follows+: the only one, or, beside other
        # lists, the one of that name (every other stays as drawn). nil on a background that follows none.
        def followed_list_index
          return nil unless follows

          palettes.one? ? 0 : palette_names.index(follows)
        end

        # Which of #drawn_lists a tile drawn from +drawn+ (its name and colours) takes its other
        # colours from: its own, or — for a tile given the colours themselves, beside tiles given
        # the list by name — the list of the layer that holds them.
        def recolored_list_of(drawn) = drawn_lists.include?(drawn) ? drawn : drawn_lists.find { |_, colors| colors == drawn.last }

        # Each list a tile can be drawn from to the list it is drawn with at step +step+ of
        # +recolors+, a tile given the colours themselves included (#recolored_list_of).
        def list_swaps(step)
          swaps = drawn_lists.zip(recolors.fetch(step)).to_h
          drawn_lists.each { |_, colors| swaps[[nil, colors]] ||= swaps[recolored_list_of([nil, colors])] }
          swaps
        end

        # The variable that holds which of a background's sets is in place now, one a target
        # with room for a single set keeps. Named here so every part of the program that resets
        # it as a scene takes over names the same one.
        def self.set_var(name) = :"__bg_#{name}_set"

        # The variable that holds which list of colours a background told `draw_with` is really
        # drawn with now, written in the gap between frames (BackgroundColors).
        def self.live_colors_var(name) = :"__bg_#{name}_live_colors"

        # For a background brought into view a strip at a time (see #streams?): which map the
        # cells around the view are copied from, and whether they hold it yet — 0 until they
        # are, which asks a target that copies strips for the whole view again. Only such a
        # target reads them.
        def self.stream_vars(name) = [:"__bg_#{name}_streamed", :"__bg_#{name}_filled"]

        # The two variables a background's scroll position is kept in, x then y, in pixels.
        def self.scroll_vars(name) = [:"__bg_#{name}_sx", :"__bg_#{name}_sy"]

        def several_sets? = !sets.nil? && !sets.empty?

        # Which tiles of +tiles+ belong to set number +set+.
        def set_tiles(set) = (set_starts[set]...(set_starts[set + 1] || tiles.length))

        # Every map this background can show: +maps+, or +map+ alone where there is one.
        def every_map = maps.nil? || maps.empty? ? [map] : maps

        # Whether its maps are brought into view a strip at a time (see IR::TileMap.streams?).
        def streams? = TileMap.streams?(every_map)

        # Whether it is a status bar (see +bar_top+).
        def bar? = !bar_top.nil?

        # The variable a status bar's top row is kept in, which the gap between frames shows.
        def self.bar_top_var(name) = :"__bar_#{name}_top"
        def self.bar_covers_var(name) = :"__bar_#{name}_covers"

        # The variables a box a background is held to is kept in: its left, top, width and height
        # in pixels, then whether it is held to the box at all (0 shows it everywhere).
        def self.box_vars(name) = %i[x y w h held].map { |part| :"__bg_#{name}_box_#{part}" }
      end

      # A BACKGROUND SHOWN ONLY INSIDE A BOX on the screen, +x+ and +y+ its top-left corner and
      # +width+ and +height+ its size, in pixels; each may be worked out as the program runs.
      # Outside the box the background is not drawn at all, and what is behind it shows. Sprites
      # are not held to it. A box past the screen's edges is the part of it on the screen, and a
      # width or height of 0 or less shows the background nowhere. +held+ of 0 shows it everywhere
      # again, the box set aside.
      #
      # Written in the gap between frames, as a scroll is, so the picture shows it from the frame
      # after. Telling a background that is not up changes nothing.
      class BoxBackground
        include Node
        kind :box_background
        category :draw
        operands name: :name, x: :value, y: :value, width: :value, height: :value, held: :value
      end

      # WHERE A STATUS BAR'S TOP IS, in screen rows: the bar covers the screen from there to the
      # bottom. A row past the bottom puts the whole bar out of view, and one above the top is
      # the top. Written in the gap between frames, as a scroll is, so the picture shows it from
      # the frame after; until a bar is first placed after it is put up, it shows at the row it
      # was declared with. Placing a background that is not a status bar changes nothing.
      #
      # +covers+, in a game that asks for it, is whether the bar hides the sprites from its top down
      # (nought shows them), written in the same gap; nil is a bar nobody told, which shows them.
      class PlaceBar
        include Node
        kind :place_bar
        category :draw
        operands name: :name, top: :value, covers: :maybe_value
      end

      # A background's tiles all draw from a different list of colours — the whole layer at
      # once, where an Object's +recolor+ does it for one picture. +which+ counts from 0
      # through the lists the background was given, and may be worked out as the program
      # runs; a number naming none of them is the background's own colours.
      #
      # Every pixel keeps the place it was drawn at and only the colour that place shows
      # changes, which is what lets one set of tiles be a dozen times of day.
      class BackgroundColors
        include Node
        kind :background_colors
        category :draw
        operands name: :name, which: :value
      end

      # A background's cells all become one of its other maps — a whole room at once, where
      # SetTile changes one cell. +which+ counts from 0 through the maps the background was
      # declared with, and may be worked out as the program runs. The cells become the map
      # exactly as it was declared, so anything SetTile had changed in them is gone.
      class ShowMap
        include Node
        kind :show_map
        category :draw
        operands name: :name, which: :value
      end

      # EVERY CELL CHANGE HELD SINCE THE LAST ONE OF THESE, SHOWN NOW, together and in the order
      # they were made (see SetTile's +held+). The builder puts one at each frame boundary of a
      # game with a background declared `held: true`, among the boundary's other writes, so a
      # pass's changes all appear on one frame.
      #
      # The changes wait in one queue for the whole program, of at most +cells+ changes. A change
      # made with the queue full shows every change waiting first, there and then, and then waits
      # itself: so past +cells+ changes in a pass, the first +cells+ show on the frame being drawn.
      # A background put up (as declared, by its scene or at power-on) forgets the changes still
      # waiting for it, since the cells they were made to are gone; the changes waiting for every
      # other background are kept, in order.
      class ShowHeldTiles
        include Node
        kind :show_held_tiles
        category :draw
        operands cells: :int

        # How many changes the queue holds: a whole 32 by 32 map's worth, a cell each. A pass
        # that changes more than that is changing a whole map, which is what show_map is for.
        MOST_CELLS = 1024
      end

      # A RUN OF TILES WHOSE PIXELS COME FROM A LIST THE GAME OWNS, rather than from a
      # picture fixed while the program is built. +tiles+ names them in order — a background's
      # map names them like any other tile — and +list+ is where their pixels are kept: tile k
      # is the 32 bytes from k × 32, each byte two pixels, the left one in the low four bits,
      # each of those a place in +colors+ (place 0 is see-through). The tiles start
      # see-through and show what the list holds only after a CopyTiles.
      #
      # A run can instead be ONE PICTURE a sprite shows: +picture+ names it, +width+ and
      # +height+ are its size in pixels, and its tiles are the list's 32-byte runs taken left
      # to right and then top to bottom — the order a sprite's tiles are kept in. +tiles+ is
      # empty for one of those, and +picture+ nil for a run a background shows.
      class TileRun
        include Node
        kind :tile_run
        declaration!
        category :data
        operands name: :name, list: :name, tiles: :list, colors: :list, picture: :name, width: :int,
                 height: :int, colors_name: :name, console_format: :flag, held_in: :name, tile_side: :int

        # A run of `tile_pictures` names the table its list only ever copies from, in +held_in+. A
        # console that can read that table with its copying engine is free to take the bytes from
        # there rather than through the list (see GBA::BackgroundDrawing#emit_copy_painted_run).

        # How many 8×8 squares its list keeps for one tile: one, or four for a tile of +tile_side+
        # 16, left to right and then down.
        def squares_per_tile = (tile_side / 8)**2

        # The list of colours its tiles are drawn from, as a background's recolouring keeps them
        # apart (Assets::Image#list_drawn_from).
        def list_drawn_from = [colors_name, colors]
      end

      # Show a TileRun's list on its tiles: every tile of the run takes the pixels its bytes
      # of the list hold now. Where a program is paced by frames this sits in the gap between
      # them, so a picture is never seen half copied.
      class CopyTiles
        include Node
        kind :copy_tiles
        category :draw
        operands name: :name
      end

      # Copy every run in +runs+ whose list the game marked moved, as one step. Which runs those
      # are is kept as bits of the variables in +masks+: run number +i+ is bit
      # +i % RUNS_PER_MASK+ of +masks[i / RUNS_PER_MASK]+. Thirty to a variable, so a mask
      # never reaches the sign bit. The bits are only read here; clearing them is the program's.
      class CopyOwedTiles
        include Node
        kind :copy_owed_tiles
        category :draw
        operands runs: :list, masks: :list

        RUNS_PER_MASK = 30
      end

      # A SET OF SPRITE TILES THE GAME REWRITES AS IT RUNS: +count+ tiles of 8×8, drawn from
      # +colors+ by place (place 0 see-through), each see-through until the game first loads it.
      # No sprite shows the set itself. Its poses (TilePose) each draw some of its tiles, so a
      # tile loaded again changes every pose that draws it, and a pose costs no tiles of its own.
      class SpriteTiles
        include Node
        kind :sprite_tiles
        declaration!
        category :data
        operands name: :name, count: :int, colors: :list, colors_name: :name

        # The list of colours its tiles are drawn from, as a sprite's recolouring keeps them
        # apart (Assets::Image#list_drawn_from).
        def list_drawn_from = [colors_name, colors]
      end

      # A PICTURE A SPRITE SHOWS, MADE OF TILES OF A SpriteTiles SET: +pieces+ are each
      # [dx, dy, tile], the set's tile +tile+ with its top left at (dx, dy) in the picture, on
      # the picture's 8-pixel grid. Places no piece covers are see-through. The picture is
      # +width+ by +height+, as far as its pieces reach. It shows what the set's tiles hold
      # now, so it has no pixels of its own.
      class TilePose
        include Node
        kind :tile_pose
        declaration!
        category :data
        operands name: :name, tiles: :name, pieces: :list, width: :int, height: :int
      end

      # Load +count+ tiles of a SpriteTiles set from the cartridge: tiles +to+ onwards of the set
      # +name+ take the pixels of tiles +at+ onwards of the table +table+, whose bytes keep a
      # tile as painted tiles do (32 bytes: eight rows of four, two places a byte, the left one in
      # the low four bits). The tiles change where the load is written, so they are in the
      # picture of the pass that wrote it, as a painted run's `changed now: true` is: a console
      # whose picture memory cannot be written while it draws copies them in the gap after the
      # pass, before that picture is shown. A load that reaches past the end of the set or of the
      # table changes nothing.
      class LoadSpriteTiles
        include Node
        kind :load_sprite_tiles
        category :draw
        operands name: :name, table: :name, at: :value, to: :value, count: :int

        # Bytes a tile of the table takes.
        TILE_BYTES = 32

        # THE MOST LOADS ONE PASS CAN MAKE, on every build. A console whose picture memory cannot be
        # written while it draws copies a pass's loads in the short gap after it, which holds this
        # many; a pass that loads more stops the game, saying so (IR::Faults.too_many_sprite_tile_loads).
        MOST_IN_A_PASS = 8
      end

      # The per-frame write that turns and resizes an affine background as a whole (see
      # ScrollBackground, its sibling for plain panning). +angle+ is degrees clockwise,
      # +scale+ is in Build::SCALE_ONE-ths (1.0 = drawn size) — the same units a hardware
      # sprite's rotation/scale carry, so both go through the shared {IR::Affine} rules.
      #
      # +around_x+/+around_y+ are the point the picture turns around, in screen pixels —
      # the one place that stays still while the rest swings or grows about it, and the
      # place the same point of the picture keeps landing on. The middle of the screen
      # unless the program sets another. They are settled while the program is written
      # rather than worked out as it runs, so they are plain numbers on the statement.
      class AffineBackground
        include Node
        kind :affine_background
        category :draw
        operands name: :name, angle: :value, scale: :value,
                 around_x: :int, around_y: :int
      end

      # One cell of a declared background becomes a different tile, while the game runs —
      # a door opening, a pot breaking, a wall a bomb took out. +col+ and +row+ are cell
      # coordinates and may be worked out as the game runs; +tile+ is which of the
      # background's own tiles goes there, settled while the program is written. +now+ asks for
      # the change on the frame being drawn, on the rows still to come, and changes nothing about
      # what the program means: a console showing every pass whole shows the cell the same.
      # +held+ keeps the change for the next ShowHeldTiles instead, for a background declared
      # `held: true`: its cell shows on the frame every other change of the pass shows on.
      class SetTile
        include Node
        kind :set_tile
        category :draw
        operands name: :name, col: :value, row: :value, tile: :int, now: :flag, held: :flag
      end

      class BackingBuffer
        include Node
        kind :backing_buffer
        declaration!
        category :data
        operands name: :name, width: :int, height: :int
      end

      class Beep
        include Node
        kind :beep
        category :sound
        operands tone: :tone, duty: :option, decay: :option, volume: :int
      end

      class Binop
        include Node
        kind :binop
        category :value
        operands op: :option, lhs: :value, rhs: :value
      end

      # Every bit of a number turned the other way — a 1 where there was a 0 and a 0
      # where there was a 1. Its own kind rather than an operator because it takes one
      # operand, exactly as +neg+ does.
      class BitNot
        include Node
        kind :bit_not
        category :value
        operands operand: :value
      end

      # How far a number is from nought: the number, or the number the other way round when
      # it is below nought. A new number — the +abs+ statement changes a variable instead.
      class Absolute
        include Node
        kind :absolute
        category :value
        operands operand: :value
      end

      # A number held inside a range: +min+ when it is below it, +max+ when it is above it,
      # and itself in between. A new number — the +clamp+ statement changes a variable instead.
      class Clamped
        include Node
        kind :clamped
        category :value
        operands operand: :value, min: :value, max: :value
      end

      class Bitmap
        include Node
        kind :bitmap
        declaration!
        category :data
        operands name: :name, width: :int, height: :int, pixels: :text, transparent: :int,
                 colors: :list, places: :text, colors_name: :name, pieces: :list,
                 shading: :name, shading_places: :text, from_file: :file_picture, places_from_pack: :flag

        # +places_from_pack+ is true for a picture whose places are a data pack slot's tiles, kept as the
        # original keeps them (Assets::Image#places_from_pack).
        #
        # +from_file+ is where in the file the program is handed as it starts (StartFile) this
        # picture's colours and places are, for a picture read from there; it holds zeros until
        # then. Absent on every other picture.

        # The list of colours it was drawn from, as a background's recolouring keeps them apart
        # (Assets::Image#list_drawn_from).
        def list_drawn_from = [colors_name, colors]

        # A picture given as numbers into a shading's colours (Builder#image with +shading+) keeps
        # each pixel's number, two bytes a pixel, in +shading_places+: two numbers of one colour
        # that darken apart are told apart by it. A face lit by +shading+ darkens each pixel by
        # its own number's levels; nothing else reads them, and every other drawing draws +pixels+.
        #
        # The numbers, one a pixel, when +shading_name+ is the shading they count into; else nil.
        def places_in_shading(shading_name)
          shading_places&.unpack("v*") if shading && shading == shading_name
        end
      end

      class Blit
        include Node
        kind :blit
        category :draw
        operands name: :name, x: :value, y: :value
      end

      class BlitPose
        include Node
        kind :blit_pose
        category :draw
        operands poses: :list, index: :value, x: :value, y: :value
      end

      class Call
        include Node
        kind :call
        category :control
        operands target: :name

        def callees = [target]
      end

      # Call ONE of +targets+, picked by +which+ — a number counting from 0 through the list,
      # which may be worked out as the program runs. A number naming no routine in the list,
      # below 0 or past its end, calls nothing.
      #
      # Case's sibling, and the difference is what each costs. A case asks its values one at a
      # time, so a long one is a long run of questions; this goes straight to the routine the
      # number names, however many there are. That is what stepping a script wants: one of a
      # hundred and more handlers, picked by an instruction's number, several times a frame.
      class CallOneOf
        include Node
        kind :call_one_of
        category :control
        operands targets: :list, which: :value

        def callees = targets
      end

      class Camera
        include Node
        kind :camera
        category :draw
        operands x: :value, y: :value
      end

      class Case
        include Node
        kind :case
        category :control
        operands var: :name, clauses: :list

        def callees = clauses.map(&:last)
      end

      class Chance
        include Node
        kind :chance
        category :value
        operands draw: :value, percent: :int
      end

      class Clamp
        include Node
        kind :clamp
        category :var
        operands var: :name, min: :value, max: :value
      end

      # One reading of the date and time: +reading+ is one of IR::Clock::READINGS.
      class Clock
        include Node
        kind :clock
        category :value
        operands reading: :option
      end

      # Set the clock to a date and time, each a value worked out as the game runs and already
      # held to the range IR::Clock::SET_RANGES gives it: kept as how far it is from the clock's
      # own (see IR::Clock::OFFSET_DAYS). With no clock it does nothing.
      class SetClock
        include Node
        kind :set_clock
        category :var
        operands year: :value, month: :value, day: :value, hour: :value, minute: :value, second: :value
      end

      class ClearScreen
        include Node
        kind :clear_screen
        category :draw
        operands color: :color
      end

      # A NAMED LIST OF COLOURS THAT CAN BE TOLD TO HOLD OTHER COLOURS as the program runs.
      # An Object names one in its +recolors+ where a plain list of colours would go, and is
      # then drawn in whatever the list holds at that moment — so one list dresses many
      # different things in turn.
      #
      # +colors+ is what it holds when the program starts, the see-through place first.
      # +recolors+ is every other set of colours it can be told to hold, in the order
      # ColorListHolds counts them. A list of colours nothing ever changes has no node at
      # all: an Object carries its colours outright.
      #
      # +backdrop_place+ means the colour shown wherever nothing is drawn follows this list: it is
      # the colour at that place of whatever set the list holds, changing as the list does
      # (ColorListHolds). Nil for a list the backdrop does not follow. The game's `screen` sets
      # the colour at that place of the declared set, which is what the backdrop is until the list
      # is told anything, and a scene arriving leaves the backdrop as the list has it
      # (SceneHandover#backdrop_follows_list?).
      class ColorList
        include Node
        kind :color_list
        declaration!
        category :data
        operands name: :name, colors: :list, recolors: :list, backdrop_place: :int

        # A variable for a target that keeps the colours somewhere of its own and has to
        # put them back there — after it has rewritten that place for some other reason —
        # to record which set is in force. Nought is "nothing has been set yet"; what goes
        # there otherwise is that target's business alone. Named here so the program and
        # the target name the same one.
        def self.source_var(name) = :"__colors_#{name}_at"

        SHARED_PREFIX = "__shared_colors_"

        # The name of a list that lists a game declares are never in use together take turns in.
        # Several such lists are drawn through one of these, so they need one place between
        # them where each would have needed its own. +family+ counts the lists placed
        # together (one scene's, or the lists every scene draws with), and +number+ counts
        # within it.
        def self.shared_name(family, number) = :"#{SHARED_PREFIX}#{family}_#{number}"

        # Is +name+ one of those?
        def self.shared?(name) = name.to_s.start_with?(SHARED_PREFIX)

        # Which family the shared list +name+ belongs to.
        def self.shared_family(name) = name.to_s.delete_prefix(SHARED_PREFIX).split("_").first.to_i

        # For one of those: the set of lists, in the author's words, that needs the most of its
        # family at once — what to point at when they do not fit. Not part of what the program
        # does, so not an operand.
        attr_accessor :busiest_set
      end

      # A ColorList holds another set of colours from now on, and everything drawn with it
      # shows them. +which+ counts from 0 through the list's +recolors+ and may be worked out
      # as the program runs; a number naming none of them is the colours it was declared
      # with.
      class ColorListHolds
        include Node
        kind :color_list_holds
        category :draw
        operands name: :name, which: :value
      end

      # A SCENE'S SPRITE PICTURES IN GROUPS, only some of which are up at a time — a room's
      # things, where a scene is many rooms. +groups+ is each group's picture names, by its
      # number (nil for a number naming none); +together+ is each set of group numbers that can
      # be up at once, a group always being able to be up alone. A picture in no group is up the
      # whole time. +scene+ is the game state they belong to, nil for every screen's. A target
      # that keeps every picture in reach whatever is up needs none of this to draw.
      class PictureGroups
        include Node
        kind :picture_groups
        declaration!
        category :data
        operands name: :name, groups: :list, together: :list, scene: :name

        # No group: what a slot of ShowPictureGroup holds before the game names one, and when it
        # names no group.
        NONE = -1

        # How many groups can be up at once: the biggest set +together+ names, or one.
        def slots = [*together.map(&:length), 1].max

        # The numbers of the groups holding +picture+.
        def groups_holding(picture) = groups.each_index.select { |number| groups[number]&.include?(picture) }

        # Does +number+ name a group?
        def names_group?(number) = number.between?(0, groups.length - 1) && !groups[number].nil?

        # Can the groups +numbers+ be up at once?
        def together?(numbers) = numbers.length < 2 || together.any? { |set| (numbers - set).empty? }
      end

      # One of a PictureGroups' slots holds group +which+ from now on, a number worked out as the
      # program runs; a number naming no group leaves nothing up in that slot. The groups up are
      # the ones the slots hold.
      class ShowPictureGroup
        include Node
        kind :show_picture_group
        category :draw
        operands name: :name, slot: :int, which: :value
      end

      class Copy
        include Node
        kind :copy
        category :var
        operands dest: :name, src: :name
      end

      class Data
        include Node
        kind :data
        declaration!
        category :data
        operands name: :name, bytes: :text
      end

      class DataByte
        include Node
        kind :data_byte
        category :value
        operands name: :name, index: :int
      end

      class DefineSound
        include Node
        kind :define_sound
        declaration!
        category :sound
        operands name: :name, frequency: :int, duty: :option, decay: :option, volume: :int

        # The sound this declares, as every backend plays it.
        def effect = VBlank::Audio::Sound::Effect.new(frequency: frequency, duty: duty, decay: decay, volume: volume)
      end

      class DivFix
        include Node
        kind :div_fix
        category :value
        operands lhs: :value, rhs: :value, fraction_bits: :int
      end

      class DmaFillRect
        include Node
        kind :dma_fill_rect
        category :draw
        operands x: :int, y: :int, w: :int, h: :int, color: :color
      end

      class DrawDigit
        include Node
        kind :draw_digit
        category :draw
        operands value: :value, x: :int, y: :int, color: :color, font: :name
      end

      class DrawRectAt
        include Node
        kind :draw_rect_at
        category :draw
        operands x: :value, y: :value, w: :value, h: :value, color: :color
      end

      # One column of a picture, stretched to a height the program works out. The whole of a
      # first-person view is this, done once per strip across the screen.
      #
      # +width+ is how many pixels ACROSS the strip is. A view whose strips are wider than a
      # pixel shows the same picture column at the same height in each of them, so the width
      # belongs here rather than in a loop the caller writes: one walk down the screen fills
      # the whole strip. It is a number settled while building, because a strip's width is a
      # property of the view rather than something a game works out per frame.
      class DrawColumnAt
        include Node
        kind :draw_column_at
        category :draw
        operands name: :name, slice: :value, x: :value, top: :value, height: :value, width: :int
      end

      # A PLACE MADE OF FLAT FACES, DRAWN AS A VIEWER SEES IT. The place is data the program
      # declared (its points and faces, kept as tables) and the viewer is variables the game
      # changes, so drawing it is one statement here, and the work of drawing it is the
      # statements under it: they hand the viewer and the edges of the view to a routine the
      # program holds for the place, which turns each point to the viewer, finds where it lands
      # on the screen and fills each face with its picture (see IR::PlaceDrawing).
      #
      # A target that draws by working those sums out itself runs the children and nothing
      # else. A target whose hardware turns points and fills faces itself reads +place+ and
      # +viewer+ instead and leaves the children alone — that is why this is a kind of its own
      # and not a bare call.
      #
      # What it is told, each a fact a hardware target needs as much as the statements do:
      #
      #   +perspective+  how a picture is laid across a face that leans away; :none stretches it
      #                  straight between the corners
      #   +near+         how near a point may be, a fraction with sixteen bits; a face reaching
      #                  nearer is cut there
      #   +view_angle+   how wide the view is, in degrees across
      #   +both_sides+   whether a face is drawn from behind as well as from in front
      #   +faces+        a list of the faces to draw, in order, or nil for all of them in the
      #                  order the place declares them
      #   +window+       four values, the left, top, right and bottom the view is held to as the
      #                  game runs, or nil for the area drawing is held to
      class DrawPlace
        include Node
        kind :draw_place
        category :draw
        operands place: :name, viewer: :name, perspective: :option, near: :int, view_angle: :int,
                 both_sides: :flag, faces: :name, window: :list
      end

      # ONE FACE ALREADY ON THE SCREEN, filled with a picture. Its corners are the first +count+
      # fours of list +corners+ (3 to 8 of them, in order round the face): where each lands on the
      # screen (x, y, in sixteenths of a pixel) and where it falls on the picture (u across, v
      # down, in picture pixels with sixteen fraction bits). The picture is number +picture+ of
      # +pictures+, held to the ends of that list, and repeats past its edges like wallpaper.
      # Nothing outside +left+, +top+, +right+ and +bottom+ (whole pixels, the right and bottom
      # ones not drawn) is touched. Every number but the list of pictures can be worked out as the
      # game runs.
      #
      # How the corners become pixels is written down once, in Reference#exec_fill_face, and
      # every target lands every pixel where that puts it.
      class FillFace
        include Node
        kind :fill_face
        category :draw
        operands pictures: :list, picture: :value, corners: :name, count: :value,
                 left: :value, top: :value, right: :value, bottom: :value, perspective: :value, shading: :name

        # The most corners a face can have: four, each cut by the near limit into two.
        MOST_CORNERS = 8

        # How many numbers a corner is in the list: x, y, u, v, one over its distance (w, with
        # 26 bits of fraction), which only a picture in perspective reads, and its light (0 for
        # dark to LIGHTEST, with sixteen bits of fraction), which only a fill with +shading+ reads.
        CORNER_NUMBERS = 6

        # The most light a corner can have: a hair under one whole, so the brightest level of a
        # shading is the last one.
        LIGHTEST = 0xFFFF

        # +perspective+ is how many pixels apart the place on the picture is worked out exactly
        # across a row: PERSPECTIVE_NONE for never (the picture is stretched straight between the
        # row's ends), 8 or 1. Between, it steps straight.
        PERSPECTIVE_NONE = 0
        PERSPECTIVE_SPANS = Ractor.make_shareable({ none: PERSPECTIVE_NONE, every_8_pixels: 8, every_pixel: 1 })

        # The edges nothing outside is drawn, [left, top, right, bottom].
        def edges = [left, top, right, bottom]
      end

      # A GAME'S SHADING: what each colour becomes at each level of light, from the darkest level
      # to the brightest, as the game's own tables give. +colors+ are the game's colours (15-bit,
      # its palette), and each of +levels+ gives, for each of those colours by its place, the place
      # of the colour it becomes at that level. A colour not among +colors+ stays as it is.
      #
      # A face filled with a shading (FillFace's +shading+) is lit from its corners: each corner's
      # light, times how many levels there are, is stepped across the face like its place on the
      # picture, and each pixel's colour is looked up at the level its light has reached.
      class Shading
        include Node
        kind :shading
        declaration!
        category :data
        operands name: :name, colors: :list, levels: :list

        # The level a light (0 to FillFace::LIGHTEST) times the levels has reached: its whole part.
        def self.level_of(shade) = shade >> 16

        # Where each colour stands in +colors+, as a Hash of colour to place: a colour listed twice
        # is at its first place, which every lowering and the palette agree on.
        def places
          places = {}
          colors.each_with_index { |color, place| places[color] ||= place }
          places
        end
      end

      # Words at a fixed place. +picked+ is a second colour and +showing+ the test that picks
      # it — the words are drawn in +picked+ while the test holds and in +color+ when it does
      # not. The words are ONE set however many colours they can be, so a backend paints them
      # once with the colour worked out first. Without +picked+, +showing+ is never read.
      class DrawText
        include Node
        kind :draw_text
        category :draw
        operands text: :text, x: :int, y: :int, color: :color, font: :name, picked: :color, showing: :value

        def drawn_colors = [color, picked].compact
      end

      class Else
        include Node
        kind :else
        part!
        category :control
      end

      class EnableSound
        include Node
        kind :enable_sound
        category :sound
      end

      class Every
        include Node
        kind :every
        category :control
        operands counter: :name, period: :int
      end

      # A fade toward black or white. +under+ places it in the stack; +reaches+ keeps it to one
      # part of the screen instead — :inside the rectangle +area+ holds, or :outside it — with
      # +area+ as [left, top, right, bottom] in screen pixels, already clipped to the screen,
      # the right and bottom one past the last column and row.
      class Fade
        include Node
        kind :fade
        category :draw
        operands toward: :option, amount: :value, under: :name, fraction_bits: :int, reaches: :option, area: :list
      end

      # No sprite is drawn on the next frame drawn after this pass, and on the frame after that
      # every one is drawn again as it would have been. Nothing about any sprite changes.
      class HideSprites
        include Node
        kind :hide_sprites
        category :draw
      end

      # THE PLAYER'S HANDS SHAKEN: a motor run for +frames+ frames, on or off on each by +pattern+'s
      # eight bits from the top, round again after the eighth. A rumble asked for while one runs takes its
      # place, and nought frames stops it. Felt only on a console whose cartridge has a motor
      # (Console::Description#rumbles).
      class Rumble
        include Node
        kind :rumble
        category :sound
        operands frames: :value, pattern: :value
      end

      class FillRect
        include Node
        kind :fill_rect
        category :draw
        operands x: :int, y: :int, w: :int, h: :int, color: :color
      end

      # A routine. +measure_holding+ is how a build that measures the game plays this routine's
      # scene while it measures it: a list of frames, each the buttons down on it, played round
      # and round. nil for a scene measured with nothing pressed, and for every routine that is
      # not a scene. Nothing the routine does depends on it, so no lowering reads it.
      class Func
        include Node
        kind :func
        declaration!
        category :control
        operands name: :name, fast: :flag, loads_first: :flag, on_chip: :flag, measure_holding: :list
      end

      # A part of the picture that everything inside this stays within. Whatever the children
      # draw is cut off at these edges, exactly as it is cut off at the edges of the picture —
      # so the pixels outside are not merely covered up afterwards, they are never worked out.
      #
      # A program that shows one part of the picture over another — a strip of the world with a
      # panel of numbers under it — needs this to mark which part is which. Without it the world
      # is drawn over the whole picture and the panel painted on top, and everything under the
      # panel was worked out for nothing.
      #
      # The edges are settled while building. Where the parts of a picture are is a fact about
      # how a program is laid out, not something it works out as it goes.
      class Inside
        include Node
        kind :inside
        category :control
        operands x: :int, y: :int, w: :int, h: :int
      end

      class Halt
        include Node
        kind :halt
        category :control
      end

      # HOW MANY PLAYERS ARE CONNECTED NOW, at least 1: a player counts from the first time one of
      # their buttons is down (IR::Buttons.masks). A console that reads one controller answers 1.
      class PlayersConnected
        include Node
        kind :players_connected
        category :value
      end

      # WHICH PLAYER THIS MACHINE'S PERSON IS, from 1: the one number that is different on each machine
      # of a match by design. The build lets it reach nothing but what is drawn
      # (Builder#drawing_for_local_player), so it can never make two machines play different games.
      # A machine that plays alone, and every console, answers 1.
      class LocalPlayer
        include Node
        kind :local_player
        category :value
      end

      class Held
        include Node
        kind :held
        category :value
        operands button: :option, player: :player
      end

      class If
        include Node
        kind :if
        category :control
        operands cond: :value, else: :branch
      end

      class Int
        include Node
        kind :int
        category :value
        operands value: :int
      end

      # The stack of layers a picture is built from, backmost first — and which of them
      # you can see through (+see_through+, a list of SeeThroughLayer). A screen shows at
      # most one of those at a time, so a game has one for each screen that wants one.
      # +shared+ lists runs of neighbouring names that share one level of depth, each back
      # to front (see IR::Stacking#depths).
      class Layers
        include Node
        kind :layers
        declaration!
        category :data
        operands names: :list, see_through: :list, shared: :list
      end

      # One layer you can see through, and by how much: +shows+ is how much of the layer
      # itself shows and +behind+ how much of what is behind it, each 0 to 100. They need
      # not add to 100 — past it the mix is brighter than either side and stops at full
      # brightness, which is how a glow or a shaft of light looks.
      #
      # +split+ marks the one-number form, where the author gave how much of what is
      # behind shows and the layer takes the rest. The two forms round differently, so
      # it is carried rather than inferred: the rest is what is LEFT of a whole once the
      # far side is counted, where two amounts are each taken to the nearest step.
      #
      # The amounts are values rather than numbers, because a picture can go on changing
      # them — fog that thickens, water that gets murkier the deeper you swim. A number
      # settled while authoring is written once and never again; one the program works out
      # is read again every frame (see SeeThrough).
      class SeeThroughLayer
        include Node
        kind :see_through_layer
        declaration!
        category :data
        operands name: :name, shows: :value, behind: :value, split: :flag
      end

      # How see-through +layer+ is, RIGHT NOW.
      #
      # The framework puts one at each frame boundary for a layer whose amounts are worked
      # out as the game runs, so the display is told again before the frame is drawn — and
      # for every see-through layer in a game with more than one, since which of them is
      # on screen changes as the screens take turns. The amounts are on the layer's own
      # SeeThroughLayer. +added+ marks a layer that shows the whole of itself, written as a number,
      # with only how much of what is behind it worked out: all a display that can only add can do.
      class SeeThrough
        include Node
        kind :see_through
        category :draw
        operands layer: :name, added: :flag
      end

      class ListDrop
        include Node
        kind :list_drop
        category :list
        operands name: :name, from: :option
      end

      class ListGet
        include Node
        kind :list_get
        category :value
        operands name: :name, index: :value
      end

      class ListLen
        include Node
        kind :list_len
        category :value
        operands name: :name
      end

      class ListNew
        include Node
        kind :list_new
        category :list
        # +fast+ is what the author asked for about where this should live, on a machine with
        # more than one work memory: false for "I know this is cold — give it room", true
        # to insist on the quick one, absent to let the framework decide. It is the same
        # word a routine takes for the same question, and it changes nothing a program
        # does — only how long a read takes.
        #
        # +full_of+, when given, is what the list holds from power-on and each time this runs:
        # +capacity+ items, every one that number. Absent, it starts empty.
        operands name: :name, capacity: :int, declared: :int, width: :option, fast: :flag, full_of: :int
      end

      class ListPush
        include Node
        kind :list_push
        category :list
        operands name: :name, value: :value
      end

      class ListSet
        include Node
        kind :list_set
        category :list
        operands name: :name, index: :value, value: :value
      end

      # Every item from +from+ for +count+ items set to +value+, as that many list_sets would
      # — a count of 0 or less sets none. One statement, so a backend can write a long run a
      # word at a time rather than an item at a time.
      class ListFill
        include Node
        kind :list_fill
        category :list
        operands name: :name, from: :value, count: :value, value: :value
      end

      # The list made to hold exactly +count+ entries of +table+, from entry +at+ on. +at+ is
      # worked out as the game runs and is held inside the table, so the run never reads past
      # either end of it. One statement, so a backend can copy the run as a block rather than
      # an entry at a time.
      class ListCopy
        include Node
        kind :list_copy
        category :list
        operands name: :name, table: :name, at: :value, count: :int
      end

      # Every item the list holds put in order by a number another list keeps for it: each item
      # is a place in +by+, and the number there is what it is ordered by, the smallest first
      # (the biggest first when +descending+). Items whose numbers are equal keep the order they
      # were in, so sorting again a list already in order moves nothing — a stable sort, and so
      # its answer is the one answer every backend must give, whatever way it sorts.
      #
      # Every item must be a place in +by+. The interpreter stops the game at one that is not, as
      # reading +by+ there would; a lowering need not look, since the framework only sorts lists
      # of places it made. One statement, so a backend sorts in a routine of its own machine's
      # code, where the same sort written as list reads and writes takes a call for each of them.
      class ListSort
        include Node
        kind :list_sort
        category :list
        operands name: :name, by: :name, descending: :flag
      end

      class Loop
        include Node
        kind :loop
        category :control
      end

      class MulFix
        include Node
        kind :mul_fix
        category :value
        operands lhs: :value, rhs: :value, fraction_bits: :int
      end

      class Neg
        include Node
        kind :neg
        category :value
        operands operand: :value
      end

      class Negate
        include Node
        kind :negate
        category :var
        operands var: :name
      end

      class NegateAbs
        include Node
        kind :negate_abs
        category :var
        operands var: :name
      end

      class Noise
        include Node
        kind :noise
        category :sound
        operands preset: :option, pitch: :option, decay: :option, volume: :int, metallic: :flag
      end

      class Object
        include Node
        kind :object
        declaration!
        category :draw
        # +scene+ is the game state this thing belongs to, where it was declared inside
        # one. It is on screen only while that state is active, which the +active+
        # operand already carries — what the NAME adds is that a target with somewhere
        # finite to keep pictures knows which of them are needed at the same time.
        #
        # +recolors+ is every other list of colours it can be drawn with, and +recolor+ holds
        # which of them it is drawn with now, counting from 0; any other number draws it in
        # its own. A pixel keeps its place in the picture's own list, so drawn with another
        # list it shows whatever colour that list holds at the same place. Each entry is the
        # colours themselves, or the name of a ColorList, whose colours can change as the
        # program runs.
        # +name+ is this thing's own identity, handed out as the program is built, and
        # +declared+ is what the AUTHOR called it. They differ because one author's name can
        # stand for many of these — every slot of a pool is one — and because some are drawn
        # for things the author named no sprite for at all, a letter of text among them, which
        # have no +declared+ to give. Keeping it is what lets a target report on what it drew
        # in the author's own words rather than in numbers it made up.
        #
        # +layers+ is every other layer it can be put in while the program runs, and
        # +layer_pick+ names the variable saying which of them it is in now, counting from 0;
        # both are absent on a thing that never changes layer. Any other number
        # leaves it in +layer+, the one it was declared in. That is how one thing walks
        # behind scenery on one floor of a room and in front of it on the next.
        #
        # +over_picture+ means it is shown over a screen the program paints, rather than over
        # scenery drawn from tiles. It is drawn over the painted picture and never into it,
        # so painting the picture again does not touch it, and it is in front of everything
        # the program paints there.
        #
        # +follows+ names a ColorList it is drawn with for good, from power-on, its pictures drawn
        # in that list's own colours: its own colours are then the list's, and a target whose sprites
        # and backgrounds share one table of colours needs no place in it for them. Absent otherwise.
        operands name: :name, declared: :name,
                 poses: :list, pose: :value, x: :value,
                 y: :value, active: :value, angle: :value,
                 scale: :value, layer: :name, scene: :name,
                 recolor: :value, recolors: :list,
                 layers: :list, layer_pick: :name, over_picture: :flag, follows: :name
      end

      class OnTimer
        include Node
        kind :on_timer
        category :control
        operands timer: :name

        # The handler each timer answers its ticks with, timer name -> node. A handler is its
        # timer's from power-on wherever it is written — inside a routine nothing calls too —
        # and a second one for the same timer replaces the first. Every backend asks here, so
        # none of them can settle that differently.
        def self.of(program)
          program.walk.select { |node| node.kind == :on_timer }.to_h { |node| [node.timer, node] }
        end
      end

      class Pixel
        include Node
        kind :pixel
        category :draw
        operands x: :value, y: :value, color: :color
      end

      class Pixelate
        include Node
        kind :pixelate
        category :draw
        operands size: :value, under: :name
      end

      class PixelsOverlap
        include Node
        kind :pixels_overlap
        category :value
        operands a_poses: :list,
                 a_pose: :value, a_x: :value, a_y: :value,
                 b_poses: :list, b_pose: :value, b_x: :value,
                 b_y: :value
      end

      class PlaySample
        include Node
        kind :play_sample
        category :sound
        operands name: :name, loop: :flag, volume: :option, pitch: :option
      end

      # The tune playing now is +name+. With +this_frame+ it is on its first frame where this
      # is reached, rather than from the next frame on.
      class PlaySong
        include Node
        kind :play_song
        category :sound
        operands name: :name, this_frame: :flag
      end

      class PresentObjects
        include Node
        kind :present_objects
        category :draw
        operands names: :list, orders: :list
      end

      class Pressed
        include Node
        kind :pressed
        category :value
        operands button: :option, player: :player
      end

      # The whole program. +console+ names the console it was built for (see Console::Kit), whose
      # screen the game was laid out on and checked against. Every build names one.
      #
      # AN UNBOUND PROGRAM names none: a tree a test makes by hand, or with a Builder that was not
      # told a console. It is a test's, and each test run plays it as the console that run is for
      # (Testing#program_played). Until then it is laid out and checked on the Advance's screen,
      # the one the hand-built trees were written against.
      #
      # +variant+ names the hardware the console's copy has beyond the plain console (a chip on a
      # Super Nintendo cartridge, Console::Variant), or is nil for the plain console.
      #
      # +sprite_piece_sizes+ is the size of piece each console the game named one for draws its
      # sprites in, as [console, [width, height]] pairs (Cartridge::Options#sprite_piece_size). It
      # is kept by console, not for the console the program is built for, so a test's unbound
      # program carries it to whichever console a run plays it as. What a sprite shows is the same
      # at every size; only how a console's build cuts it up differs.
      #
      # +kept_widths+ is each variable the game declared narrow, as [name, :byte or :half] pairs. Every
      # write to one is followed by the wrap to that width (IR::KeptWidths), so what it holds
      # needs nothing more from any backend; a console may keep it in fewer bytes.
      #
      # +fraction_vars+ and +fraction_lists+ are each variable and each list (a pool's field among them)
      # the game keeps fractions in, as [name, bits] pairs: the number is kept multiplied by two to
      # the power of +bits+ (DSL::Fraction). No backend needs them to run the game; they are how
      # anything reading a running game gives the game's number back (Reference::ReadingBack).
      #
      # +sprite_readings+ is where each sprite the game can read by name keeps its place, an
      # IR::SpriteReading each, with an IR::SharedName for a name several sprites share,
      # for the same readers; like the two above, no backend needs it to run. +background_readings+
      # is the same for each background, an IR::BackgroundReading each.
      #
      # +players+ is [fewest, most]: how many players the game takes on this build
      # (Cartridge::Players), or nil where it gave nothing. +for_computer+ is true for a build that
      # plays on a computer, whose controllers are not the console's (#described_build).
      #
      # +border+ is the picture the game gave for the border round its screen, two bytes a pixel as
      # a picture keeps them, and +border_size+ its [width, height] (Builder::Images#border). Both
      # are nil where the game gave none, or where the console shows the game's screen whole and no
      # border is drawn (Console::Description#bordered?). A border is a picture of the whole screen
      # around the game's, not something the game does, so it is not a statement and every backend
      # that draws no border has nothing to do with it.
      #
      # +pixel_size+ is how many of the console's pixels across and down one of the game's is shown
      # as (`screen :bitmap, pixel_size: 2`), or nil for one. It is the whole game's, so it is the
      # program's: the game is laid out and played on a screen that many times smaller
      # (#described_console), and each console's build shows that picture bigger.
      #
      # +verbs_written+ is the names of the verbs the game wrote that are written in other verbs
      # and leave no step of their own: a `pulse` is a sprite's size walked every frame, an iris a
      # light's. The steps say what the program does, which is all a backend needs, but not which
      # verb the author wrote. A console that cannot do one says so in that verb's words
      # (Console::Questions.verb_questions), where the steps alone would have it answer for the verb
      # underneath. Absent for a game that wrote none; no backend reads it to run the game.
      class Program
        include Node
        kind :program
        category :root
        operands console: :name, variant: :name, sprite_piece_sizes: :list, kept_widths: :list,
                 fraction_vars: :list, fraction_lists: :list, sprite_readings: :list, background_readings: :list,
                 players: :list, verbs_written: :list,
                 for_computer: :flag, border: :text, border_size: :list, pixel_size: :int,
                 start_file: :start_file

        # +start_file+ is the file the program is handed as it starts, which some of its tables and
        # pictures are read from (a StartFile), or absent for a program that reads none.

        # The most players the game takes on this build, or nil where it gave nothing.
        def most_players = players&.last

        # Whether the game takes more than one player, which is what a match of several machines
        # needs. A build carries what a match needs (its seed routine, the runtime that plays one) only then.
        def several_players? = most_players.to_i > 1

        # What the console this program was built for can do, as the build reads it: on a computer
        # its controllers are as many players as any build reads (IR::Buttons::MOST_PLAYERS), since
        # a computer has no ports to count; everything else is the console's.
        def described_build
          console = described_console
          for_computer ? console.with(controllers: IR::Buttons::MOST_PLAYERS) : console
        end

        # The width variable +name+ is kept at, or nil for the whole number.
        def kept_width_of(name) = (kept_widths || []).to_h[name]

        # What variable +name+ holds, given the number +stored+ for it, in the game's units; and the
        # same for the items of list +name+. A fraction is kept multiplied by two to the power of its
        # bits, and comes back a Rational: a whole number over a power of two is always exactly one,
        # so two readings compare exactly, and it equals the Float the game wrote (25/2 == 12.5). A
        # whole number comes back as it is. Every reader of a running game asks these, so all of
        # them answer alike (Reference::ReadingBack, Bots::GameView).
        def var_in_game_units(name, stored) = in_game_units(stored, (fraction_vars || []).to_h[name])

        def list_in_game_units(name, items)
          bits = (fraction_lists || []).to_h[name] or return items
          items.map { |item| in_game_units(item, bits) }
        end

        private def in_game_units(stored, bits) = bits ? Rational(stored, 1 << bits) : stored

        # Sprite +name+ as it stands (an IR::SpriteState), read from +reader+'s stored numbers; every
        # reader of a running game asks this (IR::ReadingByName#sprite).
        def sprite_state(name, reader) = sprite_reading(name).state_from(reader)

        # Background +name+ as it stands (an IR::BackgroundState), read the same way.
        def background_state(name, reader) = background_reading(name).state_from(reader)

        # Where background +name+ keeps its state (an IR::BackgroundReading), refusing in plain
        # words a name no background has.
        def background_reading(name)
          readings = background_readings || []
          readings.find { |reading| reading.name == name } or
            raise ArgumentError, "This game has no background :#{name}. #{names_there_are('backgrounds', readings)}"
        end

        # The music's loudness, read from +reader+'s stored numbers, as the game's own `music_volume`
        # reads it: 0 to 100, whole and rounded down from the sixteenths it is kept in (IR::Tunes),
        # and full for a game that never sets it.
        def music_volume_from(reader)
          return Tunes::FULL_PERCENT unless Reach.variables(self).include?(Tunes::LEVEL)

          Tunes.percent_of(reader.raw_var(Tunes::LEVEL))
        end

        # The names in +readings+, said for a refusal ("Its sprites are :a, :b.").
        private def names_there_are(kind, readings)
          return "It has none." if readings.empty?

          "Its #{kind} are #{readings.map { |reading| ":#{reading.name}" }.join(', ')}."
        end

        # Where sprite +name+ keeps its state (an IR::SpriteReading), refusing in plain words a
        # name no sprite has, and a name several sprites share.
        def sprite_reading(name)
          readings = sprite_readings || []
          found = readings.find { |reading| reading.name == name }
          return found if found.is_a?(SpriteReading)
          raise ArgumentError, found.message if found

          raise ArgumentError, "This game has no sprite :#{name}. #{names_there_are('sprites', readings)}"
        end

        # What the console this program was built for can do: its screen, buttons, sprites — the
        # screen as the game sees it, so with the game's pixel size (#pixel_size) it is that many
        # times smaller than the console's.
        def described_console = console_description.with_pixel_size(pixel_size)

        # The console this program was built for, with its variant, as it is whatever the game's
        # pixel size. A program that names none cannot be laid out, and no console is assumed for
        # it. A game names its consoles and a build its console; a test's program plays as its
        # run's, and the test kit sets how it is laid out (Testing::LaidOutForTheAdvance).
        def console_description
          return Console.described(console, variant: variant) if console

          raise VBlank::BuildError, "This program names no console, so it cannot be laid out. To fix this, name " \
                                    "one: `VBlank.game \"NAME\", consoles: %i[gba]`, or `console: :gba` on the build."
        end

        # The size of piece the game named for +console+'s sprites, or nil where it named none.
        def sprite_piece_size_on(console) = (sprite_piece_sizes || []).to_h[console]
      end

      # A FONT THE PROGRAM DECLARED, the same way a declared picture is a node: it draws
      # nothing itself, it is there to be named by something that draws. `font :heavy do
      # ... end` puts one of these in the tree and `draw_text ..., font: :heavy` names it.
      #
      # It belongs to the program for the reason a picture does — it is part of the game.
      # Kept in one table shared by the whole process instead, the second game built in a
      # session could draw with the first one's font, a name declared twice replaced
      # quietly, and a game building on another core could not declare one at all. The two
      # fonts the framework ships are not in here; those are everybody's, and live in
      # Graphics::Fonts.
      class Font
        include Node
        kind :font
        declaration!
        category :data
        operands name: :name, font: :font
      end

      class Raw
        include Node
        kind :raw
        tier :hardware_only
        category :control
        operands bytes: :text
      end

      class ReadScanline
        include Node
        kind :read_scanline
        tier :hardware_only
        category :value
      end

      # +stop_when+ is a value checked before each pass: when it is true the loop ends early,
      # which is what a search wants — a ray that has met a wall has its answer and every step
      # after it is spent proving nothing.
      class Repeat
        include Node
        kind :repeat
        category :control
        operands count: :value, index: :name, stop_when: :value
      end

      class RestoreRegion
        include Node
        kind :restore_region
        category :draw
        operands buffer: :name, x: :value, y: :value
      end

      class Sample
        include Node
        kind :sample
        declaration!
        category :data
        operands name: :name, bytes: :text, rate: :int, note: :option,
                 envelope: :shape, holds_from: :int, from_file: :int
      end

      class SaveInit
        include Node
        kind :save_init
        category :var
        operands vars: :save, magic: :int
      end

      # THE THREE WAYS INTO SAVE MEMORY that save data is built from (see Builder::SaveData):
      # read a byte, a half or a word at a place in it, write one, and total a run of bytes
      # into a checksum. A place is a count of bytes from the start of save memory, and what
      # save memory IS — a chip, a file, a Ruby hash — is each backend's business.
      #
      # A read is unsigned for a byte and a half and a whole signed word for a word, so a
      # narrow list slot comes back the way the list itself reads a number too big for it.
      class SaveRead
        include Node
        kind :save_read
        category :value
        operands at: :value, width: :option
      end

      class SaveWrite
        include Node
        kind :save_write
        category :var
        operands at: :value, value: :value, width: :option
      end

      # The checksum of +length+ bytes from +at+: two running totals, the bytes and the totals
      # of the bytes, each kept to sixteen bits — the second is what makes it notice two bytes
      # swapped — with the second in the top half of the word. See IR::SaveLayout.checksum.
      class SaveSum
        include Node
        kind :save_sum
        category :value
        operands at: :value, length: :value
      end

      # A WHOLE LIST MOVED BETWEEN SAVE MEMORY AND THE GAME IN ONE STEP. A record that keeps a list
      # reads and writes every slot of it, and written as a read or a write for each item that
      # is a call apiece, with the place worked out afresh each time: on a small console the
      # calls cost far more than the bytes. One statement lets a backend move the run as a block,
      # the way a console's own games copy their saves.
      #
      # SaveLoadList: the list made to hold +count+ items (held to nought and +most+, which is no
      # more than its capacity), read from +at+ on, each a slot of the list's +width+ as a
      # save_read of that width reads it, pushed in order. What the list held before is gone.
      #
      # SaveStoreList: every item the list holds written from +at+ on, in order, each as a
      # save_write of the list's +width+ writes it. The bytes go in rising order, so a power cut
      # part way leaves what the same writes one at a time would.
      #
      # +index+ names a variable the builder declared for a backend that writes the step out as
      # the loops it stands for (IR::SaveListMoves.loops_for). It is a variable of the game's like
      # any other, so every backend leaves it the same: at nought once the step is done.
      class SaveLoadList
        include Node
        kind :save_load_list
        category :list
        operands name: :name, at: :value, count: :value, most: :int, width: :option, index: :name
      end

      class SaveStoreList
        include Node
        kind :save_store_list
        category :list
        operands name: :name, at: :value, width: :option, index: :name
      end

      # HOW MUCH SAVE MEMORY THE PROGRAM HAS, in kilobytes (see IR::SaveLayout::MEMORIES), and
      # so which kind: the smallest takes any byte at any time, where the bigger ones have to be
      # wiped a block at a time before a block is written again (IR::SaveLayout::Memory says
      # which). A program that names none has the smallest.
      #
      # It also records how the size came about, for a report to read and nothing to run:
      # +asked_for+ is whether the program's author named it, and +records+ is each record laid
      # out in it as [name, half bytes, copies, kept], in the order they were declared — +kept+
      # being what it keeps as [kind, name] (see Builder::Saves#laid_out_records), which a test
      # writing a copy into save memory reads.
      class SaveMemory
        include Node
        kind :save_memory
        declaration!
        category :data
        operands kilobytes: :int, asked_for: :flag, records: :list
      end

      # Wipe the block of save memory that holds +at+, so it takes any write again, and reads
      # as never written. Memory wiped a block at a time needs this before a block is written
      # afresh; on memory that takes any byte it does nothing, so a write order is written once
      # for both.
      #
      # A wipe takes a while. With +wait+ the program goes on once it is done. Without, the wipe
      # is only started, so the program can do other work meanwhile: until it is done, the
      # program must not write to save memory or start another wipe, and a read of the block
      # does not read 0xFF. So the program reads the block's first byte until it reads 0xFF.
      class SaveErase
        include Node
        kind :save_erase
        category :var
        operands at: :value, wait: :flag
      end

      class SaveRegion
        include Node
        kind :save_region
        category :draw
        operands buffer: :name, x: :value, y: :value
      end

      class SaveStore
        include Node
        kind :save_store
        category :var
        operands var: :name, slot: :int
      end

      class Screen
        include Node
        kind :screen
        category :draw
        # +late+: the rows above which a page finished too late for its break is shown at once
        # rather than at the next break (see IR::LatePages); nil, the default, always waits.
        # +late_pace+: how many breaks a pass may take and be on time; nil is one.
        # +backdrop+: the colour shown wherever nothing is drawn, as a 15-bit colour; nil is black.
        # +pixel_size+: on the game's first screen, how many of the console's pixels across and down
        # one of the game's is shown as; nil is one. The program carries it for the whole game
        # (Program#pixel_size); here it is the line that asked, for a console that cannot.
        operands mode: :mode, buffered: :flag, colors: :list, late: :int, late_pace: :int, backdrop: :int,
                 pixel_size: :int
      end

      class ScrollBackground
        include Node
        kind :scroll_background
        category :draw
        operands name: :name, x: :value, y: :value
      end

      class ScrollRows
        include Node
        kind :scroll_rows
        category :draw
        operands name: :name, row: :name, offset: :value
      end

      class Set
        include Node
        kind :set
        category :var
        operands var: :name, value: :value
      end

      # The picture darkened everywhere outside one span of each row: a light. Standing
      # once it is declared, like a bend, and read again before every frame — the row
      # variable is set to each row of the screen in turn, and +left+ and +right+ give where
      # that row's span starts and ends (the end not included), both worked out from it.
      # +amount+ is how dark the rest of the row goes, 0 (as drawn) to 100 (black).
      class ShadeOutside
        include Node
        kind :shade_outside
        category :draw
        operands row: :name, left: :value, right: :value, amount: :value
      end

      # The light worked out again where this is reached, so the picture of this pass shows it
      # as it stands rather than as it stood when the pass began. Nothing when the game has no
      # light.
      class ShowLightNow
        include Node
        kind :show_light_now
        category :draw
      end

      class ShiftRight
        include Node
        kind :shift_right
        category :value
        operands operand: :value, bits: :int
      end

      # A tune. At +total_frames+ it comes round again — to its first frame, or to
      # +loop_frame+ when it has one, so an introduction plays once — unless it +plays_once+,
      # and then it ends there (IR::Tunes.plays_once?). Played as a sound effect, the
      # others of its +group+ are the effects it stops (IR::Tunes.priority_of). +low_notes_intended+
      # means a note lower than its voice can play is played at the lowest it can on purpose.
      # +keeps_voices+ means a sound effect holds each voice it has taken until it ends, through a
      # rest or a note at volume 0.
      class Song
        include Node
        kind :song
        declaration!
        category :sound
        operands name: :name, voices: :score, total_frames: :int, loop_frame: :int, priority: :int,
                 group: :name, low_notes_intended: :flag, plays_once: :flag, keeps_voices: :flag
      end

      # A named list of songs that each play ONCE, over the tune playing now, when the program
      # asks for one (see PlaySoundEffect). A definition: it names what can be played and sounds
      # nothing.
      class SoundEffectList
        include Node
        kind :sound_effect_list
        declaration!
        category :sound
        operands name: :name, effects: :list
      end

      # Effect number +which+ of a SoundEffectList starts from its first note, counting from 0 — a
      # number that may be worked out as the program runs. Asked for while it is still sounding,
      # it starts again; a number naming no effect in the list plays nothing. With +this_frame+
      # it is on its first frame where this is reached, rather than from the next frame on.
      class PlaySoundEffect
        include Node
        kind :play_sound_effect
        category :sound
        operands name: :name, which: :value, this_frame: :flag
      end

      # A named list of songs, in order — the game's music, picked by number (see
      # PlayFromList). A definition, like Song: it names what can be played and sounds nothing.
      class SongList
        include Node
        kind :song_list
        declaration!
        category :sound
        operands name: :name, songs: :list
      end

      # The tune playing now is song number +which+ of a SongList, counting from 0 — a number
      # that may be worked out as the program runs. Like PlaySong, naming the tune already
      # playing changes nothing; a number naming no song in the list leaves the music as it is.
      # With +this_frame+ it is on its first frame where this is reached.
      class PlayFromList
        include Node
        kind :play_from_list
        category :sound
        operands name: :name, which: :value, this_frame: :flag
      end

      class StopMusic
        include Node
        kind :stop_music
        category :sound
      end

      # The tune playing stays where it is (+held+ true): what it sounds rings on and nothing new
      # starts, until this is set the other way (+held+ false) or another tune, or a stop, takes over.
      class HoldMusic
        include Node
        kind :hold_music
        category :sound
        operands held: :flag
      end

      class StopSample
        include Node
        kind :stop_sample
        category :sound
        operands name: :name
      end

      class StopWave
        include Node
        kind :stop_wave
        category :sound
      end

      class Sub
        include Node
        kind :sub
        category :var
        operands var: :name, operand: :value
      end

      class Table
        include Node
        kind :table
        declaration!
        category :data
        operands name: :name, values: :list, width: :option, signed: :flag, from_file: :int, entries_in_file: :int,
                 file_number_format: :number_format

        # +from_file+ is where its first entry is in the file the program is handed as it starts
        # (StartFile), for a table read from there, and +entries_in_file+ how many it has: its
        # +values+ are empty, since a program is written with none of them. Both are absent on
        # every other table. +file_number_format+ is the Console::NumberFormat the entries are
        # kept in in the file, and absent on every other table.

        # How many entries the table has, wherever they are.
        def entry_count = from_file ? entries_in_file : values.length
      end

      class TableGet
        include Node
        kind :table_get
        category :value
        operands name: :name, index: :value
      end

      class TimerStart
        include Node
        kind :timer_start
        category :control
        operands name: :name, hz: :int
      end

      class TimerStop
        include Node
        kind :timer_stop
        category :control
        operands name: :name
      end

      class TimerTicks
        include Node
        kind :timer_ticks
        category :value
        operands name: :name
      end

      class Tint
        include Node
        kind :tint
        category :draw
        operands color: :color, amount: :value, fraction_bits: :int
      end

      class VarRef
        include Node
        kind :var_ref
        category :value
        operands name: :name
      end

      class WaitVblank
        include Node
        kind :wait_vblank
        category :control
      end

      class Wave
        include Node
        kind :wave
        category :sound
        operands shape: :waveform, frequency: :int, volume: :option
      end

      # Every kind, by its name. Derived from the classes above rather than kept alongside
      # them, so it cannot fall behind: a class that exists is in here.
      BY_KIND = Ractor.make_shareable(constants.map { |name| const_get(name) }
                                               .to_h { |type| [type.kind, type] })

      def self.by_kind = BY_KIND

      # Every kind playing +role+ (see Node::Declarations#role), by name — what a backend's
      # handler table has to cover.
      BY_ROLE = Ractor.make_shareable(BY_KIND.group_by { |_kind, type| type.role }
                                             .transform_values { |pairs| pairs.map(&:first) })

      def self.of_role(role) = BY_ROLE.fetch(role, [])

      # Build a node of the named kind. The one place a kind SYMBOL becomes a class, for
      # callers that have the name rather than the type.
      def self.build(kind, children: [], source: nil, **operands)
        by_kind.fetch(kind) { raise ArgumentError, "no IR node kind #{kind.inspect}" }
               .new(children: children, source: source, **operands)
      end
    end
  end
end
