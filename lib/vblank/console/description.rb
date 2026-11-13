# frozen_string_literal: true

require_relative "hardware"

module VBlank
  module Console
    # WHAT A CONSOLE IS, AS FAR AS A GAME CAN TELL: how big its screen is, which buttons it has, how
    # many sprites it shows, and which of the picture's tricks it can do at all. The builder, the
    # build checks and the interpreter read these, so a game is laid out, checked and played for the
    # screen it will be shown on.
    #
    # It holds nothing about HOW the console is driven — register addresses, memory, the processor —
    # which is each lowering's own business (Console::Hardware is the Advance's). A program carries
    # the name of the console it was built for, and anything that reads it asks
    # Program#described_console.
    #
    # +name+ is how a game and the command line name it (:gba), +title+ how a person does.
    # +screen_width+ and +screen_height+ are in pixels. +buttons+ are the ones it has, in the
    # order IR::Buttons names them, and +controllers+ how many of them a game can read at once
    # (`held(:left, player: 2)`). +sprites+ is how many it can show at once, and +sprite_places+
    # how many a game can keep places for: more than it shows where a cartridge keeps a bigger
    # copy of its table and puts the sprites showing into the console's each frame, as the
    # Advance's does (Backends::GBA::SpriteDrawing::HeldTable), and the same where it does not.
    # +sprites_a_row+ is how many pieces of sprites, eight pixels wide, it draws on one row of the
    # screen before it leaves the rest of that row's out, or nil where the build does not count
    # them. +sprite_pieces_drawn_a_line+ is how many entries of the console's sprite table every
    # backend draws on one line of the screen, or nil where none counts them: the first that many the
    # table holds there, front-most first, and the rest are left out of that line alone
    # (Backends::SpriteLines). Of those, +sprite_slivers_drawn_a_line+ is how many slivers eight
    # pixels wide the console fetches, starting from the entry furthest back (the Super Nintendo's
    # 34), and +sprite_pixels_drawn_a_line+ how many pixels it draws, starting from the front, each
    # entry spending its whole width (the Genesis's 320); either is nil where it counts no such thing.
    # +sprite_piece_shape+ is what one entry of its table draws, which is how a picture is cut into
    # entries: :small, a square of 8×8 (or 8×16, as a game asks); :squares, those or squares of 16×16;
    # :rectangles, up to four squares of 8×8 across and four down (Backends::SpriteLines.picture_places).
    # +sprite_pieces_drawn_a_screen+ is how many of those pieces its sprite table holds, or nil where
    # every backend draws every sprite: the table is filled with each piece on the screen from the end
    # +sprite_table_filled_from+ names (:front, front-most first, or :back), and a piece that finds it
    # full is left out of every line (Backends::SpriteLines).
    # +backgrounds+ is how many tiled layers it stacks, +turning_backgrounds+ how many of
    # them can turn and resize, and +backgrounds_beside_turning+ how many still scroll on a screen
    # where one turns. +bar_is_a_background+ marks whether a status bar is one of those layers, or a
    # layer the console keeps beside them. +bar_shares_display+ marks whether the bar takes a part of the
    # display something else needs as well (a window the Advance's lights use, the memory the Color's
    # painted screen keeps its picture in), which Checks::StatusBarCannotShare asks about; where it is
    # false the bar is a picture drawn like any other. +turning_sprites+ marks whether a sprite can turn and resize.
    # +sprite_sizes+ is the sizes one sprite of the console is drawn at whole, in pixels across and
    # down, which a picture the game paints from a list has to be; nil where its build draws every
    # sprite's picture in pieces of 8×8, so such a picture can be any size in whole pieces.
    # +tile_planes+ is how many bit planes the console keeps a tile in, which a list a game paints
    # in the console's own form (`console_format: true`) holds as they are: eight bytes a plane, a
    # row's two planes side by side and the second pair after the first. nil where the console
    # keeps a tile as a list already holds one, two pixels a byte, so there is nothing to choose.
    # +blends+ marks whether its display can mix colours as it draws —
    # fade the finished picture, mix one layer into another — rather than only change the colours
    # in its lists. +fades_by_brightness+ marks whether a fade to black is its display's own brightness,
    # in the sixteen levels Backends::FadeSteps.dimmed gives. +mixes_by_half+ marks whether, without blending by degrees, it can still show a
    # layer half see-through — the Super Nintendo's colour math adds what is behind a layer to it
    # and halves the sum — which an amount the build rounds to an even half asks for, and nothing
    # else. +list_colors+ is how many places a list of colours holds. +painted_pages+ is
    # how many pictures a tear-free painted screen keeps: two where one is drawn while the other
    # is shown, one where the console only ever shows a picture whole. +clock_keeps_date+ marks
    # whether the clock chip its cartridges carry holds the date and time, or only counts the days
    # and the time of day since it started (IR::Clock). +extension+ ends the name of a cartridge
    # file for it.
    #
    # +color_bits+ is how many bits of each colour channel the console can show, counted from the
    # top: the five a game names a colour in, or the three of a console whose colours are 9 bits
    # in all. A picture is shown with the top +color_bits+ of each channel (the interpreter's
    # Framebuffer), so what a console cannot tell apart looks the same on every backend.
    #
    # +cycles_a_second+ is the clock the display counts in, and +cycles_a_frame+ how many of those
    # it takes to draw one picture and the gap after it: together they are how long a frame is,
    # which anything that keeps real seconds by counting frames needs. Neither console shows
    # exactly sixty a second. +samples_a_copy+ is how many samples of mixed sound one copy hands
    # the console's sound hardware, which decides the rates a mix can run at
    # (Console::SampleClock), or nil where the processor hands it no samples. The timer that marks when
    # the next sample is due counts in +sample_timer_step+ of those cycles at a time, and at most
    # +sample_timer_counts+ of them, so it can only wait a whole number of steps up to that many.
    # +recordings_at_once+ is how many recordings sound together; a play past that is dropped.
    # +mixes_recordings+ marks whether a recording can be shaped (`envelope:`), its loudness moved
    # sample by sample: the processor adds them up into a stream of its own, or the sound chip's
    # voices do that themselves. One that does neither plays a recording a sample at a time, all
    # or nothing, on a voice of the sound chip. +recording_voice_hz+ is, for a console whose
    # sound chip plays each recording on a voice of its own rather than having the processor mix
    # them, how many samples a second those voices read; nil elsewhere. +voice_output_hz+ is how
    # often it hands its sound chip's voices on to the speaker, which matters to the noise voice alone:
    # a hiss can step faster than that, and what is heard of one that does is whichever way it
    # stood at each of those moments, a hiss of its own and a lower one. A backend that makes the
    # sound itself looks at the hiss at the same moments to make the same one. +lowest_square_hz+ is
    # the bottom of a square voice, or nil where it has none: a chip that tunes one by a number of
    # clock ticks a wave runs out of ticks, and plays a lower note AT its bottom, a different note
    # with nothing to say so. A console whose square is a recording reads it more slowly and has no
    # such place. +largest_memory_bytes+ is how
    # many bytes the largest memory a game's lists and pools are kept in holds: one pool is kept
    # whole in one memory, so no pool can be bigger.
    #
    # How much a game can keep, which the build checks count against (Checks::IwramBudget):
    # +work_memory_bytes+ is the memory every variable lives in, +work_memory_kept_bytes+ how much
    # of it the build keeps for itself (the stack, the copy of the sprite table), and
    # +roomier_memory_bytes+ the memory beside it that lists and pools can move to, 0 where there is
    # none. +variables_go_far+ marks that the variables can move there too, when the work memory cannot
    # hold them all: where false, every variable must fit the work memory.
    #
    # +sprites_placed_before_wait+ marks where a game loop's pass places the frame's sprites and
    # scroll (IR::Frames.loop_in_console_order). A console that writes them straight into its display
    # in the gap between frames places them after the wait, from the pass just ended. One that
    # sends them from a copy as the wait ends places them before it, or they would show a frame
    # later than the pass that moved them.
    #
    # +changes_cells_while_drawing+ marks that a pass can write a cell of a background into the display's
    # memory as a frame is drawn, for rows the screen has not reached yet. One whose display locks
    # that memory until the frame is drawn cannot.
    #
    # +rumbles+ marks that a game's `rumble` is felt: the cartridge carries a motor the game turns on and
    # off. Where it is not, the verb does nothing, since a game plays the same without it.
    #
    # +plays_bios_start_up+ marks that a desktop build plays the console's own start-up before the game
    # (its logo and chime, run from the player's own copy of the console's BIOS, where the player has
    # one: runtime/rg_bios_boot.c). Where it is false the game starts at once, as it always does
    # without the BIOS.
    #
    # +whole_screen_size+ is [width, height] of the console's own screen where the game's screen is
    # smaller and is shown in the middle of it at its own size, with a border round it (a Game Boy
    # Color's 160×144 on the Advance's 240×160: Console::AdvanceKit::COLOR_SCREEN). The screen size
    # above is then the game's, which is what a game laid out for that screen reads and what the
    # interpreter plays; how the border is drawn is the console's lowering's own business. nil for
    # every console as it is, whose game's screen is the whole screen.
    #
    # +holds_background_above_row+ marks that a background can be kept to the rows above a row (`above_row:`),
    # and +glides_recordings+ that a recorded note can carry on at a new pitch (`glides: true`).
    #
    # +sets_main_volume+ marks that the console's build writes the main volume a game names
    # (`enable_sound main_volume:`) to its sound chip, which scales everything the chip plays. Where it
    # is false the build refuses such a game (Console::Questions), rather than play it louder.
    #
    # +background_box+ sets how a background is held to a box the game moves (`show_only_inside`):
    # :shared_windows where the display's windows do it and the light, a status bar and a fade held
    # to part of the screen use the same windows (the Advance); :own_window where a window does it
    # that nothing else in the game uses (the Super Nintendo); nil where nothing can.
    #
    # +area_clips_called_routines+ marks that a routine called from inside `inside` has its drawing held to
    # that area, as the interpreter holds it: the console's build keeps the area as numbers in memory
    # while the game runs, and every drawing routine reads them, wherever it was built. Where it is
    # false the build works each shape's clipping out from the edges as it writes the shape (the
    # Advance's ARM), so a routine built once, outside any area, draws past the area of whoever calls
    # it, and the build refuses such a call (Checks::CallInsideArea).
    Description = Data.define(:name, :title, :screen_width, :screen_height, :buttons, :controllers,
                              :holds_background_above_row, :background_box, :area_clips_called_routines,
                              :glides_recordings, :sets_main_volume, :sprites, :sprite_places,
                              :sprites_a_row, :sprite_pieces_drawn_a_line, :sprite_slivers_drawn_a_line,
                              :sprite_pixels_drawn_a_line, :sprite_piece_shape, :sprite_pieces_drawn_a_screen,
                              :sprite_table_filled_from, :turning_sprites, :sprite_sizes, :tile_planes, :backgrounds, :turning_backgrounds,
                              :backgrounds_beside_turning, :bar_is_a_background, :bar_shares_display, :changes_cells_while_drawing,
                              :blends, :fades_by_brightness, :mixes_by_half, :list_colors, :color_bits, :painted_pages,
                              :clock_keeps_date, :cycles_a_second, :cycles_a_frame, :samples_a_copy,
                              :sample_timer_step, :sample_timer_counts, :recordings_at_once, :mixes_recordings,
                              :recording_voice_hz, :lowest_square_hz,
                              :voice_output_hz, :largest_memory_bytes, :work_memory_bytes, :work_memory_kept_bytes,
                              :roomier_memory_bytes, :variables_go_far, :sprites_placed_before_wait, :rumbles, :plays_bios_start_up,
                              :whole_screen_size, :extension, :code_cache_bytes, :face_fill_skips_outside_window,
                              :face_fill_by_row_middles, :pixel_size, :shows_bigger_pixels,
                              :pose_lists, :sprites_in_blocks, :voices_read_sound_memory, :big_background_tiles,
                              :shown_rows, :gives_up_rows) do
      # +code_cache_bytes+ is how much of the game's code the processor keeps in a cache of its own and
      # runs without going out to memory for each instruction, or nil for a processor with none (it
      # reads every instruction from memory as it runs it, or memory as quick as a cache). Where it is
      # small, a routine run over and over is best written short, as a loop, so it stays in the cache
      # (IR::PlaceDrawing#face_loop_statements).
      #
      # +face_fill_skips_outside_window+ is true where the console's cartridge fills a place's faces
      # with a routine of its own that passes over a face wholly outside its window before it does any
      # work for it, so the shared drawing leaves its own test of that out (IR::PlaceDrawing::OUTCODE_EDGES).
      # The drawing is made once for the console, so a computer's build of such a game (as C,
      # JavaScript or Ruby) leaves it out too: it fills those faces and draws nothing of them.
      #
      # +face_fill_by_row_middles+ is true where a face is filled as the interpreter fills it
      # (Reference#exec_fill_face): a row is drawn where an edge crosses the row's middle. There a face
      # whose corners all lie between two rows' middles draws nothing, and the shared drawing passes
      # it over before it hands the corners on (IR::PlaceDrawing#whole_face_statements). False for a
      # console whose fill puts the corners on whole pixels first, which can draw such a face's row.
      #
      # +pixel_size+ is how many of the console's pixels across, and as many down, one pixel of the
      # game's picture is shown as: 1 for a game that sets nothing, 2 for a game that draws a picture
      # half as wide and half as tall and has the console show each pixel as a square of four
      # (`screen :bitmap, pixel_size: 2`, #with_pixel_size). The screen size above is then the
      # game's small picture, which is what the game lays itself out on and what the interpreter
      # plays. +shows_bigger_pixels+ marks whether the console's hardware can show it that way.
      #
      # +pose_lists+ sets what the console's build makes of one sprite whose poses are drawn from
      # different lists of colours. A console's sprite table names the group of colours of each entry
      # beside its tile, so its own games change the two together for nothing; what differs is how far
      # each build goes. :one where the build keeps one group for a whole sprite, so such a sprite is
      # refused, naming the console. :own where it writes the group with the pose's tiles, so each
      # pose is shown in its own list's colours. :followed where such a sprite can also follow its
      # lists, each pose shown in what its list holds now (IR::Nodes::Object#follows_each); under :own
      # that is refused, naming the console. Checks::PosesWithDifferentColors makes both refusals.
      #
      # +sprites_in_blocks+ marks whether the display can show its sprites in blocks when the game
      # pixelates (`pixelate`), as well as its backgrounds. False where its blocks reach the
      # backgrounds alone (the Super Nintendo's mosaic), and nil where it has no blocks at all,
      # which its answers refuse whole.
      #
      # +voices_read_sound_memory+ marks a sound chip that plays each of the game's four voices as a
      # loop it reads out of a memory of its own (the PlayStation's: Backends::PS1::SoundMemory), where
      # the Game Boy family's chip makes its square waves, waveform and hiss itself. A desktop, web or
      # Ruby build made as such a console plays its voices that chip's way (runtime/rg_spu.c), so it
      # sounds like the console it was made as.
      #
      # +big_background_tiles+ marks a console whose hardware draws a background from tiles of 16x16
      # as well as 8x8 (the Super Nintendo's, BGMODE's size bits), so a cell of 16x16 is one entry of
      # its map. A background from the data pack whose cells are 16x16 is built from pictures of that
      # size there (Builder::PackBackgrounds#big_pack_cells?), as the original's map is.
      #
      # +shown_rows+ is [first, past] of the rows of the screen a game's picture shows
      # (`screen :bitmap, shown_rows:`, #with_shown_rows), or nil for every row: the rows outside
      # are given up and show black. +gives_up_rows+ marks a console that gains from it: one whose
      # video memory takes writes only while it is not drawing, and that can switch the screen off
      # for those rows, so the copy has them as well as the blank (the Super Nintendo's forced
      # blank, written line by line: Backends::SNES::Runtime::Letterbox).
      def initialize(code_cache_bytes: nil, face_fill_skips_outside_window: false, face_fill_by_row_middles: true,
                     pixel_size: 1, shows_bigger_pixels: false, pose_lists: :one, sprites_in_blocks: true,
                     voices_read_sound_memory: false, big_background_tiles: false, shown_rows: nil,
                     gives_up_rows: false, sprite_pieces_drawn_a_screen: nil, sprite_slivers_drawn_a_line: nil,
                     sprite_pixels_drawn_a_line: nil, sprite_piece_shape: :small, sprite_table_filled_from: :front,
                     **rest) = super

      # Whether one sprite can show poses drawn from different lists of colours (see +pose_lists+).
      def poses_keep_own_lists? = pose_lists != :one

      # Whether such a sprite can follow the lists its poses are drawn from.
      def poses_follow_lists? = pose_lists == :followed

      def screen_size = [screen_width, screen_height]

      # This console with each of the game's pixels shown +size+ pixels across and down: its screen,
      # as the game sees it, that many times smaller. The console as it is for a size of 1 or nil.
      # A desktop build of it plays no start-up, whose logo is drawn for the whole screen.
      def with_pixel_size(size)
        return self if size.nil? || size == 1

        with(screen_width: screen_width / size, screen_height: screen_height / size, pixel_size: size,
             plays_bios_start_up: false)
      end

      # This console showing only the rows [first, past] of +rows+ (see +shown_rows+); the console
      # as it is for nil.
      def with_shown_rows(rows) = rows ? with(shown_rows: rows) : self

      # The first row the picture shows and the one past its last: the whole screen where the game
      # gives up none.
      def shown_row_bounds = shown_rows || [0, screen_height]

      # Whether a pixel of the game's picture is shown bigger than one of the console's.
      def bigger_pixels? = pixel_size > 1

      # The size of the picture the console shows, in its own pixels: the game's screen with each of
      # its pixels shown #pixel_size times across and down.
      def shown_screen_size = [screen_width * pixel_size, screen_height * pixel_size]

      # Whether the game's screen is shown in a border, inside a bigger screen (#whole_screen_size).
      def bordered? = !whole_screen_size.nil?

      # Where the game's screen starts inside the whole screen, [left, top] in pixels: the middle.
      # [0, 0] for a console showing the game's screen whole.
      def border_corner
        return [0, 0] unless bordered?

        [(whole_screen_size[0] - screen_width) / 2, (whole_screen_size[1] - screen_height) / 2]
      end

      # How much of the work memory is free for a game's own variables and lists.
      def free_work_memory_bytes = work_memory_bytes - work_memory_kept_bytes

      # +color+ (a 15-bit value) as this console shows it: with the top #color_bits of each channel.
      def shown(color) = Graphics::Color.kept(color, bits: color_bits)

      # Whether there is a roomier memory beside the work memory for lists and pools to move to.
      def roomier_memory? = roomier_memory_bytes.positive?

      # How long one frame is, in seconds.
      def frame_seconds = Rational(cycles_a_frame, cycles_a_second)

      # The clock a mix of recordings runs at, as near +hz+ as this console's sound can keep up
      # with (see Console::SampleClock) — or, where each recording plays on a voice of the sound
      # chip, the rate those voices read at, whatever +hz+ is.
      def sample_clock(hz)
        recording_voice_hz ? SampleClock.on_voices(recording_voice_hz, self) : SampleClock.nearest(hz, self)
      end

      # Whether it has a clock to play a recording by: voices that read one, or a timer that hands
      # the sound samples. A console with neither cannot give how a recording plays yet.
      def sample_clock? = !recording_voice_hz.nil? || !samples_a_copy.nil?

      # Whether any of its backgrounds can turn and resize.
      def turns_backgrounds? = turning_backgrounds.positive?

      # How many backgrounds scroll at one time, on a screen where one turns or where none does.
      def scrolling_backgrounds(turning:) = turning ? backgrounds_beside_turning : backgrounds

      # The middle of the screen, in whole pixels.
      def middle = [screen_width / 2, screen_height / 2]
    end

    # The sizes of pixel a game can ask for (`screen :bitmap, pixel_size:`). Each divides every
    # console's screen into whole pixels.
    Description::PIXEL_SIZES = [1, 2].freeze

    # The Game Boy Advance.
    ADVANCE = Description.new(name: :gba, title: "Game Boy Advance", screen_width: 240, screen_height: 160,
                              buttons: %i[a b select start right left up down r l].freeze, controllers: 1,
                              holds_background_above_row: false, background_box: :shared_windows, glides_recordings: false, sets_main_volume: false, sprites: 128,
                              # Each shape is clipped against the area's edges as the ARM is
                              # written (Backends::GBA::Statements#emit_inside).
                              area_clips_called_routines: false,
                              # The most the desktop and web builds draw in one frame, too.
                              sprite_places: 512,
                              # What limits a row on the Advance is the time the display has to
                              # draw it, which depends on how wide each sprite is and whether it
                              # turns, and the build does not work that out.
                              sprites_a_row: nil, sprite_pieces_drawn_a_line: nil, turning_sprites: true, sprite_sizes: Hardware::OBJ_SIZES.keys, tile_planes: nil,
                              # Four layers that scroll, or two that scroll and one that turns.
                              backgrounds: 4, turning_backgrounds: 1, backgrounds_beside_turning: 2,
                              # A status bar is one of those layers.
                              bar_is_a_background: true, bar_shares_display: true,
                              changes_cells_while_drawing: true,
                              blends: true, fades_by_brightness: false, mixes_by_half: false, list_colors: 16, color_bits: 5, painted_pages: 2, clock_keeps_date: true,
                              # 228 lines of 1232 cycles: 160 drawn, and 68 the gap after.
                              cycles_a_second: 16_777_216, cycles_a_frame: 280_896,
                              # The sound copy moves four 32-bit words at a time: sixteen 8-bit samples.
                              samples_a_copy: 16,
                              # ...on a timer counting every cycle, up to its 16 bits.
                              sample_timer_step: 1, sample_timer_counts: 65_536,
                              # The framework's number, not the hardware's (Audio::Sound::MIXER_VOICES).
                              recordings_at_once: 16, mixes_recordings: true,
                              # The voices are mixed into the speaker's output at the rate the
                              # sound's bias register starts at, which no cartridge built here changes.
                              recording_voice_hz: nil, lowest_square_hz: 64, voice_output_hz: 32_768,
                              # The 256K of roomier memory beside the 32K quick one.
                              largest_memory_bytes: 256 * 1024,
                              # The 32K quick memory, 4K of it the stack and the framework's own.
                              work_memory_bytes: 32 * 1024, work_memory_kept_bytes: 4 * 1024,
                              roomier_memory_bytes: 256 * 1024,
                              # A variable is reached by its distance from the quick memory's start.
                              variables_go_far: false,
                              # The sprite table and the scroll are written straight into the
                              # console in the gap after the wait, and show on the frame after it.
                              sprites_placed_before_wait: false,
                              # Its rumble cartridges are not made here yet: nothing is felt.
                              rumbles: false,
                              # The logo and its chime, played from the player's own BIOS.
                              plays_bios_start_up: true, whole_screen_size: nil, extension: ".gba",
                              # The fill in ARM (Backends::GBA::Faces) tests a face's corners against
                              # its window itself, in fewer instructions than the shared test.
                              face_fill_skips_outside_window: true,
                              # The painted screen is drawn through a background that resizes, so
                              # told to read half a pixel a step it shows each pixel as four.
                              shows_bigger_pixels: true)

    # The Game Boy Color: a smaller screen, eight buttons, forty sprites and ten on a row, one
    # background, nothing that turns, lists of four colours, and a clock that counts days. What
    # each verb does on it is Console::ColorAnswers's to say.
    COLOR = Description.new(name: :gbc, title: "Game Boy Color", screen_width: 160, screen_height: 144,
                            buttons: %i[a b select start right left up down].freeze, controllers: 1,
                            holds_background_above_row: false, background_box: nil, glides_recordings: false, sets_main_volume: false, sprites: 40, sprite_places: 40,
                            # rt_paint_area keeps the area in memory (GBC::Lowering::Picture#emit_inside).
                            area_clips_called_routines: true,
                            # The first ten pieces its table holds on a line, every other left out
                            # (each piece is a sprite of its own, 8 wide), and forty pieces on the
                            # whole screen, the forty entries of its table.
                            sprites_a_row: 10, sprite_pieces_drawn_a_line: 10, sprite_pieces_drawn_a_screen: 40,
                            turning_sprites: false, sprite_sizes: nil, tile_planes: 2,
                            backgrounds: 1, turning_backgrounds: 0, backgrounds_beside_turning: 0,
                            # A status bar is the window, a layer beside the one background.
                            bar_is_a_background: false, bar_shares_display: true,
                            changes_cells_while_drawing: true,
                            blends: false, fades_by_brightness: false, mixes_by_half: false, list_colors: 4, color_bits: 5, painted_pages: 1, clock_keeps_date: false,
                            # 154 lines of 456 cycles: the Advance's frame exactly, on a clock a
                            # quarter as fast. Double speed doubles the cycles, not the frames.
                            cycles_a_second: 4_194_304, cycles_a_frame: 70_224,
                            # One recording at a time, a sample each time the timer runs out,
                            # handed to the sound chip by the processor itself. The timer counts
                            # every sixteenth cycle of the processor, which runs at double speed:
                            # every eighth of these. It holds a byte, so it waits 256 counts at most.
                            samples_a_copy: 1, sample_timer_step: 8, sample_timer_counts: 256,
                            recordings_at_once: 1, mixes_recordings: false,
                            # Nothing stands between the voices and the speaker: every step of the
                            # hiss is heard, which is every tick of the noise voice's own clock
                            # (Audio::Sound::NOISE_CLOCK_HZ) at the most. The emulator the tests
                            # play in takes a sample every 32 cycles instead and averages the hiss
                            # over each, which is its own approximation of the same thing.
                            recording_voice_hz: nil, lowest_square_hz: 64, voice_output_hz: 524_288,
                            # The 8K of work memory in view at once (see Backends::GBC::Memory),
                            # and nothing beside. The stack, the copy of the sprite table and the
                            # runtime's own state are in it before any variable, which the Color
                            # lowering's tests hold this to (test_gbc_memory.rb).
                            largest_memory_bytes: 8 * 1024,
                            work_memory_bytes: 8 * 1024, work_memory_kept_bytes: 2048,
                            roomier_memory_bytes: 0, variables_go_far: false,
                            # The sprite table and the scroll are sent from a copy as the wait
                            # ends, so a pass's are placed before it to show on the frame after.
                            # Each piece's attributes name its list (Backends::GBC::Lowering::Picture
                            # #pose_rows). A sprite that follows its poses' lists is not made yet.
                            pose_lists: :own,
                            sprites_placed_before_wait: true,
                            # A cartridge with a motor, for a game that rumbles (Runtime::Rumble).
                            rumbles: true,
                            # Its own start-up is not played: the game starts at once.
                            plays_bios_start_up: false, whole_screen_size: nil, extension: ".gbc",
                            # It has no mosaic.
                            sprites_in_blocks: nil)

    # The Super Nintendo: a wider and taller screen than the Advance's, twelve buttons (a game reads
    # the ten the Advance has), 128 sprites and 34 pieces of them on a row, backgrounds of tiles,
    # nothing that turns but one layer the build does not use, lists of sixteen colours. What each
    # verb does on it is Console::SNESAnswers's to say.
    SUPER_NINTENDO = Description.new(name: :snes, title: "Super Nintendo", screen_width: 256, screen_height: 224,
                                     buttons: %i[a b select start right left up down r l x y].freeze, controllers: 2,
                                     holds_background_above_row: true, background_box: nil, glides_recordings: true, sets_main_volume: true, sprites: 128,
                                     # rt_paint_area keeps the area in memory, and a routine on a
                                     # Super FX chip is handed it (SNES::Lowering::Paint#emit_inside,
                                     # SNES::ChipCode#area_places).
                                     area_clips_called_routines: true,
                                     sprite_places: 128,
                                     # A row of the screen shows at most 32 entries of the sprite
                                     # table and 34 slivers 8 pixels wide of them; a sliver is what
                                     # the build's warning counts. The first 32 entries that reach the
                                     # line are kept, front-most first, and their slivers fetched from
                                     # the back, so past 34 the entries in front lose theirs. A square
                                     # of 16×16 is one entry and two slivers, and a sliver off the
                                     # screen is not fetched (measured in bsnes).
                                     sprites_a_row: 34, sprite_pieces_drawn_a_line: 32, sprite_slivers_drawn_a_line: 34,
                                     sprite_piece_shape: :squares,
                                     # The table's 128 rows, filled from the sprite furthest back,
                                     # so past them the pieces in front are not drawn (measured in
                                     # bsnes).
                                     sprite_pieces_drawn_a_screen: 128, sprite_table_filled_from: :back,
                                     turning_sprites: false,
                                     # Every sprite picture is cut into 8×8 pieces (Backends::SNES::Art).
                                     sprite_sizes: nil, tile_planes: 4,
                                     # The build shows a game's backgrounds on the arrangement of
                                     # layers called mode 1: two of sixteen colours and one of four.
                                     # The build puts a status bar, or a background held above a
                                     # row, on the one of four, beside two other backgrounds
                                     # (Backends::SNES::Lowering::Picture.third_layer?); three with
                                     # neither among them it does not make yet, and says so.
                                     # Mode 7 turns one layer, alone; the build uses it only to
                                     # show a painted screen of big pixels.
                                     backgrounds: 3, turning_backgrounds: 0, backgrounds_beside_turning: 0,
                                     bar_is_a_background: true, bar_shares_display: true,
                                     # Its colour maths adds, subtracts or halves, never the
                                     # Advance's sixteen steps, so a fade is walked colour by colour.
                                     changes_cells_while_drawing: false,
                                     blends: false, fades_by_brightness: true, mixes_by_half: true, list_colors: 16, color_bits: 5,
                                     # A painted screen is copied whole to the console before it
                                     # is shown, as the Color's is.
                                     painted_pages: 1, clock_keeps_date: false,
                                     # 262 lines of 1364 cycles of the console's master clock, less
                                     # four cycles every other frame: sixty frames a second and a little.
                                     cycles_a_second: 21_477_270, cycles_a_frame: 357_366, samples_a_copy: nil,
                                     # No timer hands the sound chip samples: its eight voices each
                                     # read a recording of their own, and loop it, pitch it and
                                     # scale it themselves.
                                     sample_timer_step: nil, sample_timer_counts: nil,
                                     recordings_at_once: 8, mixes_recordings: true,
                                     # The sound chip's voices are mixed 32000 times a second, and
                                     # each plays a recording of its own at that rate.
                                     recording_voice_hz: 32_000, lowest_square_hz: nil, voice_output_hz: 32_000,
                                     # Lists and pools go in the 120K of work RAM past the first 8K,
                                     # 64K of it to one.
                                     largest_memory_bytes: 64 * 1024,
                                     # The first 8K of work RAM is in view from the cartridge's code, so
                                     # the variables go there first; the stack and the runtime's own
                                     # state take some of it before them. The variables the game names
                                     # least go past it when it is full, each reached by its whole
                                     # address (see Backends::SNES::Memory).
                                     work_memory_bytes: 8 * 1024, work_memory_kept_bytes: 2048,
                                     roomier_memory_bytes: 120 * 1024, variables_go_far: true,
                                     # The wait sends the sprite table and the scroll from a copy, so
                                     # a pass places them in it before its wait, as the Color's does.
                                     # Each picture's pieces name its palette (Backends::SNES::Art). A
                                     # sprite that follows its poses' lists is not made yet.
                                     pose_lists: :own,
                                     sprites_placed_before_wait: true,
                                     # No cartridge with a motor is made for it.
                                     rumbles: false, plays_bios_start_up: false, whole_screen_size: nil,
                                     # Its mosaic (MOSAIC, $2106) has a switch for each background
                                     # and none for the sprites.
                                     sprites_in_blocks: false,
                                     big_background_tiles: true,
                                     # Video memory takes writes only in the blank or with the screen
                                     # off, and the screen can be switched off line by line.
                                     gives_up_rows: true,
                                     # A painted screen of big pixels is shown on Mode 7's layer,
                                     # whose matrix reads half a pixel a step
                                     # (Backends::SNES::Runtime::PaintDoubled).
                                     shows_bigger_pixels: true,
                                     extension: ".sfc")

    # The Sega Genesis: a 320×224 screen, a pad of seven buttons (the D-pad, A, B, C and Start: no
    # Select and no shoulder buttons), 80 sprites and 20 of them on a row, two backgrounds of
    # tiles, nothing that turns, four lists of sixteen colours, and colours of 9 bits, three to a
    # channel. What each verb does on it is Console::GenesisAnswers's to say.
    GENESIS = Description.new(name: :genesis, title: "Sega Genesis", screen_width: 320, screen_height: 224,
                              buttons: %i[a b c start right left up down].freeze, controllers: 1,
                              holds_background_above_row: false, background_box: nil, glides_recordings: false, sets_main_volume: false, sprites: 80, sprite_places: 80,
                              # The area is kept in memory (Genesis::Lowering::Paint#emit_inside).
                              area_clips_called_routines: true,
                              # A row of the screen shows at most 20 entries of the sprite table (16
                              # on a screen of 256 across), and an entry here is one piece of a
                              # picture, up to 32×32. The first 20 that reach the line are kept,
                              # front-most first, and drawn front-most first until 320 pixels are
                              # spent: each spends its whole width, its blank pixels and those off
                              # the screen too (measured in Genesis Plus GX).
                              sprites_a_row: 20, sprite_pieces_drawn_a_line: 20, sprite_pixels_drawn_a_line: 320,
                              sprite_piece_shape: :rectangles,
                              # The table's 80 rows, filled from the sprite furthest back, so past
                              # them the pieces in front are not drawn (measured in Genesis Plus GX).
                              sprite_pieces_drawn_a_screen: 80, sprite_table_filled_from: :back,
                              turning_sprites: false,
                              # Every sprite picture is covered by pieces of whole 8×8 tiles, up to
                              # four across and four down (Backends::SpritePieces.cover).
                              sprite_sizes: nil, tile_planes: nil,
                              # Two planes of tiles that scroll. The window plane is a third, but it
                              # only covers whole rows of tiles and the build does not use it.
                              backgrounds: 2, turning_backgrounds: 0, backgrounds_beside_turning: 0,
                              bar_is_a_background: false, bar_shares_display: true,
                              # The build writes video RAM only in the gap between frames.
                              changes_cells_while_drawing: false,
                              # Nothing mixes one layer into another by degrees, and the shadow and
                              # highlight modes halve and brighten the whole picture, not a layer.
                              blends: false, fades_by_brightness: false, mixes_by_half: false, list_colors: 16, color_bits: 3,
                              # A painted screen is kept in work RAM and copied to the console
                              # whole before it is shown, so it holds one picture.
                              painted_pages: 1, clock_keeps_date: false,
                              # 262 lines of 3420 cycles of the console's master clock: sixty frames a
                              # second and a little under.
                              cycles_a_second: 53_693_175, cycles_a_frame: 896_040,
                              # No timer hands the sound chip samples: the sound processor writes a
                              # recording to the FM chip's sixth voice, a byte at a time, and its program
                              # (IR::Backends::Genesis::Runtime::Recordings) takes this many a second.
                              samples_a_copy: nil, sample_timer_step: nil, sample_timer_counts: nil,
                              recordings_at_once: 1, mixes_recordings: false,
                              recording_voice_hz: 13_000, lowest_square_hz: 109, voice_output_hz: 223_722,
                              # Lists and pools go in the work RAM past the runtime's own places.
                              largest_memory_bytes: 64 * 1024,
                              # All 64K of work RAM is in view from the cartridge's code, so every
                              # variable is there; the stack, the runtime's own state and a painted
                              # screen's copy of the picture take some of it first (see
                              # Backends::Genesis::Memory).
                              work_memory_bytes: 64 * 1024, work_memory_kept_bytes: 4096,
                              roomier_memory_bytes: 0, variables_go_far: false,
                              # The wait sends the sprite table and the scroll from a copy, so a
                              # pass places them in it before its wait, as the Super Nintendo's does.
                              # Each picture's pieces name its palette, cut against the list it
                              # follows (Backends::Genesis::Lowering::Picture#followed_list_of).
                              pose_lists: :followed,
                              sprites_placed_before_wait: true,
                              # No cartridge with a motor is made for it.
                              rumbles: false, plays_bios_start_up: false, whole_screen_size: nil,
                              # It has no mosaic.
                              sprites_in_blocks: nil,
                              extension: ".gen")

    # The PlayStation: a 320×240 screen, a pad whose buttons a game names by the shared names (Cross is
    # :a, Circle :b, Triangle :x, Square :y, L1 and R1 :l and :r), pictures drawn by a graphics chip with no
    # limit of sprites on a row, colours of fifteen bits and lists of 256 of them. What each verb does on it
    # is Console::PS1Answers's to say.
    PLAYSTATION = Description.new(name: :ps1, title: "PlayStation", screen_width: 320, screen_height: 240,
                                  buttons: %i[a b select start right left up down r l x y].freeze,
                                  # Two ports for pads (the build reads the first alone for now).
                                  controllers: 2,
                                  # A background is a picture the graphics chip draws, so it can be held to
                                  # a box (the chip's drawing area) that nothing else uses. A recorded note
                                  # can glide: its voice's pitch is a register written while it plays.
                                  holds_background_above_row: false, background_box: :own_window, glides_recordings: true, sets_main_volume: false,
                                  # The area is kept in memory (PS1::Lowering::Paint#emit_inside).
                                  area_clips_called_routines: true,
                                  # The graphics chip draws every sprite each frame as a textured rectangle,
                                  # so the number is the framework's, not the hardware's.
                                  sprites: 128, sprite_places: 512,
                                  # Nothing limits a row: the chip draws whatever it is sent.
                                  # The chip draws a turned or resized sprite as a textured quad.
                                  sprites_a_row: nil, sprite_pieces_drawn_a_line: nil, turning_sprites: true,
                                  sprite_sizes: nil, tile_planes: nil,
                                  # ...and a turned background the same way, beside the others, as the Advance shows it.
                                  backgrounds: 4, turning_backgrounds: 1, backgrounds_beside_turning: 2,
                                  # A status bar is one more plane the chip draws, kept to its rows by where it
                                  # is drawn, so it shares nothing with anything else.
                                  bar_is_a_background: true, bar_shares_display: false,
                                  # Video RAM can be written while a frame is drawn.
                                  changes_cells_while_drawing: true,
                                  # The chip mixes by halves and sums, never by sixteen steps, so a fade is
                                  # walked colour by colour.
                                  blends: false, fades_by_brightness: false, mixes_by_half: true, list_colors: 256,
                                  color_bits: 5,
                                  # A tear-free painted screen is two pictures in video RAM, one drawn
                                  # while the other is shown.
                                  painted_pages: 2, clock_keeps_date: false,
                                  # The processor's clock, and the cycles of it one NTSC frame takes, as
                                  # measured in Beetle PSX (the sound chip makes a pair of samples every 768
                                  # cycles: test_ps1_boot.rb).
                                  cycles_a_second: 33_868_800, cycles_a_frame: 566_122,
                                  # The sound chip's 24 voices each read a recording of their own. Four of
                                  # them are the game's square, wave and noise voices
                                  # (Backends::PS1::SPUWrites::VOICES), so 20 are left for recordings, and
                                  # the build plays 16 at once, on voices 4 to 19 (Runtime::Recordings).
                                  # Sixteen, and not 20, because a recording past the console's number is
                                  # dropped and counted (Reference::Mixer#record_drop), and the desktop, web
                                  # and Ruby builds made as the PlayStation mix their recordings in a mixer
                                  # of 16 voices (Audio::Sound::MIXER_VOICES): at 20 the console would sound
                                  # a play those builds drop. Sixteen is also the framework's number on
                                  # every console that mixes, so a game sized for one fits the others.
                                  samples_a_copy: nil, sample_timer_step: nil, sample_timer_counts: nil,
                                  recordings_at_once: 16, mixes_recordings: true,
                                  recording_voice_hz: 44_100, lowest_square_hz: nil, voice_output_hz: 44_100,
                                  # Every voice reads a loop out of sound memory (Backends::PS1::SoundMemory).
                                  voices_read_sound_memory: true,
                                  # Lists and pools go in main RAM with the program after them
                                  # (Backends::PS1::Memory): 2 megabytes less the BIOS's 64K and the
                                  # stack's 32K, which the two share. The build says whether they fit
                                  # together once it knows how big the program came to.
                                  largest_memory_bytes: 1952 * 1024,
                                  work_memory_bytes: 1952 * 1024, work_memory_kept_bytes: 4096,
                                  roomier_memory_bytes: 0, variables_go_far: false,
                                  # A pass's drawing is sent to the graphics chip as its wait begins, its
                                  # sprites placed before it, so the frame after the wait shows the pass
                                  # just ended (Runtime::Tiles' rt_tiles_draw; test_frame_pairing.rb
                                  # holds it to that on the PlayStation's run). Each pose is a picture
                                  # of its own, drawn from its own list.
                                  pose_lists: :followed,
                                  sprites_placed_before_wait: true,
                                  rumbles: false, plays_bios_start_up: false, whole_screen_size: nil,
                                  extension: ".exe",
                                  # The R3000 keeps the last 4K of code it ran (psx-spx, "Memory Map").
                                  code_cache_bytes: 4096,
                                  # Its graphics chip fills a face from corners on whole pixels, not by
                                  # rows' middles (Backends::PS1::PolygonFill).
                                  face_fill_by_row_middles: false)

    # Each console's description is reached through its kit (Console::Kit, Console.described).

    # The consoles a game names as the ones it is for, as a frozen list of names: one name or a list of them.
    # A name no console has, or no name at all, is refused, since no console is the one a game is
    # for when it names none. +setting+ is what the game wrote them in (`consoles:` where the
    # game is named, `t.consoles` in its Rakefile), so both are checked alike and the refusal says
    # which.
    def self.refuse_unknown_consoles!(consoles, setting:)
      named = Array(consoles).map(&:to_sym)
      named.each { |name| described(name) }
      if named.empty?
        raise ArgumentError, "#{setting} names no console. Name the consoles the game is for: #{Console.how_to_name_consoles}"
      end

      named.freeze
    end
  end
end
