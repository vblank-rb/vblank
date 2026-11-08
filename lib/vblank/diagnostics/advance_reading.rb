# frozen_string_literal: true

module VBlank
  module Diagnostics
    # WHAT A READER OVER A RUNNING GAME BOY ADVANCE CARTRIDGE CAN BE ASKED that only the Advance's
    # way of keeping things answers: which sprite in the console's table is whose, how many passes
    # of the game loop it finished, what its mixer of recordings is playing, and the processor
    # itself — the registers, where each routine starts, the wave voice's pitch, the button reads.
    #
    # The Verifier is the one reader for every console, and a reader over an Advance cartridge is
    # given these when it is made (Console::Kit#reading). Everything else it reads — the picture,
    # memory by address, the variables, the save memory, the sound that came out — is the same on
    # every console and is the Verifier's own. A reader over another console's cartridge never has
    # these: it is not asked the processor's registers and then refused, it has no such question.
    module AdvanceReading
      # HOW THE CONSOLE'S 512 COLOURS ARE LAID OUT: the backgrounds' 256 first, then the
      # sprites'. Each half is sixteen groups of sixteen, and a sprite is told which group it
      # draws from — so these are what turns "group 4" into a place in the table.
      PALETTE = Verifier::PaletteLayout.new(half: 256, group: 16)

      # THE SOUND CHIP'S REGISTERS, a byte at a time, for Verifier#watch_sound: the four voices'
      # settings and the mixer's, SOUND1CNT_L at 0x0400_0060 to SOUNDBIAS at 0x0400_0088. The wave
      # voice's own memory (from 0x0400_0090) and the recorded sound's FIFOs (from 0x0400_00A0) are
      # left out: the FIFOs are written thousands of times a second and start no note.
      SOUND_REGISTER_ADDRESSES = (0x0400_0060..0x0400_0089)
      def sound_register_addresses = SOUND_REGISTER_ADDRESSES
      # A game writes these registers sixteen bits at a time, and a write is listed at its even
      # address with the sixteen bits written (the emulator hands them over widened to 32 with the sign).
      def sound_write_mask = 0xFFFF

      # THE VIDEO REGISTERS THAT CAN BE READ BACK, by the manual's names: which layers and mode
      # are on, each background's settings, the windows, and the blending. The scroll registers
      # cannot be read back on the console, so the scroll is a memory of its own below, read from
      # what the emulator kept.
      VIDEO_REGISTERS = { DISPCNT: 0x0400_0000, BG0CNT: 0x0400_0008, BG1CNT: 0x0400_000A, BG2CNT: 0x0400_000C,
                          BG3CNT: 0x0400_000E, WININ: 0x0400_0048, WINOUT: 0x0400_004A, BLDCNT: 0x0400_0050,
                          BLDALPHA: 0x0400_0052 }.freeze

      # Where the table of 128 sprites is, and how many bytes it holds: eight for each sprite,
      # the last two of each eight being the rotation numbers kept between them.
      SPRITE_TABLE = 0x0700_0000
      SPRITE_TABLE_BYTES = 1024

      # WHAT THE CONSOLE MAKES ITS PICTURE FROM, other than the tiles' pictures: each memory a
      # list of what is at each place in it, by where (Comparison::VideoDifference names the
      # first place two cartridges differ). +colors+ is the 512 colours by their number,
      # +sprite_table+ the table of sprites as halfwords by their byte in it, +scroll+ each
      # background's scroll across and down, and +registers+ the registers above by name.
      def video_memories
        ensure_rendered!
        { colors: palette.each_with_index.to_h { |color, at| [at, color] },
          sprite_table: (0...SPRITE_TABLE_BYTES).step(2).to_h { |at| [at, mem16(SPRITE_TABLE + at)] },
          scroll: (0..3).each_with_object({}) do |which, kept|
            across, down = @probe.scroll(which)
            kept[:"background #{which} across"] = across
            kept[:"background #{which} down"] = down
          end,
          registers: VIDEO_REGISTERS.transform_values { |address| mem16(address) } }
      end

      # THE SPRITE TABLE AS BOXES (SpriteBox), one for each entry switched on that reaches the
      # screen, in the table's order. Nothing here needs a build record, so it is how a cartridge
      # with none shows where its sprites are. A turned entry is the size of its picture, not of the
      # doubled box a turned sprite can be drawn in. Across wraps at 512 and down at 256, as the
      # console wraps them.
      #
      # @return [Array<SpriteBox>]
      def sprite_boxes
        ensure_rendered!
        # Shape 3 is no shape: the console draws nothing for it, so it has no box.
        boxes = @probe.sprites.filter_map do |row|
          sizes = SPRITE_SIZES[row[:shape]] or next
          width, height = sizes.fetch(row[:size])
          SpriteBox.new(slot: row[:slot], x: SpriteBox.wrapped(row[:x], width, 512),
                        y: SpriteBox.wrapped(row[:y], height, 256), width: width, height: height, tile: row[:tile])
        end
        boxes.select { |box| box.on_screen?(screen_width, screen_height) }
      end

      # A sprite's [width, height] in pixels, by its shape (square, wide, tall) and its size, 0 to 3.
      SPRITE_SIZES = Ractor.make_shareable([[[8, 8], [16, 16], [32, 32], [64, 64]],
                                            [[16, 8], [32, 8], [32, 16], [64, 32]],
                                            [[8, 16], [8, 32], [16, 32], [32, 64]]])

      # A list here is its slots, with its length and, for one the game shifts, where its oldest
      # item is, kept apart from them (IR::Backends::GBA::Lists#list_places).
      private def kept_list_items(place)
        front = place.head_at ? var_at(place.head_at) : 0
        Array.new(var_at(place.length_at)) do |i|
          little_slot(place.base + (((front + i) % place.slots) * place.bytes), place.bytes)
        end
      end

      # How many instructions {#run_until} runs before it gives up: several frames of a game
      # that never sleeps.
      RUN_UNTIL_LIMIT = 2_000_000

      # WHERE THE SAVE CHIP ENDS IN THE FILE THE EMULATOR KEEPS IT IN. A cartridge given a clock has
      # mGBA write 16 bytes of the clock's own state after the chip (its time and settings, and when
      # it wrote them), and a save chip is a whole number of kilobytes.
      SAVE_FILE = Verifier::SaveFileLayout.new(whole: 1024, clock_bytes: 16)

      # HOW MANY TIMES ROUND THE GAME LOOP THE CONSOLE GOT, in the frames it ran (see
      # Verifier for what a pass is and why it is not the frame count). Build the Verifier with
      # `count_passes: true` to ask for it.
      #
      # It is counted by watching for the loop's own first instruction, so the cartridge
      # measured is the cartridge that ships. The alternative is adding a counter to the
      # program, and one extra instruction can tip a routine out of the console's quick memory
      # and change the timing being measured.
      #
      # PASSES FINISHED, not passes begun. A run stops at a frame boundary, where the game is
      # part-way through a pass — it has asked for the next frame and is waiting for it — so
      # the pass in flight is not counted. A program with no game loop has no passes and gets
      # nil, which is a different answer from none.
      #
      # WHICH INSTRUCTION IS WATCHED depends on where the build put the loop, and the two
      # answers are chosen so that neither has to guess where the game is when the run stops.
      #
      # A loop the build kept in the console's quick memory is a routine the loop CALLS, so its
      # first instruction runs once at the START of every pass — the one in flight included, and
      # there is always one in flight. Passes finished is then one fewer than the arrivals.
      #
      # A loop left in the cartridge is written out in place, and the instruction that makes it
      # a loop is the branch back to the top. That runs once at the END of every pass that
      # finished, and never for the one in flight, so the arrivals ARE the passes finished. Its
      # first instruction cannot be used instead: for a loop that waits for the screen, that is
      # the instruction asking the console to sleep, and the console's own startup can enter
      # that one twice.
      def passes
        unless @count_passes
          raise ArgumentError, "This run did not count its passes. To count them, build the Verifier with " \
                               "`count_passes: true`."
        end
        ensure_rendered!
        return nil unless @passes_counted

        [@probe.arrivals - @pass_in_flight, 0].max
      end

      # THE SPRITES THE CONSOLE IS DRAWING, each knowing which one the game declared it for.
      #
      # One SpriteRow per sprite being drawn, off the console's own table — +name+, +x+, +y+,
      # +slot+, +tile+, +palette+, +color_count+, +colors+, +priority+, +shape+, +size+,
      # +mirrored_across+, +mirrored_down+, +turned+, +piece_x+, +piece_y+. Name one and only
      # that sprite's rows come back.
      #
      # +colors+ IS THE COLOURS IT IS WEARING, ready to compare against — no group number and no
      # arithmetic, and right for a picture stored either of the two ways (see #colors_drawn_from,
      # and +color_count+, which marks which way).
      #
      # +x+ AND +y+ ARE WHERE THE PICTURE STARTS — the corner of the canvas the art was drawn
      # on, which is where the game put the sprite. That is NOT the number the console carries,
      # and the difference is worth saying because it is invisible: a pose is stored trimmed to
      # what it actually draws and the sprite stands that much further along to compensate, and a
      # pose drawn backwards is trimmed from the other side and stands a different amount further
      # along again. So the console's own number is right for a sprite facing one way and out by
      # up to a canvas for the same sprite facing the other — which reads as the animation being
      # wrong rather than the position. The build did the moving, so it is undone here; +piece_x+
      # and +piece_y+ still carry what the console was told, for a test that wants that instead.
      # A row the build cannot name is left where it is, since there is nothing to look up.
      #
      # Worth having because the finished picture cannot answer several ordinary questions: it
      # cannot tell a hidden sprite from one drawn in the backdrop colour, from one behind a
      # background, or from one a pixel off the edge. A sprite the game has switched off is left
      # out, which is the answer a test wants.
      #
      # WHAT THE NAME SAVES is the guessing. The console's table holds which of its 128 places a
      # sprite is in and nothing else, so a test with a cast otherwise picks its hero by a place
      # number (which moves the day the game declares something earlier), by position (which
      # needs the game to keep its own position in a variable, and is a pixel or two out exactly
      # while the thing is moving), or by which colours it draws from (no use at all for a sprite
      # whose colours are being swapped). The build gave out the places and the cartridge carries
      # that, so the rows can name whose they are.
      #
      # A PICTURE TOO BIG for the console to draw in one go is several rows with the same name,
      # not one merged row: which piece is which is the framework's business, and a test asking
      # where something is wants all of it.
      #
      # Rows the build cannot name come back with a nil +name+ — a glyph of tiled text, say.
      #
      # @param name [Symbol, nil] keep only this declared sprite's rows; nil for every row
      # @return [Array<SpriteRow>]
      def sprites(name = nil)
        rows = named_sprite_rows
        return rows if name.nil?

        known = sprite_slots!
        unless known.key?(name)
          raise ArgumentError, "This game has no sprite #{name.inspect}. " \
                               "Its sprites are: #{known.keys.map(&:inspect).join(', ')}."
        end
        rows.select { |row| row.name == name }
      end

      # WHAT THE CONSOLE IS PLAYING, as values — one per sounding voice, in the order the
      # mixer holds them (see IR::Backends::GBA::Mixer::Voice for what each carries). Read off
      # the running console at the final frame boundary, so it is what the lowering really did
      # rather than what anything says it should have.
      #
      # Needs the cartridge to know where its voices are kept, which it does when it was
      # assembled with its build record. A program that plays no samples has no voices, and
      # this is empty for it.
      def voices
        table = voice_table!
        table ? table.read { |address| mem32(address) } : []
      end

      # Just the names of the samples sounding, in the mixer's order — directly comparable with
      # the interpreter's Reference#active_samples, which is what lets a test check the two
      # backends agree about sound with one equality.
      def sounding = voices.map(&:sample)

      # The sample clock this cartridge was built with — the rate the mix runs at and how many
      # samples that is a frame. A voice's step is a ratio against this rate, so anything asking
      # what pitch a voice is playing at needs it. Nil for a program that plays no samples.
      def sample_clock = voice_table!&.clock

      # WHAT THE CONSOLE COULD NOT PLAY: how many plays found every voice busy and were dropped,
      # and how the voices were being split at the worst of them. Counted since the cartridge
      # booted, so a test reads it at the end of a run. Directly comparable with the
      # interpreter's Reference#sound_drops — the same shape, so the two backends' answers meet
      # in one equality. Unmeasured for a program that plays no samples, which can lose none.
      def sound_drops
        refuse_missing_build_record!("where it counts the sounds it dropped")
        table = @rom.built.sound_drops
        table ? table.read { |address| mem32(address) } : SoundDrops::Reading.unmeasured
      end

      # WHICH SONG IS PLAYING NOW, by its name, or nil for none (Reference#music_playing): the
      # number the player is on (GBA::Audio::MUSIC_PLAYING) turned back into the tune it numbered,
      # as the frames played so far left it: a song the game named in the frame just played starts
      # at the player's next step, so is read from the frame after. A game that plays no tune keeps
      # no number, and plays none.
      def music_playing
        refuse_missing_build_record!("which songs it plays")
        playing = IR::Backends::GBA::Audio::MUSIC_PLAYING
        return nil unless @var_addresses&.key?(playing)

        number = raw_var(playing)
        number.zero? ? nil : IR::Backends::GBA::Audio.tunes_in_order(read_program).fetch(number - 1)
      end

      # HOW MANY TIMES A SPRITE WENT WITHOUT ITS COLOURS since the cartridge booted: drawn with a
      # list of its own (`draw_with`), it borrows a group of the console's colours for the frame,
      # and this counts each time every group was taken already, so it showed its own colours
      # instead. 0 for a game that draws no sprite with another list, which borrows none.
      def borrowed_colors_missed
        refuse_missing_build_record!("where it counts the colours it went without")
        address = @rom.built.colors_short_at
        address ? IR::Int32.wrap(mem32(address)) : 0
      end

      # --- the processor ---
      #
      # For debugging what the lowering emitted: stop the running cartridge at the first
      # instruction of a routine, then read what the processor holds there. The frames run
      # first, so the stop is the next time the routine is reached after them.

      # Run on until the routine named +routine+ is about to run its first instruction. The
      # name is the one the program gave it (`func(:count_up)`), or BuildRecord::FRAME_ROUTINE
      # for the game loop's own body. Raises when the routine is never reached, rather than
      # leaving the processor somewhere else to be read as if it were there.
      #
      # @return [self]
      def run_until(routine, limit: RUN_UNTIL_LIMIT)
        ensure_rendered!
        address = routine_start!(routine)
        @probe.run_until(address, limit: limit)
        self
      rescue RuntimeError
        # The emulator says which ADDRESS it failed to reach, which is the only thing it knows.
        # Only the build can turn that back into the name the program gave the routine, and the
        # name is the whole reason anybody asked for it here.
        raise RuntimeError, format("The routine %p (at 0x%08X) did not run within %d instructions.",
                                   routine, address, limit)
      end

      # What the processor holds right now: +:r0+ through +:r14+, +:pc+ (the instruction that
      # runs next) and +:cpsr+.
      def registers
        ensure_rendered!
        @probe.registers
      end

      # The pitch the wave voice is playing at, as the rate a game writes for it. Ask this rather
      # than reading the register back: the console makes those bits write-only, so {#mem16}
      # there reads 0 whatever note is playing. See Probe#wave_rate.
      def wave_rate
        ensure_rendered!
        @probe.wave_rate
      end

      # How many times the game read the pad while the console ran it — what the emulator saw,
      # which is not the same as how many passes a game loop made (see Probe#pad_reads).
      #
      # @return [Integer]
      def pad_reads
        ensure_rendered!
        @probe.pad_reads
      end

      private

      # WATCH FOR ARRIVALS AT THE GAME LOOP, before any frame runs, when the run counts passes. A
      # program with no game loop has no such routine, and that is an answer rather than an error
      # — see {#passes}.
      def watch_passes!
        return unless @count_passes

        refuse_missing_build_record!("where its game loop is, so its passes cannot be counted")
        span = @rom.built.routines[Cartridge::BuildRecord::FRAME_ROUTINE]
        return unless span

        # The start of the pass, or the end of it — see {#passes} for why each shape gets the
        # one it does, and what each means for the pass that is still running when we stop.
        kept_fast = @rom.built.frame_in_quick_memory?
        @pass_in_flight = kept_fast ? 1 : 0
        @probe.watch_arrivals(kept_fast ? span.begin : span.end)
        @passes_counted = true
      end

      # The cartridge's record of where it keeps its voices, or nil for a program that plays no
      # samples. A cartridge with no build record cannot answer.
      def voice_table!
        refuse_missing_build_record!("where it keeps its voices")
        @rom.built.voices
      end

      # Every row of the console's table, each with the name of the sprite the game declared it
      # for. Read once per call, so a test that steps the cartridge on sees where things moved to.
      def named_sprite_rows
        ensure_rendered!
        whose = sprite_slots!.each_with_object({}) do |(name, slots), by_slot|
          slots.each { |slot| by_slot[slot] = name }
        end
        moved = @rom.built.sprite_offsets
        rooms = @rom.built.streamed_sprite_pose_vars
        # A run drawn in an order the game works out moves its sprites' rows about, so a row is
        # taken back to the sprite's own place before anything is looked up by place.
        own = (@rom.built.sprite_runs || []).reduce({}) { |found, run| found.merge(run.own_places(method(:mem8))) }
        table = palette(:sprites) # read once for the lot, not once per row
        turns = @rom.built.sprite_turns || {}
        held = @rom.built.held_sprites
        @probe.sprites.map do |row|
          # A row of a game keeping more rows than the console's table is whichever of its own
          # rows was copied there this frame.
          slot = held ? held.row_in_copy(row[:slot], method(:mem16)) : row[:slot]
          home = own.fetch(slot, slot)
          name = whose[home]
          dx, dy = moved.dig(home, pose_key(row, rooms, home)) || [0, 0]
          # A place several scenes' sprites take turns at is the sprite of the scene the table
          # was last written for.
          if (turn = turns.fetch(home, []).find { |each_turn| var_at(each_turn.at) == each_turn.value })
            name = turn.name
            dx, dy = turn.offsets[turn_pose_key(row, turn)] || [0, 0]
          end
          # Back into the ranges the console keeps these in, so a sprite half off the left edge
          # reads the way its own place reads rather than going negative.
          SpriteRow.new(**row, name: name, piece_x: row[:x], piece_y: row[:y],
                        x: (row[:x] - dx) & 0x1FF, y: (row[:y] - dy) & 0xFF,
                        colors: colors_drawn_from(row, table))
        end
      end

      # THE COLOURS A ROW IS DRAWING FROM, which is the question the row's +palette+ field looks
      # like an answer to and is not.
      #
      # A picture is stored one of two ways, and the console picks by how many colours the art
      # uses: half a byte a pixel, picking out of a GROUP of sixteen colours, or a whole byte
      # picking out of all 256. +palette+ names the group, so it is the answer for the first kind
      # and means nothing for the second — and the two look identical from outside, which is why
      # handing over "the sixteen at that group" would be quietly wrong for a sprite drawn from
      # more than fifteen colours rather than obviously wrong.
      #
      # +color_count+ marks which kind, so this can simply take the right run: the group for a
      # picture that has one, and the whole table for a picture that draws from all of it.
      def colors_drawn_from(row, table)
        from = row[:color_count] == PALETTE.group ? row[:palette] * PALETTE.group : 0
        table[from, row[:color_count]]
      end

      # WHICH POSE A ROW IS HOLDING, given the way the build wrote that place's trims down (see
      # IR::Backends::GBA#pose_key, the other end of this).
      #
      # Nearly every sprite keeps all its pictures in sprite memory at once, and then the row tells
      # its own poses apart: the tiles it draws and whether it is drawn backwards differ for every
      # pose, so those two are the answer.
      #
      # A sprite with more pictures than fit keeps ONE of them there at a time, and then the row
      # cannot: every pose is copied into the same room, so it shows that one place whichever pose
      # is in it. The cartridge keeps the pose number in a variable of its own for exactly that
      # reason — it is how it knows whether the frame already in the room is still the right one —
      # and the build records where, so this reads it rather than guessing from a row that cannot
      # know. A room nothing has been copied into yet holds no pose at all, and no pose finds no
      # trim; a row being drawn always has one, because the frame goes in before the row is
      # written.
      def pose_key(row, rooms, home = row[:slot])
        address = rooms[home] or return [row[:tile], row[:mirrored_across], row[:mirrored_down]]

        var_at(address)
      end

      # ...the same, for a sprite taking its turn at a place (see BuildRecord#sprite_turns),
      # which itself records where its pose is kept when it keeps one frame at a time.
      def turn_pose_key(row, turn)
        return [row[:tile], row[:mirrored_across], row[:mirrored_down]] if turn.pose_var.nil?

        var_at(turn.pose_var)
      end

      # Which places the build gave each declared sprite. A cartridge with no build record
      # cannot know.
      def sprite_slots!
        refuse_missing_build_record!("which of its sprites is which")
        @rom.built.sprite_slots
      end

      # Where a routine's first instruction really is while the cartridge runs — which is not
      # where it sits in the cartridge when it was copied into the console's quick memory, so
      # only the build record holds it.
      def routine_start!(routine)
        refuse_missing_build_record!("where its routines are")
        span = @rom.built.routines[routine] or
          raise ArgumentError, "This ROM has no routine #{routine.inspect}. " \
                               "Its routines are: #{@rom.built.routines.keys.map(&:inspect).join(', ')}."
        span.begin
      end
    end
  end
end
