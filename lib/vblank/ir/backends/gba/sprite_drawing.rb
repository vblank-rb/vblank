# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # The code that puts sprites on a tiled screen. The console draws sprites itself,
        # every frame, out of a table of 128 rows it keeps in its own memory: each row holds
        # where a sprite stands, which of the pictures in sprite memory it shows, and how.
        # So drawing a sprite here means writing its row — once for one that never moves,
        # every frame for one that does — and, for a sprite whose pictures do not all fit,
        # copying the frame it is showing into its room first.
        #
        # Where each sprite's pictures and rows are was settled before any code existed
        # (see {ScreenLayout}); this reads that plan and writes the code that carries it out.
        class SpriteDrawing
          # The statements this part writes (Lowering#statements_written_by), each by its own method.
          STATEMENT_KINDS = %i[color_list_holds present_objects hide_sprites].freeze

          def emit_statement(node)
            case node.kind
            when :color_list_holds then emit_color_list_holds(node)
            when :present_objects then emit_present_objects(node)
            when :hide_sprites then emit_hide_sprites(node)
            else raise LoweringError, "no writer here for #{node.kind.inspect}"
            end
          end

          include Console::Hardware

          def initialize(emitter:, primitives:, lowering:, divide:, framebuffer:, palette_tint:, uploads:,
                         placement:, raster:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @divide = divide
            @framebuffer = framebuffer
            @raster = raster
            @palette_tint = palette_tint
            @uploads = uploads
            @placement = placement
            @layout = nil
            @picture_group_copying = nil
          end

          attr_writer :layout, :picture_group_copying, :scene_entry

          def placed_fade = @layout.screen.placed_fade

          # Where a sprite's tiles live: the object tile area of video memory, and the
          # sprite table itself. In tile mode the console draws sprites from tiles kept
          # in this region, separate from the background's, so the two never collide.
          OBJ_TILE_BASE = VRAM_START + 0x10000 # Object tiles start 64KB into video memory
          OBJ_HIDDEN_ATTR0 = 0x0200            # attr0 marking a sprite-table slot unused
          OBJ_HIDDEN_WORD  = 0x02000200        # Two hidden attr0s, for a fast table clear

          # A turning sprite sets two more attr0 bits. Rotate/scale (bit 8) tells the
          # console to draw this sprite through an affine parameter group instead of
          # straight. Double-size (bit 9) draws it in a box twice as wide and tall so a
          # rotated corner has room and never clips — we place the box so the sprite
          # stays centered where an upright one would sit. (With rotate/scale off, this
          # same bit 9 is the "hidden" marker above, which is why hiding still works.)
          OBJ_ROTSCALE     = 0x0100
          OBJ_DOUBLE_SIZE  = 0x0200

          # How far off the screen a sprite can stand and still be where the game put it.
          #
          # A row of the table keeps a sprite's row as one of 256 and its column as one of
          # 512, and a place outside those is kept as a place inside them: row 300 is kept as
          # row 44, so a sprite a game parked below the screen is drawn across the middle of
          # it. The screen is 160 of the 256 rows, which leaves 96 for a sprite standing above
          # it, and 240 of the 512 columns, which leaves 272 for one to its left. So a box is
          # drawn where the game put it while its top is no more than 96 rows above the
          # screen and its bottom is short of the last row counted, and the same across
          # with 272 columns and the last column. Anywhere else the table would draw it
          # somewhere the game never meant, so it is moved to the first row below the screen
          # or the first column right of it, where none of it shows (see
          # #emit_move_far_place_off_screen).
          ROWS_KEPT = 256
          COLUMNS_KEPT = 512
          ROWS_KEPT_ABOVE = ROWS_KEPT - SCREEN_HEIGHT
          COLUMNS_KEPT_LEFT = COLUMNS_KEPT - SCREEN_WIDTH

          # The largest box the console draws a sprite in, each way: any sprite that stands
          # upright, and each piece of a picture drawn as several. One that turns or resizes
          # is drawn in a box twice its own size, so the largest of those is twice this.
          LARGEST_BOX = 64

          # The rows a box as tall as the largest is drawn at as the game put them, and the
          # columns: for the box of a sprite that stands upright, and for the wider one of a
          # sprite that turns.
          ROWS_DRAWN_AS_PUT = (-ROWS_KEPT_ABOVE...(ROWS_KEPT - LARGEST_BOX))
          COLUMNS_DRAWN_AS_PUT = (-COLUMNS_KEPT_LEFT...(COLUMNS_KEPT - LARGEST_BOX))
          TURNED_COLUMNS_DRAWN_AS_PUT = (-COLUMNS_KEPT_LEFT...(COLUMNS_KEPT - (LARGEST_BOX * 2)))

          # The tallest box that stands unseen at the first row below the screen: as many
          # rows as are counted past the bottom edge. The one box taller is a turning
          # sprite's, 64 pixels tall and so drawn in 128 rows (see #emit_tall_box_attr0).
          TALLEST_BOX_UNSEEN_BELOW = ROWS_KEPT_ABOVE

          # Where one over a resizing sprite's size is parked between the divide that
          # works it out and the multiplies that use it (see #emit_object_scale_reciprocal).
          # One variable serves every sprite, because each is done with before the next
          # one starts.
          OBJ_SCALE_RECIP = :_obj_scale_recip

          # One-time sprite setup at boot: blank the whole sprite table (its memory is
          # garbage at power-on, so an untouched slot would show a stray sprite), upload
          # the one shared color table every sprite indexes into, then each sprite's
          # tiles into video memory. After this the per-frame draw just points slots at
          # these tiles.
          def emit_boot_objects
            clear_object_table
            @layout.border&.emit_put_up # the border round a smaller screen, in the table's first rows
            # A game in a border with no sprites of its own has nothing more to send.
            return if @layout.screen.obj_palette_blob.nil?

            # The table has just been wiped, so the sprites nobody moves are gone from it too
            # and have to be written again. This runs on a change of screen as well as at
            # boot, which is the case that would otherwise leave a title screen blank.
            emit_mark_still_sprites_unwritten
            @uploads.emit_dma_blob(@layout.screen.obj_palette_blob, OBJ_PALETTE, @layout.screen.obj_palette_units) # the shared sprite palette, once
            @palette_tint.emit_record_obj_palette_source(@layout.screen.obj_palette_blob) # ...which is the one a tint walks until a scene sends its own
            emit_no_scene_colors_sent # ...so the scene taking over sends its own as it arrives
            @layout.screen.objects.each_value do |obj|
              # A sprite showing the same pictures as one already uploaded points at
              # those, so there is nothing of its own to send. A sprite that belongs to a
              # scene is sent when that scene takes over, not here (see
              # Drawing#emit_scene_art_upload), since scenes share the room above this.
              next if obj.tiles.nil? || obj.scene

              @uploads.emit_dma_blob(obj.tiles, OBJ_TILE_BASE + (obj.tile_index * 32), obj.tile_units * 16) # tiles -> sprite memory
            end
            emit_reset_resident_frames(@layout.screen.objects.each_value)
            # ...and no group's pictures are in sprite memory, so the groups the game set as up
            # are copied in again before the sprites are next written.
            @picture_group_copying.emit_forget_every_set_up
            emit_boot_object_windows
            @palette_tint.emit_tint_reset_if_tinting # the table now holds the originals again
          end

          # Set up the object window, once, for a program that keeps sprites out of a
          # fade. Outside it every layer shows and the color effect applies; inside it
          # every layer still shows and the effect does not. The region itself is the
          # shape of whatever the twin sprites paint, so nothing here mentions a place on
          # screen. EFFECT_LINE starts past the front of the stack: until a fade is
          # placed, no twin shows.
          #
          # In a game with a light the light sets the register as it switches, since a light that
          # is on reaches the kept sprites too (Raster#emit_light_window_shut).
          def emit_boot_object_windows
            return if placed_fade.none?

            @emitter.write_reg16(REG_WINOUT, WIN_ALL_LAYERS | WIN_EFFECT | (WIN_ALL_LAYERS << WINOUT_OBJ_SHIFT)) unless @raster.feeds_light?
            @primitives.store_word_immediate(placed_fade.fade_stack_index, @primitives.var_addr(EFFECT_LINE))
          end

          # Fill the sprite table with the "unused slot" marker so no leftover memory
          # shows as a sprite. One source-fixed DMA of a word that is two hidden slots.
          def clear_object_table
            scratch = @primitives.var_addr(:_oam_clear)
            @primitives.store_word_immediate(OBJ_HIDDEN_WORD, scratch)
            @primitives.emit_start_copy_engine(from: scratch, to: OAM_START, control: @framebuffer.dma_fill_control(OAM_SIZE / 4))
            emit_clear_draw_run_copies
            emit_clear_held_table
          end

          # The routine that writes the sprites nothing moves, and the two things remembered
          # about it: whether those sprites are in the console's table at all, and what the
          # variable that decides them held when they were put there.
          #
          # Two words and not one, which looks like one too many and is not. A single word
          # holding "the value we last wrote for" needs some reading of it to mean "nothing
          # written yet", and every value a word can hold is one a program is free to number a
          # scene with — a game whose first state is -1 would then find the table already
          # right at power-on and leave its title screen blank for ever, with nothing in the
          # program to point at. The separate yes-or-no cannot be confused with a scene, and
          # costs one load and one compare on a frame.
          STILL_ROUTINE = Messages::MadeNames.make(:still_sprites)
          STILL_UP = :__still_up
          STILL_STATE = :__still_state

          # What is remembered in a program with no scenes, which has no variable to watch
          # because nothing at all can change once its sprites are up.
          NOTHING_TO_WATCH = 0

          # A list of sprite colours holds another set: put that set into the group of sixteen
          # the sprites drawn with the list read.
          #
          # Not a sprite is touched. A sprite's row names which group its pixels pick their
          # colours from, and every sprite drawn with this list names the same one — so
          # changing the sixteen entries there changes all of them at once, and costs the same
          # however many there are. That is what lets one group dress a goblin in one room and
          # a bat in the next: the group is a slot, and this fills it.
          #
          # Why the group is the list's own: the write lands in the table, where anything else
          # reading those sixteen would change colour too (see
          # ScreenLayout#changing_list_pictures).
          #
          # WHEN it happens is decided above this: the framework puts the copy in the gap
          # between frames, which is where the sprites' rows are written too, on the frame the
          # answer changed and no other (see Builder::ColorLists).
          #
          # A number naming none of the sets hands over the colours the list was declared
          # with, which sit last in the blob — so that case is a conditional move rather than a
          # branch. Where the set starts is remembered as well as written, because a tint, a
          # scene taking over and a change of screen all put the declared colours back in this
          # group, and each then reads this to put the set in force back (see
          # PaletteTint#emit_recolored_obj_banks).
          #
          # A background drawn with several lists the game changes follows this write too: the same
          # set goes into the group of background colours its tiles drawn from this list read (see
          # ScreenLayout::FollowedColors), so the tiles change on the frame the sprites do.
          def emit_color_list_holds(node)
            @palette_tint.emit_backdrop_held(node) # the backdrop, where it follows this list
            list = @layout.screen.color_lists[node.name]
            followed = @layout.screen.followed_colors[node.name]
            sets = list || followed
            return if sets.nil? # no sprite on a tiled screen draws with it, and no background follows it

            @lowering.value(node.which)
            # One unsigned compare catches both ends: a negative number reads as a very large
            # one, so anything outside 0...count fails the same test.
            @emitter.emit_number(TMP, sets.count)
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit(ASM.mov_reg_cond(:hs, ACC, TMP))
            @emitter.emit(ASM.lsl_imm(TMP, ACC, COLOR_SET_SHIFT))
            @emitter.emit_load_data_address(ACC, sets.blob)
            @emitter.emit(ASM.add_reg(ACC, ACC, TMP))
            @primitives.store_var(ACC, sets.source_var)
            @palette_tint.emit_changed_list_colors(list) if list
            @palette_tint.emit_followed_list_colors(followed) if followed
          end

          # A set is sixteen colours of two bytes each, so the set numbered N starts 32 * N
          # along the blob.
          COLOR_SET_SHIFT = 5

          # Draw this frame's sprites: write each named object's current position and
          # visibility into its slot in the sprite table. Runs right after the vblank
          # (when changing the table is safe), so a moving sprite lands at its new spot
          # with no tearing. A game playing recorded sound keeps that: its mixing waits for
          # the display to start the next picture, so it never takes the gap from this. The console composites the sprites over the background for
          # free — there's nothing to erase, unlike a software sprite.
          #
          # The table first, the groups' pictures after. The groups the game set as up are brought
          # in last (see PictureGroupCopying), so a sprite showing one of their pictures draws it on
          # the frame it first shows it, as long as the copy ends inside the gap. The table has to
          # be written while nothing is drawn: the display reads a sprite's row of it as it draws
          # each line (GBATEK, LCD OBJ - OAM Attributes). A group's pictures are a big copy, and
          # copied first, one longer than what is left of the gap would push the table's writes
          # down into the picture, tearing a row of sprites part way down it.
          def emit_present_objects(node)
            by_scene = @layout.scene_sprites
            emit_switch_sprite_layer
            emit_unless_set_just_came_in do
              @scene_entry.emit_unless_scene_is_loading do
                emit_scene_colors_on_change # before any row is written
                emit_count_lending_frame
                emit_hide_scene_rows_on_change
                emit_write_sprite_rows(node.names - @layout.movement.still - by_scene.flat_map(&:names))
                by_scene.each { |group| emit_scene_sprites(group) }
                emit_refresh_still_sprites
                @layout.draw_runs.each { |run| emit_copy_draw_run(run) }
                emit_game_rows_copied_in
                @picture_group_copying.emit_calls_to_routines
              end
            end
            # The sprite table is written, and the mix need wait no longer (see
            # Mixer::GAP_WRITES_RUNNING).
            @placement.emit_gap_writes_ended
          end

          # Bringing an area's tiles in is the longest thing a frame ever does, and it comes just
          # before the frame's sprite work, in the same gap. So the sprite work waits a frame: the
          # sprites stay as they stood while the area arrives, and the frame after writes the same
          # numbers. A game whose frames only just hold that copy is then well inside them, and how
          # many sprites it sorts cannot push the pass over. A game that stays in one area emits
          # nothing here.
          def emit_unless_set_just_came_in
            return yield unless @layout.screen.walks_areas?

            came_in = BackgroundDrawing::SET_CAME_IN
            work = @emitter.gensym
            past = @emitter.gensym
            @primitives.load_var(ACC, came_in)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, work, cond: :eq)
            @emitter.emit_number(ACC, 0)
            @primitives.store_var(ACC, came_in)
            @emitter.emit_branch(:b, past)
            @emitter.place_label(work)
            yield
            @emitter.place_label(past)
          end

          # Every sprite off for a frame (see Builder::Sprites#hide_sprites).
          #
          # The console draws its sprites as a layer of their own over the backgrounds, and one
          # bit of its display-control register sets whether that layer is drawn at all. With it
          # off nothing of any sprite shows, and the table of rows and the pictures stay exactly
          # as they are, so turning it on again a frame later shows every sprite where it would
          # have been.
          #
          # `hide_sprites` only notes that it was asked. The bit is changed here, between frames,
          # where nothing is being drawn: changed while the pass runs, it would take the sprites
          # off the lower part of the frame being drawn then. The note is one of three:
          SPRITES_HIDDEN = :_sprites_hidden
          SPRITES_SHOWN = 0 # The layer is on, and nothing asked
          SPRITES_ASKED = 1 # The pass just run asked for a frame without them
          SPRITES_OFF = 2   # The layer is off for this frame, and comes on again at the next gap

          # Whether the game ever asks, so that a game that never does emits nothing for it.
          attr_writer :hides_sprites

          def hides_sprites? = @hides_sprites && @layout.has_objects

          # `hide_sprites`: note it, for the gap after this pass.
          def emit_hide_sprites(_node)
            @primitives.store_word_immediate(SPRITES_ASKED, @primitives.var_addr(SPRITES_HIDDEN)) if hides_sprites?
          end

          # At power-on the layer is on, whatever the memory held.
          def emit_sprites_shown_at_power_on
            @primitives.store_word_immediate(SPRITES_SHOWN, @primitives.var_addr(SPRITES_HIDDEN)) if hides_sprites?
          end

          # Between frames: the layer off for a frame that was asked for, and on again the gap
          # after. Turning it on is only for a screen drawn from tiles. A bitmap screen paints
          # its sprites into the picture and keeps that bit clear, and a game can go to one on
          # the pass after asking. The low three bits of the register hold which kind is up, and
          # tiled screens are the kinds below 3. A frame asked for while the layer is already
          # off keeps it off. On a frame nobody asked, this costs a load, two compares and two
          # branches.
          #
          # In a border the layer stays on, since the border is sprites too (BorderSprites). There
          # only the note moves on, and the copy into the console's table, which comes later in this
          # gap, copies none of the game's rows on a frame the note says is off
          # (#emit_held_table_copy_routine): every row of the game's is hidden for that frame, and
          # the frame after copies them all again.
          def emit_switch_sprite_layer
            return unless hides_sprites?

            done = @emitter.gensym
            turn_on = @emitter.gensym
            layer_switched = @layout.border.nil?
            @primitives.load_var(ACC, SPRITES_HIDDEN)
            @emitter.emit(ASM.cmp_imm(ACC, SPRITES_ASKED))
            @emitter.emit_branch(:bcond, turn_on, cond: :ne)
            @primitives.store_word_immediate(SPRITES_OFF, @primitives.var_addr(SPRITES_HIDDEN))
            if layer_switched
              changing_display_control do
                @emitter.emit_number(TMP, REG_DISPCNT)
                @emitter.emit(ASM.load_halfword(ACC, TMP))
                @emitter.emit(ASM.bic_imm(ACC, ACC, OBJ_ENABLE))
                @emitter.emit(ASM.store_halfword(ACC, TMP))
              end
            end
            @emitter.emit_branch(:b, done)
            @emitter.place_label(turn_on)
            @emitter.emit(ASM.cmp_imm(ACC, SPRITES_OFF))
            @emitter.emit_branch(:bcond, done, cond: :ne)
            @primitives.store_word_immediate(SPRITES_SHOWN, @primitives.var_addr(SPRITES_HIDDEN))
            return @emitter.place_label(done) unless layer_switched

            changing_display_control do
              bitmap = @emitter.gensym
              @emitter.emit_number(TMP, REG_DISPCNT)
              @emitter.emit(ASM.load_halfword(ACC, TMP))
              @emitter.emit(ASM.and_imm(2, ACC, 7))
              @emitter.emit(ASM.cmp_imm(2, 3))
              @emitter.emit_branch(:bcond, bitmap, cond: :hs) # a bitmap screen
              @emitter.emit(ASM.orr_imm(ACC, ACC, OBJ_ENABLE))
              @emitter.emit(ASM.store_halfword(ACC, TMP))
              @emitter.place_label(bitmap)
            end
            @emitter.place_label(done)
          end

          # A read and write of the display's settings, in a game where the screen's interrupt
          # can switch held layers on (BackgroundDrawing::LAYERS_HELD): with the interrupt switch
          # off between them, or the write would put back the settings read before the interrupt
          # and switch the held layers off for good. Elsewhere as it is.
          def changing_display_control(&)
            return yield unless @layout.holds_layers?

            @primitives.with_interrupts_held_off(&)
          end

          # A screen's whole set of layers, written to the display. Where a game's screens use
          # layers of their own, the screen in play writes all of them every pass, the sprite
          # layer among them — and that write lands after the gap that switched the sprite layer
          # off for a frame, so on its own it would put the sprites straight back. So in a game
          # that calls `hide_sprites`, the sprite layer is left out of the write on the frame it is
          # off for. A game that never calls it writes the value as it is, and so does a game in a
          # border, whose sprite layer stays on (#emit_switch_sprite_layer).
          #
          # A block, where given, is handed the register holding the value and writes it to the
          # display itself: with the layers held off for the rest of a picture
          # (BackgroundDrawing#emit_display_control_keeping_held_off).
          def emit_screen_layers(value, &writes_it)
            hiding = hides_sprites? && value.anybits?(OBJ_ENABLE) && @layout.border.nil?
            return @emitter.write_reg16(REG_DISPCNT, value) unless hiding || writes_it

            @emitter.emit_number(ACC, value)
            if hiding
              write = @emitter.gensym
              @primitives.load_var(TMP, SPRITES_HIDDEN)
              @emitter.emit(ASM.cmp_imm(TMP, SPRITES_OFF))
              @emitter.emit_branch(:bcond, write, cond: :ne)
              @emitter.emit(ASM.bic_imm(ACC, ACC, OBJ_ENABLE))
              @emitter.place_label(write)
            end
            return writes_it.call(ACC) if writes_it

            @emitter.emit_number(TMP, REG_DISPCNT)
            @emitter.emit(ASM.store_halfword(ACC, TMP))
          end

          # A run of the table drawn in an order the game works out (see Builder#draw_in_order).
          #
          # The console decides which of two sprites is in front by where their rows sit in its
          # table — the lower row in front — and a row's place was fixed when the cartridge was
          # built. So the sprites of such a run do not write their rows into the table at all.
          # They write them into a copy of the run kept in work memory, laid out exactly as the
          # table would have it, every way they always did; and before each frame is drawn the
          # run is copied into the table in the order the program sorted it into.
          #
          # Why a copy rather than writing each sprite straight to its new row: a sprite's row is
          # not always written. One that never moves is written once, one whose scene is not up
          # is not written at all — and they are right because a row stays as it was last
          # written. The copy keeps that true: every row stays where its own sprite put it, and
          # only the copy into the table moves.
          #
          # Only the first three of a row's four halves are copied. The fourth belongs to the
          # table's groups for turning sprites, which are counted by place, not by sprite.
          #
          # +first_slot+ and +slots+ are the run's rows in the table; +staging+ is where the copy
          # of them is kept; +order+ is where the program keeps its list of the run's sprites in
          # the order to draw them, back to front, a byte each counting from 0; and +table+ is a
          # cartridge table of two bytes a sprite — its first row, counted from the run's
          # first, and how many rows it takes.
          #
          # A run's rows are its own, never taken in turns with another scene's sprites (see
          # IR::SpriteRows): a sprite of another scene in one of them would be written into the
          # copy, and the copy is the run's.
          # +entry_bytes+ is how wide one entry of that list is: a byte, or a half for a run of more
          # than 128 sprites (Builder::DrawOrder#declare_order_lists). +shown+ is where its sort keeps
          # how many entries at the list's front are not showing (ShownSort::Kept), or nil.
          DrawRun = Data.define(:first_slot, :slots, :staging, :order, :entry_bytes, :members, :table, :shown) do
            def holds?(slot) = slot >= first_slot && slot < first_slot + slots
            def staged(slot) = staging + ((slot - first_slot) * 8)
          end

          # Each ordered run of +program+'s frame, with its copy given a place in +memory+ and
          # its table put in +blobs+; +lists+ gives where the program keeps each list.
          #
          # The copy reads the list from its first slot, one entry a sprite, with nothing tested, so it
          # takes only the builder's own list (Build::DrawOrder#permutation), which holds every place
          # of the run there. A list written by hand, or one something takes items from the front of
          # (whose first item moves along its slots), is refused: the interpreter reads such a list as
          # it holds (Reference#names_in_draw_order), and this copy does not.
          def self.plan_draw_runs(program, objects:, memory:, blobs:, lists:, shown_sorts: {})
            present = program.walk.find { |node| node.kind == :present_objects } or return []
            dropped = program.walk.filter_map { |node| node.name if node.kind == :list_drop && node.from == :front }
            (present.orders || []).each_with_index.map do |run, k|
              unless DrawOrderWalk.read_by_slots?(run, dropped)
                raise LoweringError, "the list #{run.order.inspect} orders sprites, and the game writes it or takes " \
                                     "items from its front. The Game Boy Advance cartridge draws an order only from " \
                                     "the list that draw_in_order keeps."
              end

              sprites = run.objects.map { |name| objects.fetch(name) }
              first = sprites.map(&:slot).min
              slots = sprites.sum(&:pieces)
              unless sprites.flat_map { |sprite| (sprite.slot...(sprite.slot + sprite.pieces)).to_a }.sort == (first...(first + slots)).to_a
                raise LoweringError, "the sprites of a draw_in_order are not side by side in the sprite table"
              end

              table = :"__draw_run_#{k}"
              blobs[table] = sprites.flat_map { |sprite| [sprite.slot - first, sprite.pieces] }.pack("C*")
              order = lists.list_info(run.order)
              DrawRun.new(first_slot: first, slots: slots, staging: memory.alloc(slots * 8),
                          order: order.base, entry_bytes: order.bytes, members: sprites.length, table: table,
                          shown: shown_sorts[run.order])
            end
          end

          # Where a sprite's row +piece+ is written: its place in the table, or in the copy of
          # its run when it is in one.
          def row_address(first, piece)
            slot = first + piece
            run = @layout.draw_runs.find { |each_run| each_run.holds?(slot) }
            run ? run.staged(slot) : oam_slot(first, piece)
          end

          # Copy one run into the table in its order. The program's list holds the sprites back
          # to front, and the table's front is its first row, so the list is read from its end
          # while the table is written from the run's first row onward.
          #
          #   r1  the list, from its last entry back
          #   r12 one before the list's first entry, where the walk stops
          #   r2  the table row being written
          #   r3  the copy being read
          #   r4  rows left of this sprite
          #
          # A run sorted with what shows (ShownSort) keeps its entries not showing at the list's front,
          # so the copy stops at them, and a run of many declared and a few showing copies the few. The
          # rows past the last one written then hold whatever the pass before wrote there, so the ones
          # it wrote past where this pass stopped are hidden (#emit_rows_past_run_hidden).
          def emit_copy_draw_run(run)
            list = run.order
            next_sprite = @emitter.gensym
            next_row = @emitter.gensym
            copied = @emitter.gensym
            entry = run.entry_bytes
            @emitter.emit_number(TMP, list + ((run.members - 1) * entry))
            @emitter.emit_number(ADDR, list - entry)
            if run.shown
              @emitter.emit_number(ACC, run.shown.block)
              @emitter.emit(ASM.ldr_offset(ACC, ACC, ShownSort::HIDDEN))
              @emitter.emit(ASM.lsl_imm(ACC, ACC, 1)) if entry == 2
              @emitter.emit(ASM.add_reg(ADDR, ADDR, ACC))
            end
            @emitter.emit_number(SPARE, oam_slot(run.first_slot, 0))
            if run.shown
              @emitter.emit(ASM.cmp_reg(TMP, ADDR))
              @emitter.emit_branch(:bcond, copied, cond: :eq)
            end
            @emitter.place_label(next_sprite)
            if entry == 2                                 # which sprite goes next
              @emitter.emit(ASM.load_halfword(ACC, TMP))
            else
              @emitter.emit(ASM.ldrb_offset(ACC, TMP, 0))
            end
            @emitter.emit(ASM.sub_imm(TMP, TMP, entry))
            @emitter.emit_load_data_address(POSE_WORD, run.table)
            @emitter.emit(ASM.add_reg(POSE_WORD, POSE_WORD, ACC))
            @emitter.emit(ASM.add_reg(POSE_WORD, POSE_WORD, ACC))  # ...its two bytes in the table
            @emitter.emit(ASM.ldrb_offset(HIGH, POSE_WORD, 0))     # its first row in the copy
            @emitter.emit(ASM.ldrb_offset(POSE_WORD, POSE_WORD, 1)) # how many rows it takes
            @emitter.emit(ASM.lsl_imm(HIGH, HIGH, 3))
            @emitter.emit_number(ACC, run.staging)
            @emitter.emit(ASM.add_reg(HIGH, HIGH, ACC))
            @emitter.place_label(next_row)
            [0, 2, 4].each do |half|
              @emitter.emit(ASM.load_halfword_offset(ACC, HIGH, half))
              @emitter.emit(ASM.store_halfword_offset(ACC, SPARE, half))
            end
            @emitter.emit(ASM.add_imm(HIGH, HIGH, 8))
            @emitter.emit(ASM.add_imm(SPARE, SPARE, 8))
            @emitter.emit(ASM.subs_imm(POSE_WORD, POSE_WORD, 1))
            @emitter.emit_branch(:bcond, next_row, cond: :ne)
            @emitter.emit(ASM.cmp_reg(TMP, ADDR))
            @emitter.emit_branch(:bcond, next_sprite, cond: :ne)
            @emitter.place_label(copied)
            emit_rows_past_run_hidden(run) if run.shown
          end

          # The rows the pass before wrote past where this pass's copy stopped (in SPARE), each given
          # the "unused slot" marker, and where this pass stopped kept for the next.
          def emit_rows_past_run_hidden(run)
            blank = @emitter.gensym
            done = @emitter.gensym
            @emitter.emit_number(TMP, run.shown.block)
            @emitter.emit(ASM.ldr_offset(HIGH, TMP, ShownSort::ROWS_END))
            @emitter.emit(ASM.str_offset(SPARE, TMP, ShownSort::ROWS_END))
            @emitter.emit_number(ACC, OBJ_HIDDEN_WORD & 0xFFFF)
            @emitter.place_label(blank)
            @emitter.emit(ASM.cmp_reg(SPARE, HIGH))
            @emitter.emit_branch(:bcond, done, cond: :hs)
            @emitter.emit(ASM.store_halfword_offset(ACC, SPARE, 0))
            @emitter.emit(ASM.add_imm(SPARE, SPARE, 8))
            @emitter.emit_branch(:b, blank)
            @emitter.place_label(done)
          end

          # Fill the copy of every ordered run with the "unused slot" marker, for the same
          # reason the table itself is cleared: a row nothing has written yet would show.
          # The marker is already in the scratch word the table's own clear left it in.
          def emit_clear_draw_run_copies
            @layout.draw_runs.each do |run|
              @primitives.emit_start_copy_engine(from: @primitives.var_addr(:_oam_clear), to: run.staging,
                                     control: @framebuffer.dma_fill_control(run.slots * 2))
            end
          end

          # More rows than the console's table holds.
          #
          # The console draws its sprites from 128 rows, and every sprite is given a row while the
          # cartridge is built — a pool one for every thing it can hold, so three pools of sixty
          # need 180 although a room shows a handful. A game with more than 128 keeps all of them
          # in a bigger copy of the table, in the roomy memory, and every sprite writes its row
          # there exactly as it would have written the console's. Before each frame the rows that
          # show something are copied into the console's table one after another, front to back
          # (see #emit_held_table_copy_routine): so what has to fit in 128 is one frame's sprites, as
          # in the console's own games, which build their table each frame from what they draw.
          #
          # The order holds. The console puts a lower row in front, and the copy keeps every row
          # in the order the build gave it, only closing up the gaps the hidden ones leave.
          #
          # More showing than 128: the frontmost 128 are drawn, and the rest are left out for that
          # frame and counted (LEFT_OUT, which a profile reports). Every other backend draws them
          # all — it has no table to run out of.
          #
          # +rows+ is how many rows the build handed out, +copy+ where the bigger table is, and
          # +came_from+ a half a console row holding which row of the copy is in it this frame, so
          # a reader of the running cartridge can say whose sprite each one is.
          HeldTable = Data.define(:rows, :copy, :came_from) do
            def row_address(slot) = copy + (slot * 8)
          end

          HELD_TABLE_ROUTINE = Messages::MadeNames.make(:held_sprite_table)
          # How far into the console's table the last frame's copy reached, so the rows past this
          # frame's are hidden only as far as there was anything to hide.
          HELD_SHOWN_TO = :__held_sprites_shown_to
          # How many rows were left out because the console's table was full, since power-on.
          LEFT_OUT = :__sprites_left_out

          # The bigger table for +rows+ rows, or nil when they fit in the console's own. +allocator+
          # claims roomy memory, given how much and what for (GBA#alloc_sprite_record!).
          #
          # +moved+ marks that every sprite stands somewhere else on the console's screen than the game put
          # it, a smaller screen shown in the middle of this one (BorderSprites): then every game has
          # the copy, however few rows it needs, since copying is where each place is moved, and
          # the console's table is written by nothing else.
          def self.plan_held_table(rows, allocator:, moved: false)
            return nil if rows.zero?
            return nil if rows <= MAX_SPRITES && !moved

            HeldTable.new(rows: rows,
                          copy: allocator.alloc_sprite_record!(rows * 8, "where more sprites than the console draws are kept"),
                          came_from: allocator.alloc_sprite_record!(MAX_SPRITES * 2,
                                                                    "which sprite each row of the console's table is"))
          end

          # Every row of the copy hidden whenever the console's own table is cleared: at power-on,
          # and on coming back to a screen that draws sprites.
          def emit_clear_held_table
            held = @layout.held_sprites or return

            @primitives.emit_start_copy_engine(from: @primitives.var_addr(:_oam_clear), to: held.copy,
                                   control: @framebuffer.dma_fill_control(held.rows * 2))
            @primitives.store_word_immediate(OAM_START + OAM_SIZE, @primitives.var_addr(HELD_SHOWN_TO))
          end

          # ...and nothing left out yet, at power-on only: the count runs from there.
          def emit_held_table_at_power_on
            @primitives.store_word_immediate(0, @primitives.var_addr(LEFT_OUT)) if @layout.held_sprites
          end

          def emit_call_held_table_copy
            @placement.emit_call_cold_routine(HELD_TABLE_ROUTINE) if @layout.held_sprites
          end

          # Set while the game's rows of the console's table are hidden for a sending in a border
          # (#emit_hide_game_rows), until a copy writes them again.
          GAME_ROWS_HIDDEN = :_game_rows_hidden

          # Does this game hide its rows for a sending? A game in a border that holds its layers
          # and has scenes with sprite pictures of their own.
          def hides_game_rows? = !@layout.border.nil? && @layout.holds_layers? && @layout.screen.scene_art?

          # The game's rows copied in again, and the note of them hidden cleared.
          def emit_game_rows_copied_in
            emit_call_held_table_copy
            return unless hides_game_rows?

            @emitter.emit_number(ACC, 0)
            @primitives.store_var(ACC, GAME_ROWS_HIDDEN)
          end

          # Where the game stops, the game's rows copied in again if a sending left them hidden: no
          # pass after the stop copies them, and the screen's interrupt never writes the console's
          # table in a border. With +wait+ the copy waits for the gap first, so the picture the
          # sending ran into stays whole; without, the caller has waited already.
          def emit_game_rows_back_at_stop(wait:)
            return unless hides_game_rows?

            past = @emitter.gensym
            @primitives.load_var(ACC, GAME_ROWS_HIDDEN)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, past, cond: :eq)
            @emitter.emit(ASM.swi(GBA::SWI_VBLANK_INTR_WAIT << 16)) if wait
            emit_game_rows_copied_in
            @emitter.place_label(past)
          end

          # The game's rows of the console's table hidden, as far as the last copy reached, leaving
          # the border's rows before them up (BorderSprites). For a sending in a border, which
          # cannot switch the sprites off without the border (Drawing#emit_with_layers_held_for_art):
          # each row is the "hidden" marker in its first half (GBATEK, OBJ Attribute 0: bit 9 set
          # with bit 8 clear), and the copy into the table writes them all again (#emit_call_held_table_copy).
          # Uses ACC, TMP and ADDR.
          def emit_hide_game_rows
            loop_top = @emitter.gensym
            done = @emitter.gensym
            @emitter.emit_number(ACC, 1)
            @primitives.store_var(ACC, GAME_ROWS_HIDDEN)
            @primitives.load_var(TMP, HELD_SHOWN_TO)
            @emitter.emit_number(ADDR, first_game_row)
            @emitter.emit_number(ACC, OBJ_HIDDEN_ATTR0)
            @emitter.place_label(loop_top)
            @emitter.emit(ASM.cmp_reg(ADDR, TMP))
            @emitter.emit_branch(:bcond, done, cond: :hs)
            @emitter.emit(ASM.store_halfword(ACC, ADDR))
            @emitter.emit(ASM.add_imm(ADDR, ADDR, 8))
            @emitter.emit_branch(:b, loop_top)
            @emitter.place_label(done)
          end

          # The first row of the console's table the game's sprites are copied to: the first, or the
          # first after the border's (BorderSprites::BORDER_ROWS).
          def first_game_row = OAM_START + (@layout.border ? BorderSprites::BORDER_ROWS * 8 : 0)

          # The copy into the console's table. Each row of the copy is looked at in turn, and one
          # that is not hidden has its first three halves copied to the next row of the console's,
          # and its own number noted beside it; past the console's last row, it is counted
          # instead. The fourth half of each row is left alone: it belongs to the table's groups
          # for turning sprites, which are counted by place, not by sprite. Then the console's
          # rows past the last one copied are hidden, as far as last frame's copy reached.
          #
          # A hidden row is one with its first half's two "how it is drawn" bits saying hidden and
          # not turning (OBJ_HIDDEN_ATTR0 with the rotate/scale bit clear).
          #
          #   r0  the half being copied, then the hidden marker
          #   r1  the row of the copy being looked at     r5  its number
          #   r2  where the copy ends                      r6  rows left out this frame
          #   r3  the console's row being written         r7  scratch
          #   r4  where its number is noted                r8  where the console's table ends
          def emit_held_table_copy_routine
            held = @layout.held_sprites or return

            look = @emitter.gensym
            full = @emitter.gensym
            passed = @emitter.gensym
            hide = @emitter.gensym
            hidden = @emitter.gensym
            @emitter.emit(ASM.loop_forever) # fall-through guard: only ever entered by the call
            @emitter.place_label(HELD_TABLE_ROUTINE)
            @emitter.emit(ASM.push(4, 5, 6, 7, 8, 14))
            border = @layout.border
            @emitter.emit_number(TMP, held.copy)
            @emitter.emit_number(SPARE, held.copy + (held.rows * 8))
            @emitter.emit_number(HIGH, first_game_row)
            @emitter.emit_number(4, held.came_from)
            @emitter.emit(ASM.load_immediate(5, 0))
            @emitter.emit(ASM.load_immediate(6, 0))
            @emitter.emit_number(8, OAM_START + OAM_SIZE)
            # In a border, a frame `hide_sprites` asked for copies none of the game's rows, so the
            # hiding below reaches every row the last frame showed (#emit_switch_sprite_layer).
            copied = @emitter.gensym
            if border && hides_sprites?
              @primitives.load_var(7, SPRITES_HIDDEN)
              @emitter.emit(ASM.cmp_imm(7, SPRITES_OFF))
              @emitter.emit_branch(:bcond, copied, cond: :eq)
            end
            @emitter.place_label(look)
            @emitter.emit(ASM.load_halfword(ACC, TMP))
            @emitter.emit(ASM.and_imm(7, ACC, OBJ_ROTSCALE | OBJ_HIDDEN_ATTR0))
            @emitter.emit(ASM.cmp_imm(7, OBJ_HIDDEN_ATTR0))
            @emitter.emit_branch(:bcond, passed, cond: :eq)
            @emitter.emit(ASM.cmp_reg(HIGH, 8))
            @emitter.emit_branch(:bcond, full, cond: :hs)
            # In a border, each place is moved to where the game's screen is (BorderSprites).
            border&.emit_row_moved_by_corner(7)
            @emitter.emit(ASM.store_halfword(ACC, HIGH))
            [2, 4].each do |half|
              @emitter.emit(ASM.load_halfword_offset(ACC, TMP, half))
              border.emit_column_moved_by_corner(7) if border && half == 2
              @emitter.emit(ASM.store_halfword_offset(ACC, HIGH, half))
            end
            @emitter.emit(ASM.store_halfword(5, 4))
            @emitter.emit(ASM.add_imm(HIGH, HIGH, 8))
            @emitter.emit(ASM.add_imm(4, 4, 2))
            @emitter.emit_branch(:b, passed)
            @emitter.place_label(full)
            @emitter.emit(ASM.add_imm(6, 6, 1))
            @emitter.place_label(passed)
            @emitter.emit(ASM.add_imm(TMP, TMP, 8))
            @emitter.emit(ASM.add_imm(5, 5, 1))
            @emitter.emit(ASM.cmp_reg(TMP, SPARE))
            @emitter.emit_branch(:bcond, look, cond: :ne)
            @emitter.place_label(copied)
            @primitives.load_var(ACC, LEFT_OUT)
            @emitter.emit(ASM.add_reg(ACC, ACC, 6))
            @primitives.store_var(ACC, LEFT_OUT)
            @primitives.load_var(7, HELD_SHOWN_TO)
            @primitives.store_var(HIGH, HELD_SHOWN_TO)
            @emitter.emit_number(ACC, OBJ_HIDDEN_ATTR0)
            @emitter.place_label(hide)
            @emitter.emit(ASM.cmp_reg(HIGH, 7))
            @emitter.emit_branch(:bcond, hidden, cond: :hs)
            @emitter.emit(ASM.store_halfword(ACC, HIGH))
            @emitter.emit(ASM.add_imm(HIGH, HIGH, 8))
            @emitter.emit_branch(:b, hide)
            @emitter.place_label(hidden)
            @emitter.emit(ASM.pop(4, 5, 6, 7, 8, 15))
            @emitter.place_label(DerivedNames.routine_end(HELD_TABLE_ROUTINE))
          end

          # The routine that writes one scene's moving sprites (see GBA#prepare_scene_sprites).
          # Named for the scene, so a report and a measured profile can say whose it is.
          def self.sprites_routine(scene) = Messages::MadeNames.make(:scene_sprites, scene: Modes.strip_scene_prefix(scene))

          # What the variable that picks the scenes held when its scenes' rows were last hidden.
          def self.scene_rows_hidden_for(state) = Messages::MadeNames.make(:scene_rows_hidden_for, state: state)

          # The routine that hides every row the scenes that variable picks can use (see
          # #emit_hide_scene_rows_on_change).
          def self.hide_rows_routine(state) = Messages::MadeNames.make(:scene_rows_hide, state: state)

          # Write one scene's moving sprites, on its frames and no others. A scene that has gone
          # has had its rows hidden already (see #emit_hide_scene_rows_on_change), and another
          # scene's sprites may be using those rows now, so its own must not touch them.
          def emit_scene_sprites(group)
            emit_while_scene_up(group.state, group.value) do
              @lowering.statement(Build.call(self.class.sprites_routine(group.scene)))
            end
          end

          # Emit the block's code to run only while +state+ holds +value+: while that scene is up.
          def emit_while_scene_up(state, value)
            skip = @emitter.gensym
            @lowering.value(Build.binop(:==, Build.var_ref(state), Build.int(value)))
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, skip, cond: :eq)
            yield
            @emitter.place_label(skip)
          end

          # Hide every row a scene's sprites can be in, on the frame the scene changes, before
          # any sprite is written.
          #
          # Scenes never up together take turns at the same rows of the table (see
          # IR::SpriteRows), so the scene that went cannot hide its own sprites the way a sprite
          # hides itself: by the time it wrote "hidden" into a row, the scene that came might
          # have written a sprite there already. So nothing of a scene that is not up writes
          # anything, and this hides them all first: every row of every sprite a scene puts up,
          # its window twin's if it has one, and its place in the copy of a run drawn in an order
          # the game works out. The sprites of the scene that came are written after this, on the
          # same frame — a moving one by its scene's routine, a still one because the still ones
          # are written again whenever this variable changes (see #emit_refresh_still_sprites).
          #
          # One compare a frame for each variable that picks scenes; on a change, a call to a
          # routine of one store a row. The stores are a routine of their own so the frame's own
          # code stays the same size however many sprites the scenes have. What was remembered
          # can hold anything at power-on, and the worst a stray match does is leave rows as they
          # are, which the boot has just cleared.
          def emit_hide_scene_rows_on_change
            @layout.gated_sprites.map(&:state).uniq.each do |state|
              remembered = self.class.scene_rows_hidden_for(state)
              same = @emitter.gensym
              @primitives.load_var(ACC, state)
              @primitives.load_var(TMP, remembered)
              @emitter.emit(ASM.cmp_reg(ACC, TMP))
              @emitter.emit_branch(:bcond, same, cond: :eq)
              @primitives.store_var(ACC, remembered)
              @lowering.statement(Build.call(self.class.hide_rows_routine(state)))
              @emitter.place_label(same)
            end
          end

          # The body of that routine: hide every row the sprites +names+ are written at.
          def emit_hide_sprite_rows(names)
            emit_hide_rows_at(names.flat_map { |name| row_addresses_of(name) }.uniq.sort)
          end

          # The value of the variable that picks scenes when a scene's sprite colour table last went
          # in, and whether one has gone in since power-on or the last change of screen.
          SCENE_PICK_SENT_FOR = :__scene_pick_sent_for
          SCENE_COLORS_SENT = :__scene_sprite_colors_sent
          # The routine that sends the table of the scene picked now.
          SCENE_COLORS_ROUTINE = Messages::MadeNames.make(:scene_sprite_colors)

          # A scene's sprite colours go in with its sprites, in the gap between frames, on the frame
          # the variable that picks it changes, and not as its routine first runs.
          #
          # Scenes never up together take turns at the same groups of sprite colours (see
          # ScreenLayout#build_shared_object_palette), and which scene's sprites are in the table
          # changes here, in the gap, when the variable that picks scenes does (see
          # #emit_hide_scene_rows_on_change). Sent as the arriving scene's routine first runs, its
          # colours would land in the middle of the frame under the leaving scene's sprites, which
          # are on screen until this gap, and for that frame they would show in the arriving
          # scene's colours. So they go in here, before any row is written, the same frame the
          # rows change. Three loads, two compares and two branches a frame; nothing in a game
          # whose scenes send no colours of their own, or are not all picked by one variable (see
          # ScreenLayout#scene_colors_picker).
          #
          # What was remembered can hold anything at power-on, and a stray match would leave the
          # first scene with no colours. And a change of screen sends the table every screen shows
          # again (#emit_boot_objects), over the scene's. So the table also goes in at the first
          # gap after power-on or a change of screen, whether the variable changed or not.
          def emit_scene_colors_on_change
            picked = @layout.screen.scene_colors_picker or return

            changed = @emitter.gensym
            same = @emitter.gensym
            @primitives.load_var(ACC, picked.state)
            @primitives.load_var(TMP, SCENE_PICK_SENT_FOR)
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit_branch(:bcond, changed, cond: :ne)
            @primitives.load_var(TMP, SCENE_COLORS_SENT)
            @emitter.emit(ASM.cmp_imm(TMP, 0))
            @emitter.emit_branch(:bcond, same, cond: :ne)
            @emitter.place_label(changed)
            @primitives.store_var(ACC, SCENE_PICK_SENT_FOR)
            @lowering.statement(Build.call(SCENE_COLORS_ROUTINE))
            @emitter.place_label(same)
          end

          # The body of that routine: the table of the scene +picked+'s variable picks now, through
          # the tint in force (PaletteTint#emit_send_scene_obj_palette), and the note that the
          # table in is the right one. A value picking none of them leaves the table as it is, as a
          # scene with no colours of its own does.
          def emit_scene_colors_routine(picked)
            picked.picks.each do |pick|
              emit_while_scene_up(picked.state, pick.value) do
                @palette_tint.emit_send_scene_obj_palette(pick.blob, @layout.screen.obj_palette_units, pick.scene)
              end
            end
            @primitives.store_word_immediate(1, @primitives.var_addr(SCENE_COLORS_SENT))
          end

          # Note that no scene's table has gone in: at power-on, whatever screen the game starts on,
          # and wherever the table every screen shows is sent again.
          def emit_no_scene_colors_sent
            @primitives.store_word_immediate(0, @primitives.var_addr(SCENE_COLORS_SENT)) if @layout.screen.scene_colors_picker
          end

          # Every address a row of sprite +name+ is written at: its rows in the table, the copy
          # of them in a run's work memory when it is one of a run, and its window twin's rows.
          def row_addresses_of(name)
            obj = @layout.screen.objects.fetch(name)
            twin = placed_fade.fade_window_for(name)
            Array.new(obj.pieces) do |piece|
              [oam_slot(obj.slot, piece), row_address(obj.slot, piece), (oam_slot(twin.slot, piece) if twin)]
            end.flatten.compact
          end

          # Mark each row at +addresses+ unused. A store reaches 255 bytes on from the address in
          # its register, so the address is loaded again only when the next row is past that.
          def emit_hide_rows_at(addresses)
            @emitter.emit_number(ACC, OBJ_HIDDEN_ATTR0)
            base = nil
            addresses.each do |address|
              unless base && address - base < 256
                base = address
                @emitter.emit_number(TMP, base)
              end
              @emitter.emit(ASM.store_halfword_offset(ACC, TMP, address - base))
            end
          end

          # Write these sprites' rows of the console's table. Called twice over: by the frame,
          # for the sprites it moves, and by a routine of its own for the sprites nothing
          # moves (see GBA#prepare_still_objects, and Functions#define_generated_func, which is what makes that
          # routine).
          #
          # The split is there to keep the frame's own code small. The console re-reads this
          # table every frame and a row of it stays exactly as it was last written, so a
          # sprite the program never moves is already right — but the code to write it again
          # is some forty instructions apiece, and it sits in the body the framework keeps in
          # the console's quick memory. A picture too big for one of the console's objects is
          # drawn as several, so a title screen's lettering is a dozen of them and more; the
          # whole of that was code saying that nothing had changed.
          #
          # Sprites that are one write are written by going round it (see SpriteRepeats): a
          # pool's, which differ only in which entry of the pool's lists each reads.
          def emit_write_sprite_rows(names)
            sprites = @layout.screen.objects
            repeats = SpriteRepeats.new(sprites: sprites, row_of: ->(name) { row_address(sprites.fetch(name).slot, 0) },
                                        alone: ->(name) { must_be_written_alone?(sprites.fetch(name), name) })
            repeats.among(names).each do |part|
              next emit_sprite_repeat(part) if part.is_a?(SpriteRepeat)

              emit_present_object(sprites.fetch(part), twin: placed_fade.fade_window_for(part), name: part)
            end
          end

          # The sprites one write cannot serve, whatever they look like. Each has something of
          # its own at a place worked out from where it sits in the table, which going round
          # one write cannot reach: a window that keeps it out of a placed fade, or a room in
          # sprite memory its frames are copied into. (A sprite that turns has a group of the
          # table of its own as well, but that is a field of its record, so no two of those
          # are ever found to be one write in the first place.)
          #
          # And one drawn as more objects than a store can reach across from the first: a
          # store of a half names its address as a register and a distance under 256 bytes.
          def must_be_written_alone?(sprite, name)
            !placed_fade.fade_window_for(name).nil? || !sprite.frames.nil? || sprite.pieces > MAX_PIECES_OF_REPEATED_SPRITE
          end

          # Rows are 8 bytes, so the last half of the 32nd is 252 bytes on from the first.
          MAX_PIECES_OF_REPEATED_SPRITE = 32

          # Where the row being written is kept while a repeat is gone round.
          REPEAT_ROW = :__sprite_repeat_row

          # A row of the console's table to write: at an address settled while building, for a
          # sprite written on its own...
          FixedRow = Data.define(:address)

          # ...or +offset+ bytes on from wherever a repeat has got to, which only the running
          # game knows.
          MovingRow = Data.define(:offset)

          # Write every sprite of a repeat by going round one write. Two variables carry the
          # round: the entry of the pool's lists this sprite reads, which the write's own sums
          # name (see SpriteRepeats::INDEX), and the address of the row it writes. They are
          # kept in memory and not in registers because working out where a sprite stands is
          # free to use every register there is.
          #
          # What it costs against a copy apiece is a load of the row's address before each
          # store, and stepping the two variables — a handful of instructions a sprite. A pool's
          # sprites with nothing to show are passed over first, a store a row
          # (#emit_hide_places_left_over), and the walk starts at the first that shows something.
          def emit_sprite_repeat(repeat)
            again = @emitter.gensym
            done = @emitter.gensym
            @emitter.emit_number(ACC, repeat.first_index)
            @primitives.store_var(ACC, SpriteRepeats::INDEX)
            @emitter.emit_number(ACC, repeat.first_row)
            @primitives.store_var(ACC, REPEAT_ROW)
            live = live_count_var(repeat)
            emit_hide_places_left_over(repeat, live, done) if live
            @emitter.place_label(again)
            emit_present_object(repeat.sprite, rows: Array.new(repeat.sprite.pieces) { |piece| MovingRow.new(offset: piece * 8) })
            @primitives.load_var(ACC, REPEAT_ROW)
            @primitives.emit_add_const(ACC, ACC, repeat.row_step, TMP)
            @primitives.store_var(ACC, REPEAT_ROW)
            @primitives.load_var(ACC, SpriteRepeats::INDEX)
            @primitives.emit_add_const(ACC, ACC, repeat.index_step, TMP)
            @primitives.store_var(ACC, SpriteRepeats::INDEX)
            @emitter.emit_number(TMP, repeat.index_after)
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit_branch(:bcond, again, cond: :ne)
            @emitter.place_label(done)
          end

          # A pool's sprites, and how many of them show. Each of a pool's sprites shows a place
          # in the order its things were spawned (DSL::Pool#stacked_list), and is shown while the
          # pool holds more things than that place's rank (DSL::Pool#rank_taken) — so the places
          # with something in them are the lowest ranks, all together. The sprites are declared
          # back to front, so a walk of the table meets the ranks going down: every sprite with
          # nothing to show first, then every one that shows something. Answers the variable
          # holding how many things are in place, read off the sprites' own test, or nil for a
          # repeat that is not a pool's that way, which is written in full as before.
          #
          # Only where that rank test has the last word: the whole test, or one of several each of
          # which has to hold — joined by `&`, or by `*` of two tests that are each 0 or 1, which is
          # how a scene's own pool is shown only while the scene is up (Builder#gated_by_scene). A
          # sprite past the count is then hidden whatever the rest sets. Found inside anything else
          # (an `|`, a test turned round) it settles nothing, and the sprites are written in full.
          #
          # Not for sprites given rooms of their own in sprite memory, whose hiding gives the room
          # back (#emit_let_go_of_shared_room), which a plain hidden mark does not.
          def live_count_var(repeat)
            return nil unless repeat.index_step == -1 && repeat.sprite.rooms.nil?

            rank_test_held(repeat.sprite.active)&.lhs&.name
          end

          # The rank test (count > INDEX) in +test+ that has to hold for +test+ to, or nil.
          def rank_test_held(test)
            return nil unless test.is_a?(IR::Node) && test.kind == :binop
            return test if test.op == :> && test.lhs.kind == :var_ref && test.rhs.kind == :var_ref &&
                           test.rhs.name == SpriteRepeats::INDEX
            return nil unless %i[& *].include?(test.op)

            rank_test_held(test.lhs) || rank_test_held(test.rhs)
          end

          # Mark the places with nothing in them hidden, a store for each of a place's rows,
          # before the walk writes the places that show something. Written in full, such a place
          # cost its whole test and write and the walk's bookkeeping in memory, and a game sized
          # for its biggest room keeps pools mostly empty in every other room, so the frame paid
          # that for every slot a room did not use. Here an empty place is its rows' stores and a
          # few instructions on. The walk then carries on from the first place that shows
          # something, or is over.
          #
          # In registers that are a statement's own scratch — the place in SPARE, its row in HIGH,
          # where to stop in TMP, the hidden mark in ACC, and ADDR for a row step too big to add
          # at once — since this runs between statements of the sprites routine and nothing is
          # held across it.
          def emit_hide_places_left_over(repeat, live, done)
            place, row, stop = SPARE, HIGH, TMP
            walk = @emitter.gensym
            next_place = @emitter.gensym
            past_empty = @emitter.gensym
            @primitives.load_var(stop, live)
            @emitter.emit_number(ACC, repeat.index_after + 1)
            @emitter.emit(ASM.cmp_reg(stop, ACC))
            @emitter.emit_branch(:bcond, walk, cond: :ge)
            # Fewer things than this repeat's first place: nothing in it shows, so the walk stops
            # at its last place. (A pool's sprites can be several repeats.)
            @emitter.emit(ASM.mov_reg(stop, ACC))
            @emitter.place_label(walk)
            @emitter.emit_number(place, repeat.first_index)
            @emitter.emit_number(row, repeat.first_row)
            @emitter.emit_number(ACC, OBJ_HIDDEN_ATTR0)
            @emitter.place_label(next_place)
            @emitter.emit(ASM.cmp_reg(place, stop))
            @emitter.emit_branch(:bcond, past_empty, cond: :lt)
            repeat.sprite.pieces.times { |piece| @emitter.emit(ASM.store_halfword_offset(ACC, row, piece * 8)) }
            @primitives.emit_add_const(row, row, repeat.row_step, ADDR)
            @emitter.emit(ASM.sub_imm(place, place, 1))
            @emitter.emit_branch(:b, next_place)
            @emitter.place_label(past_empty)
            @primitives.store_var(place, SpriteRepeats::INDEX)
            @primitives.store_var(row, REPEAT_ROW)
            @emitter.emit_number(ACC, repeat.index_after)
            @emitter.emit(ASM.cmp_reg(place, ACC))
            @emitter.emit_branch(:bcond, done, cond: :eq)
          end

          # Store the low half of r0 in the half of +row+ that starts +half+ bytes into it.
          def emit_store_acc_in_row(row, half)
            return @primitives.store_halfword_acc(row.address + half) if row.is_a?(FixedRow)

            @primitives.load_var(TMP, REPEAT_ROW)
            @emitter.emit(ASM.store_halfword_offset(ACC, TMP, row.offset + half))
          end

          # Store +number+, settled while building, in that half of +row+.
          def emit_store_number_in_row(row, half, number)
            return @emitter.write_reg16(row.address + half, number) if row.is_a?(FixedRow)

            @emitter.emit_number(ACC, number)
            emit_store_acc_in_row(row, half)
          end

          # Write the still sprites, on the frames where that can matter and no others.
          #
          # Everything about such a sprite is settled except whether it is shown, and that is
          # decided by one variable: the one the program picks its scenes with, since a sprite
          # declared inside a scene is on screen exactly while that scene is. So the whole
          # question "is the sprite table still right?" is "are they in it, and was it that
          # variable's doing?" — a handful of instructions for every still sprite in the game
          # together, against a table write each.
          #
          # A game with no scenes has no such variable, so it remembers a fixed number and the
          # routine runs on the first frame and never again.
          def emit_refresh_still_sprites
            return if @layout.movement.still.empty?

            watching = @layout.movement.watching
            watching ? @primitives.load_var(ACC, watching) : @emitter.emit_number(ACC, NOTHING_TO_WATCH)
            settled = @emitter.gensym
            write = @emitter.gensym
            @primitives.load_var(TMP, STILL_STATE)
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit_branch(:bcond, write, cond: :ne) # a different scene: they need writing again
            @primitives.load_var(TMP, STILL_UP)
            @emitter.emit(ASM.cmp_imm(TMP, 0))
            @emitter.emit_branch(:bcond, settled, cond: :ne) # ...and they are in the table already
            @emitter.place_label(write)
            @primitives.store_var(ACC, STILL_STATE)
            @emitter.emit_number(TMP, 1)
            @primitives.store_var(TMP, STILL_UP)
            @lowering.statement(Build.call(STILL_ROUTINE))
            @emitter.place_label(settled)
          end

          # The routine that writes the still sprites: the ones every scene shows, and then each
          # scene's own while that scene is up. A scene that is not up writes nothing, not even
          # "hidden", because its rows are hidden already and another scene's sprites may be in
          # them now (see #emit_hide_scene_rows_on_change).
          def emit_write_still_sprite_rows(still)
            by_scene = @layout.gated_sprites.filter_map do |group|
              mine = group.names & still
              group.with(names: mine) if mine.any?
            end
            emit_write_sprite_rows(still - by_scene.flat_map(&:names))
            by_scene.each do |group|
              emit_while_scene_up(group.state, group.value) { emit_write_sprite_rows(group.names) }
            end
          end

          # Write one sprite's table entries from its live x/y/active variables. A hidden
          # sprite (active == 0) gets the "unused slot" marker instead, so it vanishes; a
          # shown one gets its position, size, and tiles — drawn upright, or turned to its
          # current angle when the sprite rotates.
          #
          # +twin+ is the window that keeps this sprite out of a placed fade, when it has
          # one. It stands exactly where the sprite stands and holds exactly the pose the
          # sprite holds, so it is filled in from the same numbers on the way past rather
          # than worked out again — a copy of each attribute as it is written, and one test
          # of where the fade is sitting. See PlacedFade.
          #
          # A picture too big for one object is drawn as several, standing shoulder to
          # shoulder — so this walks the pieces, and a sprite the console can draw in one
          # go is simply the case where there is one of them. The pieces take a run of
          # slots from the sprite's own, so the whole thing keeps one place in the stack.
          #
          # +rows+ is where each piece's row is written: the sprite's own places in the table,
          # unless it is one of a run and the run records where it has got to.
          #
          # A sprite standing further off the screen than the table can hold is kept off it
          # (see ROWS_KEPT): a piece at a time, since the far piece of a big picture can be
          # out of the table's reach while the near one is on the screen.
          def emit_present_object(obj, twin: nil, name: nil, rows: nil)
            rows ||= Array.new(obj.pieces) { |piece| FixedRow.new(address: row_address(obj.slot, piece)) }
            @lowering.value(obj.active)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            draw = @emitter.gensym
            done = @emitter.gensym
            @emitter.emit_branch(:bcond, draw, cond: :ne)
            obj.pieces.times do |piece|
              emit_store_number_in_row(rows[piece], 0, OBJ_HIDDEN_ATTR0) # active == 0: mark it unused
              @emitter.write_reg16(oam_slot(twin.slot, piece), OBJ_HIDDEN_ATTR0) if twin # ...and its window
            end
            emit_let_go_of_shared_room(obj) if obj.rooms
            @emitter.emit_branch(:b, done)

            @emitter.place_label(draw)
            emit_store_object_picked_attr2(obj) if obj.picks_attr2?
            if obj.rooms
              emit_take_shared_room(obj)
            elsif obj.frames
              emit_send_object_frame(obj, name)
            end
            emit_send_pose_first_shown(obj.pose_sends, obj.pose) if obj.pose_sends
            # Worked out once for the whole sprite when it is drawn as several objects:
            # every piece stands at the same place and reads it back from there.
            emit_stash_object_position(obj) if obj.pieces > 1
            obj.pieces.times do |piece|
              row = rows[piece]
              mirror = twin && oam_slot(twin.slot, piece)
              if obj.transformed
                emit_draw_object_transformed(obj, row, mirror)
              else
                emit_draw_object_upright(obj, row, mirror, piece)
              end
            end
            emit_hide_twin_unless_faded(twin, obj.pieces) if twin
            @emitter.place_label(done)
          end

          def oam_slot(first, piece)
            held = @layout.held_sprites
            held ? held.row_address(first + piece) : OAM_START + ((first + piece) * 8)
          end

          # Where the part of a sprite's third word a frame decides is held while its pieces are
          # written. One variable serves every sprite, since each is done before the next.
          OBJ_PICKED_ATTR2 = :__obj_picked_attr2

          # The part of a sprite's third word this frame decides, worked out once, before the
          # pieces, and ORed into each of their third words. Since that word is written with
          # the position and the pose, what it decides changes on the same frame they do.
          #
          # Two things can be decided there. WHICH COLOURS: a pixel of a small-storage sprite
          # is a place in a bank of sixteen, and the bank is named in this word — so naming
          # another bank is all it takes, and the picture itself is never touched. And how
          # deep: the console compares a sprite's two-bit depth here with each background's
          # own, and draws the sprite in front of every background whose number is the same
          # or bigger. Putting the sprite in another layer is changing those two bits.
          def emit_store_object_picked_attr2(obj)
            if obj.recolor_banks
              emit_pick_from_table(obj.recolor, obj.recolor_banks)
              emit_borrow_group_if_lent(obj) if obj.recolor_banks.lends
            end
            if obj.layer_depths
              @primitives.store_var(ACC, OBJ_PICKED_ATTR2) if obj.recolor_banks
              emit_pick_layer_depth(obj.layer_pick, obj.layer_depths)
              if obj.recolor_banks
                @primitives.load_var(TMP, OBJ_PICKED_ATTR2)
                @emitter.emit(ASM.orr_reg(ACC, ACC, TMP))
              end
            end
            @primitives.store_var(ACC, OBJ_PICKED_ATTR2)
          end

          # r0 = the word +choice+ picks out of +table+. A number past the last entry, or
          # below 0 (which compared unsigned is past it too), picks the table's last entry,
          # which is what the sprite was declared with.
          def emit_pick_from_table(choice, table)
            @lowering.value(choice)
            @emitter.emit(ASM.cmp_imm(ACC, table.own))
            @emitter.emit(ASM.mov_imm_cond(:hs, ACC, table.own))
            @emitter.emit_load_data_address(TMP, table.table)
            @emitter.emit(ASM.ldr_reg_lsl(ACC, TMP, ACC, 2))
          end

          # r0 = the depth the sprite's picked layer puts it at, on the screen that is up. Where
          # the depths differ from screen to screen the table is a row per screen, and the
          # variable that picks the screen gives which row — held to the last row, the deepest,
          # for a value that picks no screen of the sprite's own.
          def emit_pick_layer_depth(choice, depths)
            return emit_pick_from_table(choice, depths) unless depths.scene_var

            @lowering.value(choice)
            @emitter.emit(ASM.cmp_imm(ACC, depths.own))
            @emitter.emit(ASM.mov_imm_cond(:hs, ACC, depths.own))
            @primitives.load_var(TMP, depths.scene_var)
            @emitter.emit(ASM.cmp_imm(TMP, depths.scene_count))
            @emitter.emit(ASM.mov_imm_cond(:hs, TMP, depths.scene_count))
            @emitter.emit_number(2, depths.own + 1)  # r2 = one row: each layer, then its own
            @emitter.emit(ASM.mul(3, TMP, 2))                       # r3 = the screen's row (rd must differ from rm)
            @emitter.emit(ASM.add_reg(ACC, ACC, 3))
            @emitter.emit_load_data_address(TMP, depths.table)
            @emitter.emit(ASM.ldr_reg_lsl(ACC, TMP, ACC, 2))
          end

          # OR this frame's picked part into the third word being worked out in r0, for a
          # sprite whose +attr2_base+ leaves that part out.
          def orr_picked_attr2(obj)
            return unless obj.picks_attr2?

            @primitives.load_var(TMP, OBJ_PICKED_ATTR2)
            @emitter.emit(ASM.orr_reg(ACC, ACC, TMP))
          end

          # Which pose's pictures are sitting in a sprite's room right now, for a sprite that
          # keeps one frame at a time (see ScreenLayout#pick_set_for_one_frame). The sprite names its
          # own variable, so that anything reading a finished cartridge back looks in the same
          # place this writes (see Sprite#resident_frame_var, and GBA#streamed_sprite_pose_vars).
          def resident_frame_var(obj) = obj.resident_frame_var

          # Nothing is in any room: set at boot, and again whenever sprite memory is written
          # over — a screen change sends every picture again, and a scene taking over sends
          # its own over the room its sprites use — so the next draw copies its frame in.
          NO_FRAME = 0xFFFF_FFFF

          def emit_mark_still_sprites_unwritten
            return if @layout.movement.still.empty?

            @primitives.store_word_immediate(0, @primitives.var_addr(STILL_UP))
          end

          def emit_reset_resident_frames(objects)
            objects.each { |obj| @primitives.store_word_immediate(NO_FRAME, @primitives.var_addr(resident_frame_var(obj))) if obj.frames }
            objects.filter_map(&:rooms).uniq.each { |rooms| emit_empty_shared_rooms(rooms) }
          end

          # Sprites sharing rooms (see SpriteLayout::SharedRooms, which says how the record of a set
          # of rooms is laid out). The record is kept in the roomy memory. A sprite holding no room
          # holds the room past the last, which is one compare to tell.
          ROOMS = SpriteLayout::SharedRooms
          def room_table(rooms) = @layout.room_tables.fetch(rooms)
          def room_pose_at(rooms, room) = room_table(rooms) + rooms.room_at(room)
          def room_sprite_count_at(rooms, room) = room_pose_at(rooms, room) + ROOMS::SPRITE_COUNT_OFFSET
          def room_held_at(rooms, member) = room_table(rooms) + rooms.held_at(member)

          # Where the tiles of the room a sprite holds start, counted from its first room, while the
          # sprite is drawn. One variable serves every sprite, since each is done before the next.
          OBJ_ROOM_TILES = :__obj_room_tiles

          # Nothing is in any room and nobody holds one: at boot, and as their scene takes over,
          # since another scene's pictures went into the same memory.
          def emit_empty_shared_rooms(rooms)
            rooms.count.times do |room|
              @primitives.store_word_immediate(NO_FRAME, room_pose_at(rooms, room))
              @primitives.store_word_immediate(0, room_sprite_count_at(rooms, room))
              @primitives.store_word_immediate(rooms.count, room_held_at(rooms, room)) # a sprite each, as many as rooms
            end
          end

          # A sprite showing a pose takes a room holding it, when the pose is not the one in its room
          # already, and is then drawn from that room. Taking one is a routine of its own the sprites
          # of a set share, since it is the rare part: a sprite holding still, or showing what it
          # showed last frame, does a compare and the sum below.
          def emit_take_shared_room(obj)
            rooms = obj.rooms
            held = @emitter.gensym
            @lowering.value(obj.pose)
            @primitives.load_var(TMP, resident_frame_var(obj))
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit_branch(:bcond, held, cond: :eq)
            @primitives.store_var(ACC, resident_frame_var(obj))
            @emitter.emit_number(TMP, obj.room_member)
            emit_call_cold_routine(shared_room_label(rooms, :take))
            @emitter.place_label(held)
            @emitter.emit_number(TMP, room_held_at(rooms, obj.room_member))
            @emitter.emit(ASM.ldr(ACC, TMP))
            @emitter.emit_number(TMP, rooms.units)
            @emitter.emit(ASM.mul(2, ACC, TMP))
            @primitives.store_var(2, OBJ_ROOM_TILES)
          end

          # A sprite that is not shown lets go of its room, so another pose can have it. The room
          # keeps its pose, and the sprite forgets what it was showing, so it takes a room again
          # when it is shown.
          def emit_let_go_of_shared_room(obj)
            rooms = obj.rooms
            none = @emitter.gensym
            @emitter.emit_number(TMP, room_held_at(rooms, obj.room_member))
            @emitter.emit(ASM.ldr(ACC, TMP))
            @emitter.emit(ASM.cmp_imm(ACC, rooms.count))
            @emitter.emit_branch(:bcond, none, cond: :hs)
            @primitives.store_word_immediate(NO_FRAME, @primitives.var_addr(resident_frame_var(obj)))
            @emitter.emit_number(TMP, obj.room_member)
            emit_call_cold_routine(shared_room_label(rooms, :let_go))
            @emitter.place_label(none)
          end

          def shared_room_label(rooms, part)
            Messages::MadeNames.make(:shared_rooms, number: @layout.room_tables.keys.index(rooms), part: part.to_s)
          end

          # The two routines each set of shared rooms has, after the program's own code and reached
          # only by the calls above. Both are handed which sprite of the set is asking in the
          # second register, and taking one is handed the pose in the first.
          #
          #   r0  the pose, then where its tiles are in the cartridge
          #   r2  the set's record, then where the tiles go in sprite memory
          #   r3  a room's number
          #   r4  where the asking sprite's word is, saying which room it holds
          #   r5  a room's two words
          #   r12 one word read out of them
          def emit_shared_room_routines
            @layout.room_tables.each_key do |rooms|
              emit_shared_room_routine(rooms, :let_go) do
                @emitter.emit_number(TMP, rooms.count)
                @emitter.emit(ASM.str(TMP, 4)) # it holds no room now
              end
              emit_shared_room_routine(rooms, :take) { emit_give_room_holding_pose(rooms) }
            end
          end

          # r0 = the bank the list just picked out of a sprite's table is drawn from, for a word
          # that names a list borrowing its group rather than a bank (see
          # ScreenLayout::LENT_MARK). A bank goes straight through.
          #
          # A sprite wholly off the screen borrows nothing, so a thing off the screen never holds
          # a group a thing on it needs. A sprite's third word names the bank of sixteen colours
          # it is drawn from, and its first two its row (eight bits) and column (nine bits), with
          # its shape and size giving the box it covers (GBATEK, "LCD OBJ - OAM Attributes"). A
          # box none of which is on the 240 by 160 screen draws nothing, so the bank it names
          # is never seen. Such a sprite is still written into the table, just off the edge,
          # and named the first group lent out. Nothing is stamped on that group, so a group it
          # held while it was on the screen goes back after a frame, as one does when the thing
          # wearing it is hidden.
          def emit_borrow_group_if_lent(obj)
            bank = @emitter.gensym
            off_screen = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(ACC, ScreenLayout::LENT_MARK))
            @emitter.emit_branch(:bcond, bank, cond: :lo)
            @primitives.store_var(ACC, OBJ_PICKED_ATTR2)
            emit_branch_if_off_screen(obj.y, *object_reach(obj, :y), SCREEN_HEIGHT, off_screen)
            emit_branch_if_off_screen(obj.x, *object_reach(obj, :x), SCREEN_WIDTH, off_screen)
            @primitives.load_var(ACC, OBJ_PICKED_ATTR2)
            emit_call_cold_routine(LEND_COLORS)
            @emitter.emit_branch(:b, bank)
            @emitter.place_label(off_screen)
            @emitter.emit_number(ACC, @layout.screen.lending.banks.first << OBJ_BANK_SHIFT)
            @emitter.place_label(bank)
          end

          # How far before and how far past a sprite's place, across (+axis+ :x) or down (:y),
          # its picture can be drawn. An upright one is drawn from its place on, over its whole
          # canvas: a pose trimmed smaller sits inside the canvas, and the pieces of a big
          # picture stand side by side across it. One that turns or resizes is drawn in a box
          # twice its size, which stands half the picture before its place (see
          # #emit_draw_object_transformed).
          def object_reach(obj, axis)
            size = axis == :x ? obj.width : obj.height
            return [0, size] unless obj.transformed

            [size / 2, (size * 2) - (size / 2)]
          end

          # Branch to +off_screen+ when a picture drawn from +place+, reaching +before+ pixels
          # before it and +past+ pixels past it, has none of itself on a screen +edge+ pixels
          # long. It is on the screen while the place is more than +past+ before nought and less
          # than +before+ past the edge. One unsigned compare tests both ends, as
          # #emit_move_far_place_off_screen does: a place too far before reads as a very large
          # number once +past+ less one is added. Every place in that range is one the table
          # keeps as put, so the test agrees with what the console draws.
          def emit_branch_if_off_screen(place, before, past, edge, off_screen)
            span = edge + before + past - 1
            @lowering.value(place)
            @primitives.emit_add_const(ACC, ACC, past - 1, TMP)
            if ASM.encode_rotated_immediate(span)
              @emitter.emit(ASM.cmp_imm(ACC, span))
            else
              @emitter.emit_number(TMP, span)
              @emitter.emit(ASM.cmp_reg(ACC, TMP))
            end
            @emitter.emit_branch(:bcond, off_screen, cond: :hs)
          end

          LEND_COLORS = :__lend_sprite_colors

          # The frame number the groups lent out are stamped with, counted once a frame as the
          # sprites are written; how many times a list found no group to borrow; and the number of
          # the last list that found none, so whatever reads the running cartridge can name the
          # sprites that wear it (Diagnostics::AdvanceReading#colors_short_message).
          LENT_COLORS_FRAME = :__lent_colors_frame
          LENT_COLORS_MISSED = :__lent_colors_missed
          LENT_COLORS_MISSED_LIST = :__lent_colors_missed_list

          # Count one more frame of sprites being written, for the groups lent to lists.
          def emit_count_lending_frame
            return unless @layout.screen.lending

            @primitives.load_var(ACC, LENT_COLORS_FRAME)
            @emitter.emit(ASM.add_imm(ACC, ACC, 1))
            @primitives.store_var(ACC, LENT_COLORS_FRAME)
          end

          # At power-on no group is lent to any list, and nothing has been drawn.
          def emit_lent_colors_at_power_on
            lending = @layout.screen.lending
            return unless lending

            @emitter.emit_number(ACC, 0)
            [LENT_COLORS_FRAME, LENT_COLORS_MISSED, LENT_COLORS_MISSED_LIST].each { |name| @primitives.store_var(ACC, name) }
            lending.banks.each_index do |k|
              @primitives.store_var(ACC, lending.last_drawn_var(k))
              @primitives.store_var(ACC, lending.source_var(k))
            end
            @emitter.emit_number(ACC, -1)
            lending.banks.each_index { |k| @primitives.store_var(ACC, lending.holder_var(k)) }
          end

          # Lend a group of sprite colours to the list a sprite is wearing, the way the console's
          # own games hand their groups out. Called as a sprite's row is written, with r0 the
          # word its table holds for the list (LENT_MARK plus the list's number); returns r0 the
          # bank to draw it from, shifted to where the row carries it.
          #
          # A group already holding the list is the answer, and is stamped with this frame. A
          # list holding none takes a group nothing was drawn with on this frame or the one
          # before — so a group still in use, by a sprite written later in this frame, is never
          # taken from under it — and its colours are copied in, through any tint in force.
          # Since the rows are written in the gap between frames, the colours and the row that
          # first reads them reach the screen together. A list that finds every group in use
          # is drawn from the first one, in whatever colours that holds, and counted, which is
          # what the console's own games do when they run out.
          #
          # ### Why running out cannot be refused when the game is built
          #
          # The console has sixteen groups of sixteen sprite colours, and a sprite's row names
          # one of them in the top four bits of its third halfword (GBATEK, "LCD OBJ - OAM
          # Attributes", attribute 2 bits 12-15, and "LCD Color Palettes", the sprite colours
          # at 0x05000200). A sprite has no other way to name colours, so the console's own
          # games share the groups out among what is on the screen, and when every group is
          # taken they draw the newcomer from a group that holds other colours or leave it out.
          # How many lists are on the screen at once is known only as the game runs, so the
          # build cannot refuse it. The routine counts each miss and keeps the list it was for,
          # and whatever reads the running cartridge says so in plain words, naming the sprites
          # (Diagnostics::AdvanceReading#colors_short_message).
          #
          # Where it falls short of them. Their groups go back the moment the last thing
          # wearing one is removed. Here a group goes back once a whole frame has passed
          # without anything drawn with it, since the rows are written one sprite at a time
          # and nothing shows, part way through, which lists the rest will wear. So with every
          # group lent out, a thing arriving on the very frame another leaves is drawn for that
          # one frame in colours not its own.
          #
          # Each group is a few variables of its own rather than a slot in a table, so the
          # groups are walked by code written once per group: there are at most sixteen. The
          # usual call finds its list holding a group already, and puts back only the three
          # registers that search uses.
          #
          # Registers: everything it touches is put back but r0 and r12.
          #   r1  the list's number
          #   r2  this frame's number
          #   r3  a group's variable being compared; then where the group to fill sits
          #   r11 the answer, kept across the copy (which uses r0 to r10)
          def emit_lend_colors_routine
            lending = @layout.screen.lending
            return unless lending

            groups = lending.banks.each_index.to_a
            held = groups.map { @emitter.gensym }
            free = groups.map { @emitter.gensym }
            copy = @emitter.gensym
            lent = @emitter.gensym
            done = @emitter.gensym
            @emitter.emit(ASM.loop_forever) # fall-through guard: only ever entered by the call
            @emitter.place_label(LEND_COLORS)
            @emitter.emit(ASM.push(1, 2, 3))
            @emitter.emit(ASM.sub_imm(1, ACC, ScreenLayout::LENT_MARK))
            @primitives.load_var(2, LENT_COLORS_FRAME)
            groups.each do |k|
              @primitives.load_var(3, lending.holder_var(k))
              @emitter.emit(ASM.cmp_reg(3, 1))
              @emitter.emit_branch(:bcond, held[k], cond: :eq)
            end
            @emitter.emit(ASM.push(4, 5, 6, 7, 8, 9, 10, 11, 14))
            groups.each do |k|
              @primitives.load_var(3, lending.holder_var(k))
              @emitter.emit(ASM.cmp_imm(3, 0))
              @emitter.emit_branch(:bcond, free[k], cond: :lt)
              @primitives.load_var(3, lending.last_drawn_var(k))
              @emitter.emit(ASM.add_imm(3, 3, 1))
              @emitter.emit(ASM.cmp_reg(3, 2))
              @emitter.emit_branch(:bcond, free[k], cond: :lo)
            end
            emit_take_family_group(lending, free) if lending.families
            @primitives.load_var(3, LENT_COLORS_MISSED)
            @emitter.emit(ASM.add_imm(3, 3, 1))
            @primitives.store_var(3, LENT_COLORS_MISSED)
            @primitives.store_var(1, LENT_COLORS_MISSED_LIST) # only when out of groups, so the usual call pays nothing
            @emitter.emit_number(ACC, lending.banks.first << OBJ_BANK_SHIFT)
            @emitter.emit_branch(:b, lent)
            groups.each do |k|
              @emitter.place_label(free[k])
              @primitives.store_var(1, lending.holder_var(k))
              @primitives.store_var(2, lending.last_drawn_var(k))
              @emitter.emit_load_data_address(ACC, lending.blob)
              @emitter.emit(ASM.lsl_imm(3, 1, COLOR_SET_SHIFT))
              @emitter.emit(ASM.add_reg(ACC, ACC, 3))
              @primitives.store_var(ACC, lending.source_var(k))
              @emitter.emit_number(11, lending.banks[k] << OBJ_BANK_SHIFT)
              @emitter.emit_number(3, lending.group_at(k))
              @emitter.emit_branch(:b, copy)
            end
            @emitter.place_label(copy)
            @palette_tint.emit_colors_into_bank_held(PaletteTint::COLORS_IN_A_BANK)
            @emitter.emit(ASM.mov_reg(ACC, 11))
            @emitter.place_label(lent)
            @emitter.emit(ASM.pop(4, 5, 6, 7, 8, 9, 10, 11, 14))
            @emitter.emit_branch(:b, done)
            groups.each do |k|
              @emitter.place_label(held[k])
              @primitives.store_var(2, lending.last_drawn_var(k))
              @emitter.emit_number(ACC, lending.banks[k] << OBJ_BANK_SHIFT)
              @emitter.emit_branch(:b, done) unless k == groups.last
            end
            @emitter.place_label(done)
            @emitter.emit(ASM.pop(1, 2, 3))
            @emitter.emit(ASM.bx(14))
            # Where it ends, so a profile of the finished game can name it (see
            # GBA#lowered_routine_addresses).
            @emitter.place_label(DerivedNames.routine_end(LEND_COLORS))
          end

          # A list that found no group free, in a game where sprites step through lists of their
          # own (ScreenLayout#lent_families): a group holding a list of its family that nothing was
          # drawn with on this frame is its own from the frame before, and it takes that one
          # (+free+, the labels that fill a group). A list of no family, or one whose family holds
          # none, falls through to be counted.
          #
          #   r1  the list's number, r2 this frame's number, as the routine has them
          #   r3  a group's list
          #   r4  where the families are
          #   r5  the family of the list asking
          #   r6  a group's frame, then its list's family
          def emit_take_family_group(lending, free)
            none = @emitter.gensym
            @emitter.emit_load_data_address(4, lending.families)
            @emitter.emit(ASM.lsl_imm(5, 1, 2))
            @emitter.emit(ASM.add_reg(5, 5, 4))
            @emitter.emit(ASM.ldr(5, 5))
            @emitter.emit(ASM.cmp_imm(5, 0))
            @emitter.emit_branch(:bcond, none, cond: :eq)
            lending.banks.each_index do |k|
              other = @emitter.gensym
              @primitives.load_var(3, lending.holder_var(k))
              @emitter.emit(ASM.cmp_imm(3, 0))
              @emitter.emit_branch(:bcond, other, cond: :lt)
              @primitives.load_var(6, lending.last_drawn_var(k))
              @emitter.emit(ASM.cmp_reg(6, 2))
              @emitter.emit_branch(:bcond, other, cond: :eq)
              @emitter.emit(ASM.lsl_imm(6, 3, 2))
              @emitter.emit(ASM.add_reg(6, 6, 4))
              @emitter.emit(ASM.ldr(6, 6))
              @emitter.emit(ASM.cmp_reg(6, 5))
              @emitter.emit_branch(:bcond, free[k], cond: :eq)
              @emitter.place_label(other)
            end
            @emitter.place_label(none)
          end

          def emit_shared_room_routine(rooms, part)
            label = shared_room_label(rooms, part)
            @emitter.emit(ASM.loop_forever) # fall-through guard: only ever entered by the call
            @emitter.place_label(label)
            @emitter.emit(ASM.push(4, 5, 14))
            @emitter.emit(ASM.lsl_imm(4, TMP, ROOMS::HELD_WORD_SHIFT))
            @emitter.emit_number(5, room_held_at(rooms, 0))
            @emitter.emit(ASM.add_reg(4, 4, 5))
            @emitter.emit_number(2, room_table(rooms))
            emit_drop_one_room_user(rooms)
            yield
            @emitter.emit(ASM.pop(4, 5, 15))
            # Where it ends, so a profile of the finished game can name it (see
            # GBA#lowered_routine_addresses).
            @emitter.place_label(DerivedNames.routine_end(label))
          end

          # One fewer sprite draws from the room the asking sprite holds, if it holds one.
          def emit_drop_one_room_user(rooms)
            none = @emitter.gensym
            @emitter.emit(ASM.ldr(3, 4))
            @emitter.emit(ASM.cmp_imm(3, rooms.count))
            @emitter.emit_branch(:bcond, none, cond: :hs)
            @emitter.emit(ASM.lsl_imm(5, 3, ROOMS::ROOM_WORDS_SHIFT))
            @emitter.emit(ASM.add_reg(5, 5, 2))
            @emitter.emit(ASM.ldr_offset(ADDR, 5, ROOMS::SPRITE_COUNT_OFFSET))
            @emitter.emit(ASM.sub_imm(ADDR, ADDR, 1))
            @emitter.emit(ASM.str_offset(ADDR, 5, ROOMS::SPRITE_COUNT_OFFSET))
            @emitter.place_label(none)
          end

          # Give the asking sprite a room holding the pose, and count it among the room's users: the
          # room already holding the pose, if one is, used or not, and then nothing is copied. Or
          # else a room nobody draws from, with the pose copied into it. There is always one of
          # those (see SpriteLayout::SharedRooms), so the second walk always stops at one; it is
          # held to the rooms there are all the same, and would take the last of them.
          def emit_give_room_holding_pose(rooms)
            found = @emitter.gensym
            take = @emitter.gensym
            emit_walk_rooms(rooms, 0, found) { @emitter.emit(ASM.cmp_reg(ADDR, ACC)) }
            emit_walk_rooms(rooms, ROOMS::SPRITE_COUNT_OFFSET, take) { @emitter.emit(ASM.cmp_imm(ADDR, 0)) }
            @emitter.emit(ASM.sub_imm(5, 5, ROOMS::ROOM_WORDS_BYTES))
            @emitter.emit(ASM.sub_imm(3, 3, 1))
            @emitter.place_label(take)
            @emitter.emit(ASM.str(ACC, 5)) # the room holds this pose now
            @emitter.emit_number(ADDR, rooms.frame_bytes)
            @emitter.emit(ASM.mul(TMP, ACC, ADDR))
            @emitter.emit_load_data_address(ACC, rooms.frames)
            @emitter.emit(ASM.add_reg(ACC, ACC, TMP)) # from the pose's frame in the cartridge
            @emitter.emit_number(ADDR, rooms.units * 32)
            @emitter.emit(ASM.mul(2, 3, ADDR))
            @emitter.emit_number(ADDR, OBJ_TILE_BASE + (rooms.first * 32))
            @emitter.emit(ASM.add_reg(2, 2, ADDR)) # ...to the room
            sharers = @layout.screen.objects.filter_map { |name, obj| ":#{declared_name(name)}" if obj.rooms == rooms }.uniq
            @emitter.note_video_copy("sending sprite #{sharers.join(', ')} its next frame", rooms.frame_bytes)
            @primitives.emit_start_copy_engine(from: Primitives::InRegister.new(ACC), to: Primitives::InRegister.new(2),
                                   control: (rooms.frame_bytes / 4) | DMA_ENABLE | DMA_32BIT)
            @emitter.place_label(found)
            @emitter.emit(ASM.ldr_offset(ADDR, 5, ROOMS::SPRITE_COUNT_OFFSET))
            @emitter.emit(ASM.add_imm(ADDR, ADDR, 1))
            @emitter.emit(ASM.str_offset(ADDR, 5, ROOMS::SPRITE_COUNT_OFFSET))
            @emitter.emit(ASM.str(3, 4)) # the asking sprite holds it
          end

          # Walk the rooms from the first, r3 counting them and r5 at each one's two words, until
          # the word +offset+ into one passes the test the block makes, and go to +stop+ there.
          # Falls through past the last room.
          def emit_walk_rooms(rooms, offset, stop)
            again = @emitter.gensym
            @emitter.emit_number(3, 0)
            @emitter.emit(ASM.mov_reg(5, 2))
            @emitter.place_label(again)
            @emitter.emit(ASM.ldr_offset(ADDR, 5, offset))
            yield
            @emitter.emit_branch(:bcond, stop, cond: :eq)
            @emitter.emit(ASM.add_imm(5, 5, ROOMS::ROOM_WORDS_BYTES))
            @emitter.emit(ASM.add_imm(3, 3, 1))
            @emitter.emit(ASM.cmp_imm(3, rooms.count))
            @emitter.emit_branch(:bcond, again, cond: :ne)
          end

          # Copy the frame this sprite is showing into its room, when it is not the one already
          # there. The cartridge holds every frame at one stride, so the frame's start is the
          # pose times the stride, and one transfer moves it: whole words, since a frame is a
          # whole number of tiles and a tile is a whole number of words. Done in the gap after
          # the screen is drawn, with the rest of the sprite table, so the frame and the table
          # entry pointing at it change together.
          def emit_send_object_frame(obj, name)
            already = @emitter.gensym
            @lowering.value(obj.pose)
            @primitives.load_var(TMP, resident_frame_var(obj))
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit_branch(:bcond, already, cond: :eq)
            @primitives.store_var(ACC, resident_frame_var(obj))
            @emitter.emit_number(TMP, obj.frame_bytes)
            @emitter.emit(ASM.mul(2, ACC, TMP))                    # r2 = where this frame starts in the blob
            @emitter.emit_load_data_address(ACC, obj.frames)
            @emitter.emit(ASM.add_reg(ACC, ACC, 2))                # from the frame in the cartridge
            @emitter.note_video_copy("sending sprite :#{declared_name(name)} its next frame", obj.frame_bytes)
            @primitives.emit_start_copy_engine(from: Primitives::InRegister.new(ACC), to: OBJ_TILE_BASE + (obj.tile_index * 32),
                                   control: (obj.frame_bytes / 4) | DMA_ENABLE | DMA_32BIT)
            @emitter.place_label(already)
          end

          # A sprite named the way the author named it, for the build's list of what is copied when;
          # the build's own name is all a sprite they named nothing for has.
          def declared_name(name) = @layout.screen.picture.objects.find { |node| node.name == name }&.declared || name

          def emit_call_cold_routine(label) = @placement.emit_call_cold_routine(label)

          # Add the room a sprite sharing rooms is drawn from to the tile number in r0, which counts
          # from its first room (see #emit_take_shared_room).
          def emit_add_room_tiles(obj)
            return unless obj.rooms

            @primitives.load_var(TMP, OBJ_ROOM_TILES)
            @emitter.emit(ASM.add_reg(ACC, ACC, TMP))
          end

          # Copy a pool's pose into sprite memory the first time one of its things shows it since
          # the scene took over (see PoseSends). Its byte marks whether it is there; nought, and
          # the pose's run of tiles is copied out of the cartridge to where the whole set would
          # have gone, so the table entries every pose's draw already writes point at it.
          #
          #   r0  the pose, then where its tiles are in the cartridge
          #   r1  its byte, then its table, then the copy engine's address
          #   r2  its word in the table, then the copy's size and how it is told to run
          #   r3  where its tiles go in sprite memory
          def emit_send_pose_first_shown(pool, pose)
            done = @emitter.gensym
            @lowering.value(pose)
            @emitter.emit_number(TMP, pool.count)
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit_branch(:bcond, done, cond: :hs) # a pose the pool does not have shows nothing new
            @emitter.emit_number(TMP, @layout.pose_sent_bytes.fetch(pool.blob))
            @emitter.emit(ASM.add_reg(TMP, TMP, ACC))
            @emitter.emit(ASM.ldrb_offset(2, TMP, 0))
            @emitter.emit(ASM.cmp_imm(2, 0))
            @emitter.emit_branch(:bcond, done, cond: :ne) # sent already
            @emitter.emit_number(2, 1)
            @emitter.emit(ASM.strb(2, TMP))
            @emitter.emit_load_data_address(TMP, pool.table)
            @emitter.emit(ASM.ldr_reg_lsl(2, TMP, ACC, 2))
            @emitter.emit(ASM.lsl_imm(3, 2, 16))
            @emitter.emit(ASM.lsr_imm(3, 3, 11))                  # r3 = how far into the set, in bytes
            @emitter.emit_load_data_address(ACC, pool.blob)
            @emitter.emit(ASM.add_reg(ACC, ACC, 3))
            @emitter.emit_number(TMP, OBJ_TILE_BASE + (pool.tile_index * 32))
            @emitter.emit(ASM.add_reg(3, 3, TMP))
            @emitter.emit(ASM.lsr_imm(2, 2, 16))
            @emitter.emit(ASM.lsl_imm(2, 2, 3))                   # its tiles, eight words each
            @emitter.emit(ASM.cmp_imm(2, 0))
            @emitter.emit_branch(:bcond, done, cond: :eq)         # a count of nought would copy the most there is
            @emitter.emit_number(TMP, DMA_ENABLE | DMA_32BIT)
            @emitter.emit(ASM.orr_reg(2, 2, TMP))
            @primitives.emit_start_copy_engine(from: Primitives::InRegister.new(ACC), to: Primitives::InRegister.new(3), control: Primitives::InRegister.new(2))
            @emitter.place_label(done)
          end

          # Nothing of a pool's poses is in sprite memory yet, as its scene takes over: every
          # pose's byte back to nought, and the blank tile its filler pieces draw cleared (see
          # PoseSends). Nought is loaded once and stored a word at a time, since both are a few words.
          def emit_forget_poses_sent(pool)
            @emitter.emit_number(ACC, 0)
            at = @layout.pose_sent_bytes.fetch(pool.blob)
            words = (0...pool.count).step(4).map { |offset| at + offset }
            if pool.blank_at
              blank = OBJ_TILE_BASE + ((pool.tile_index + pool.blank_at) * 32)
              words += (0...pool.blank_bytes).step(4).map { |offset| blank + offset }
            end
            words.each do |address|
              @emitter.emit_number(TMP, address)
              @emitter.emit(ASM.str(ACC, TMP))
            end
          end

          # An upright sprite: position and size straight into its slot.
          def emit_draw_object_upright(obj, row, mirror = nil, piece = 0)
            return emit_draw_object_sized_poses(obj, row, mirror, piece) unless obj.alike

            # attr0 = (y & 0xFF) | shape + 256-color flag. The offset is where this pose
            # sits inside the canvas it was drawn on — added back so trimming the blank
            # away cannot move the picture (see SpriteCut#pose_box).
            @lowering.value(obj.y)
            @primitives.emit_add_const(ACC, ACC, obj.offset_y, TMP) unless obj.offset_y.zero?
            emit_move_far_place_off_screen(ROWS_DRAWN_AS_PUT, SCREEN_HEIGHT) unless drawn_as_put?(obj.y, ROWS_DRAWN_AS_PUT, obj.offset_y)
            mask_into_acc(0xFF)
            orr_acc(obj.attr0_base)
            emit_store_acc_in_row(row, 0)
            emit_copy_attr0_to_twin(mirror)
            # attr1 = (x & 0x1FF) | size
            @lowering.value(obj.x)
            @primitives.emit_add_const(ACC, ACC, obj.offset_x, TMP) unless obj.offset_x.zero?
            emit_move_far_place_off_screen(COLUMNS_DRAWN_AS_PUT, SCREEN_WIDTH) unless drawn_as_put?(obj.x, COLUMNS_DRAWN_AS_PUT, obj.offset_x)
            mask_into_acc(0x1FF)
            orr_acc(obj.attr1_base)
            emit_store_acc_in_row(row, 2)
            @primitives.store_halfword_acc(mirror + 2) if mirror
            # attr2 = which tiles to draw = this sprite's base tile + pose * stride
            # (palette bank/priority left at 0). A fixed pose folds to a constant.
            emit_object_tile_number(obj, row)
            @primitives.store_halfword_acc(mirror + 4) if mirror
          end

          # A sprite whose poses came out different sizes. Four things then move with the
          # pose — which tiles, what shape, what size, and how far along to draw it — so
          # they are read together out of one word (see ScreenLayout#object_pose_table) instead of
          # being worked out from a stride that no longer exists.
          #
          # Registers: r4 holds the word for the whole of this sprite's draw, because
          # every one of the three attributes wants a piece of it.
          POSE_WORD = 4

          # Where this sprite's position is held while the pose word is in a register.
          # Working out x AND y first is not tidiness: evaluating an operand is free to use
          # any scratch register, so the word could not survive being loaded before them.
          # Held here, nothing between loading the word and the last store evaluates
          # anything, and the register is safe for the whole of it.
          POSE_DRAW_X = :__pose_draw_x
          POSE_DRAW_Y = :__pose_draw_y

          # How far along or down a pose stands from its canvas's corner is eight bits of
          # its word, so this is both the mask that reads one and the furthest one can be.
          POSE_DISTANCE = 0xFF

          def emit_stash_object_position(obj)
            @lowering.value(obj.y)
            @primitives.store_var(ACC, POSE_DRAW_Y)
            @lowering.value(obj.x)
            @primitives.store_var(ACC, POSE_DRAW_X)
          end

          def emit_draw_object_sized_poses(obj, row, mirror = nil, piece = 0)
            # A sprite of several pieces had this done once for all of them, by the caller.
            emit_stash_object_position(obj) if obj.pieces == 1
            emit_load_pose_word(obj, piece)
            # attr0 = (y + how far down) & 0xFF, then the shape out of bits 10..11.
            @primitives.load_var(ACC, POSE_DRAW_Y)
            @emitter.emit(ASM.lsr_imm(TMP, POSE_WORD, 22))
            # The two bits above the distance set which way round the pose is drawn, and
            # are set only for a sprite with a pose that is. The test of how far off the
            # screen the row is reads the whole sum, so they are taken off before it.
            @emitter.emit(ASM.and_imm(TMP, TMP, POSE_DISTANCE)) if obj.mirrors&.any?
            @emitter.emit(ASM.add_reg(ACC, ACC, TMP))
            emit_move_far_place_off_screen(ROWS_DRAWN_AS_PUT, SCREEN_HEIGHT) unless drawn_as_put?(obj.y, ROWS_DRAWN_AS_PUT, 0, POSE_DISTANCE)
            mask_into_acc(0xFF)
            @emitter.emit(ASM.and_imm(TMP, POSE_WORD, 0x0C00))   # shape, still at bit 10
            @emitter.emit(ASM.orr_reg_lsl(ACC, ACC, TMP, 4))     # ...into bit 14
            orr_acc(obj.attr0_base) unless obj.attr0_base.zero?
            emit_store_acc_in_row(row, 0)
            emit_copy_attr0_to_twin(mirror)
            # attr1 = (x + how far right) & 0x1FF, then the size out of bits 12..13.
            @primitives.load_var(ACC, POSE_DRAW_X)
            @emitter.emit(ASM.lsr_imm(TMP, POSE_WORD, 14))
            @emitter.emit(ASM.and_imm(TMP, TMP, POSE_DISTANCE))
            @emitter.emit(ASM.add_reg(ACC, ACC, TMP))
            emit_move_far_place_off_screen(COLUMNS_DRAWN_AS_PUT, SCREEN_WIDTH) unless drawn_as_put?(obj.x, COLUMNS_DRAWN_AS_PUT, 0, POSE_DISTANCE)
            mask_into_acc(0x1FF)
            @emitter.emit(ASM.and_imm(TMP, POSE_WORD, 0x3000))   # size, still at bit 12
            @emitter.emit(ASM.orr_reg_lsl(ACC, ACC, TMP, 2))     # ...into bit 14
            emit_pose_flip_bits if obj.mirrors&.any?
            orr_acc(obj.attr1_base) unless obj.attr1_base.zero?
            emit_store_acc_in_row(row, 2)
            @primitives.store_halfword_acc(mirror + 2) if mirror
            # attr2 = the pose's own first tile, out of bits 0..9. Two shifts rather than a
            # mask: a ten-bit mask is not one of the immediates this chip can carry.
            @emitter.emit(ASM.lsl_imm(ACC, POSE_WORD, 22))
            @emitter.emit(ASM.lsr_imm(ACC, ACC, 22))
            emit_add_room_tiles(obj)
            orr_acc(obj.attr2_base) unless obj.attr2_base.zero?
            orr_picked_attr2(obj)
            emit_orr_piece_bank(obj, piece)
            emit_store_acc_in_row(row, 4)
            @primitives.store_halfword_acc(mirror + 4) if mirror
          end

          # The register a piece's own bank bits are held in from the load of its pose word to the
          # write of attribute 2 (#emit_load_pose_word): nothing between evaluates an operand, and
          # the draw works in the accumulator and TMP alone.
          PIECE_BANK = 2 # GBA::SPARE, which is not defined yet as this file loads

          # A piece that names its own bank of colours (Sprite#piece_banks): its bank bits into
          # attribute 2 (GBATEK, "LCD OBJ - OAM Attributes": bits 12-15), a number where the pose is
          # one the build knows and the word loaded beside the pose word where it is not.
          def emit_orr_piece_bank(obj, piece)
            return unless obj.piece_banks

            fixed = @primitives.const_int(obj.pose)
            if fixed
              row = piece * obj.pose_count
              bits = obj.piece_banks[fixed.between?(0, obj.pose_count - 1) ? row + fixed : row]
              return orr_acc(bits) unless bits.zero?

              return
            end
            @emitter.emit(ASM.orr_reg(ACC, ACC, PIECE_BANK))
          end

          # Carry "draw this one backwards" and "draw it upside down" from the pose word into
          # the sprite's own entry: the two bits sit side by side in both, so one shift carries
          # both. Only emitted for a sprite that actually has a turned pose, so a sprite whose
          # poses merely differ in size pays nothing for it.
          def emit_pose_flip_bits
            @emitter.emit(ASM.lsr_imm(TMP, POSE_WORD, 18))                  # bits 30 and 31 down to 12 and 13...
            @emitter.emit(ASM.and_imm(TMP, TMP, OBJ_HFLIP | OBJ_VFLIP))     # ...and nothing else with them
            @emitter.emit(ASM.orr_reg(ACC, ACC, TMP))
          end

          # How far a load can reach from a register on its own (the instruction carries a
          # 12-bit offset). Only a sprite of many pieces with a great many poses runs past
          # it, and then the address is worked out instead.
          LDR_OFFSET_LIMIT = 4096

          # r4 = the word describing the piece of the pose this sprite is showing. A fixed
          # pose is one load of a number settled while building; a pose the game works out
          # is a read from the table at that index. The table is laid out piece first, so
          # this piece's row starts at a place the build already knows and the read is the
          # same one instruction whichever piece it is.
          def emit_load_pose_word(obj, piece = 0)
            words = obj.pose_words
            row = piece * obj.pose_count
            fixed = @primitives.const_int(obj.pose)
            if fixed
              at = fixed.between?(0, obj.pose_count - 1) ? row + fixed : row
              return @emitter.emit_number(POSE_WORD, words[at])
            end

            @lowering.value(obj.pose)
            @emitter.emit(ASM.lsl_imm(ACC, ACC, 2)) # a word each
            @emitter.emit_load_data_address(TMP, obj.pose_table)
            @emitter.emit(ASM.add_reg(TMP, TMP, ACC))
            offset = row * 4
            moved = emit_load_word_at(POSE_WORD, offset)
            # A piece's own bank is the word as far past its pose word as the pose words are long
            # (ScreenLayout#object_pose_table).
            emit_load_word_at(PIECE_BANK, offset + (words.length * 4) - moved) if obj.piece_banks
          end

          # +register+ from the word +offset+ bytes past TMP, which is moved on where the offset is
          # too far for one load (ACC is spent by then: the pose is already added in). Hands back
          # how far TMP was moved.
          def emit_load_word_at(register, offset)
            return @emitter.emit(ASM.ldr(register, TMP)).then { 0 } if offset.zero?
            return @emitter.emit(ASM.ldr_offset(register, TMP, offset)).then { 0 } if offset < LDR_OFFSET_LIMIT

            @primitives.emit_add_const(TMP, TMP, offset, ACC)
            @emitter.emit(ASM.ldr(register, TMP))
            offset
          end

          # Drop the attr0 just written into the window twin's slot as well, with the bit
          # that makes it a window rather than a picture. The value is still in hand, so
          # this is two instructions and not a second sprite worked out from scratch.
          def emit_copy_attr0_to_twin(mirror)
            return unless mirror

            orr_acc(OBJ_WINDOW_MODE)
            @primitives.store_halfword_acc(mirror)
          end

          # Put the window away when the fade in force is not behind this sprite — a fade
          # over the whole screen, or one placed further forward. The sprite itself has
          # already been written, so this only has to hide the twin — one window per piece
          # for a sprite drawn as several objects, since the hole has to be the shape of
          # the whole picture. Asked once for all of them, after they are drawn.
          def emit_hide_twin_unless_faded(twin, pieces)
            @lowering.value(twin.gate)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            keeps = @emitter.gensym
            @emitter.emit_branch(:bcond, keeps, cond: :ne)
            pieces.times { |piece| @emitter.write_reg16(oam_slot(twin.slot, piece), OBJ_HIDDEN_ATTR0) }
            @emitter.place_label(keeps)
          end

          # A turning or resizing sprite: the console draws it through its affine group in
          # a double-size box. We offset the box top-left by half the sprite so the
          # picture stays centered where an upright one would sit and pivots on its own
          # center, turn on the rotate/scale and double-size bits, point attr1 at the
          # affine group, then fill that group with this frame's matrix.
          def emit_draw_object_transformed(obj, row, mirror = nil)
            half_w = obj.width / 2
            half_h = obj.height / 2
            # attr0 = ((y - half_h) & 0xFF) | rotate/scale + double-size + shape/color
            @lowering.value(obj.y)
            @emitter.emit(ASM.sub_imm(ACC, ACC, half_h)) unless half_h.zero?
            if obj.height * 2 > TALLEST_BOX_UNSEEN_BELOW
              emit_tall_box_attr0(obj)
            else
              emit_move_far_place_off_screen(ROWS_DRAWN_AS_PUT, SCREEN_HEIGHT)
              mask_into_acc(0xFF)
              orr_acc(obj.attr0_base | OBJ_ROTSCALE | OBJ_DOUBLE_SIZE)
            end
            emit_store_acc_in_row(row, 0)
            emit_copy_attr0_to_twin(mirror)
            # attr1 = ((x - half_w) & 0x1FF) | size | affine-group index (bits 9..13)
            @lowering.value(obj.x)
            @emitter.emit(ASM.sub_imm(ACC, ACC, half_w)) unless half_w.zero?
            emit_move_far_place_off_screen(TURNED_COLUMNS_DRAWN_AS_PUT, SCREEN_WIDTH)
            mask_into_acc(0x1FF)
            orr_acc(obj.attr1_base | (obj.affine_slot << 9))
            emit_store_acc_in_row(row, 2)
            # The twin points at the same affine group, so it turns and resizes with the
            # sprite and the hole stays the shape of the picture.
            @primitives.store_halfword_acc(mirror + 2) if mirror
            emit_object_tile_number(obj, row)
            @primitives.store_halfword_acc(mirror + 4) if mirror
            emit_object_affine_matrix(obj)
          end

          # Fill this sprite's affine group with the matrix for its current angle and
          # size. The group's four parameters (PA, PB, PC, PD) live in the fourth
          # halfword of four sprite slots, 8 bytes apart, starting 6 bytes into the
          # group. For a clockwise turn of the drawn picture the matrix is
          # [PA PB; PC PD] = [cos sin; -sin cos], each scaled by one over the size — the
          # console reads it as screen -> picture, so it is the same matrix the reference
          # interpreter samples through, built by the same {IR::Affine} rules. The two
          # agree by design.
          def emit_object_affine_matrix(obj)
            group = OAM_START + (obj.affine_slot * 32)
            emit_object_scale_reciprocal(obj) if obj.scales # do the divide first: it clobbers everything
            @lowering.value(obj.angle)                      # r0 = angle in degrees (0..359)
            @emitter.emit_load_data_address(TMP, OBJ_SINE_BLOB)   # r1 = sine table base
            @emitter.emit(ASM.lsl_imm(2, ACC, 1))                 # r2 = angle * 2 (halfword offset)
            @emitter.emit(ASM.add_reg(ADDR, TMP, 2))
            @emitter.emit(ASM.ldrsh(2, ADDR))                     # r2 = sin(angle)
            @emitter.emit(ASM.add_imm(3, ACC, 90))                # r3 = angle + 90
            @emitter.emit(ASM.lsl_imm(3, 3, 1))
            @emitter.emit(ASM.add_reg(ADDR, TMP, 3))
            @emitter.emit(ASM.ldrsh(3, ADDR))                     # r3 = sin(angle + 90) = cos(angle)
            emit_scale_sine_and_cosine if obj.scales   # r2, r3 *= one over the size
            @emitter.emit(ASM.rsb_imm(ACC, 2, 0))                 # r0 = -sin(angle)
            @emitter.emit_number(TMP, group + 6)
            @emitter.emit(ASM.store_halfword(3, TMP))             # PA =  cos
            @emitter.emit_number(TMP, group + 14)
            @emitter.emit(ASM.store_halfword(2, TMP))            # PB =  sin
            @emitter.emit_number(TMP, group + 22)
            @emitter.emit(ASM.store_halfword(ACC, TMP))          # PC = -sin
            @emitter.emit_number(TMP, group + 30)
            @emitter.emit(ASM.store_halfword(3, TMP))            # PD =  cos
          end

          # Work out one over this sprite's size and park it in a scratch variable.
          #
          # The matrix gives which picture pixel lands on a given screen pixel, so drawing
          # bigger means stepping through the picture SLOWER — the matrix carries one
          # over the size, not the size. There is nothing to precompute (the size is a
          # number the game works out), so this is a real division, once per resizing
          # sprite per frame, and it is why resizing costs more than turning.
          #
          # It goes to memory rather than staying in a register because the divide
          # routine uses every scratch register there is.
          def emit_object_scale_reciprocal(obj)
            @lowering.value(obj.scale)                             # r0 = size, in SCALE_ONE-ths
            @emitter.emit(ASM.cmp_imm(ACC, Affine::MIN_SCALE))
            @emitter.emit(ASM.mov_imm_cond(:lt, ACC, Affine::MIN_SCALE)) # a size of 0 has no reciprocal
            @emitter.emit_number(Divide::DIV_NUM, Build::SCALE_ONE * Affine::ONE_TH)
            @divide.emit_call_divide_routine                            # r0 = SCALE_ONE * 256 / size
            @emitter.emit_number(TMP, Affine::MAX)
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit(ASM.mov_reg_cond(:gt, ACC, TMP))               # too tiny to fit: hold at the largest
            @primitives.store_var(ACC, OBJ_SCALE_RECIP)
          end

          # Scale the sine and cosine in r2/r3 by the reciprocal worked out above, back
          # down into 256ths. A shift, not a divide, so the rounding matches
          # Affine.matrix — which rounds down for the same reason.
          def emit_scale_sine_and_cosine
            @primitives.load_var(4, OBJ_SCALE_RECIP)
            @emitter.emit(ASM.mul(5, 2, 4)) # rd must differ from rm, so the product lands elsewhere
            @emitter.emit(ASM.asr_imm(2, 5, 8))
            @emitter.emit(ASM.mul(5, 3, 4))
            @emitter.emit(ASM.asr_imm(3, 5, 8))
          end

          # Write a sprite's tile number (attr2) for this frame. The sprite's poses sit
          # back to back in tile memory, so the pose it's showing is base + pose*stride.
          # A constant pose (the common single-pose sprite) folds to a plain write; a
          # variable pose (facing / animation) is computed at run time. It is the third half
          # of the sprite's +row+.
          def emit_object_tile_number(obj, row)
            fixed = @primitives.const_int(obj.pose)
            if fixed && !obj.picks_attr2? && !obj.rooms
              emit_store_number_in_row(row, 4, obj.tile_index + (fixed * obj.per_pose) | obj.attr2_base)
            elsif fixed
              @emitter.emit_number(ACC, obj.tile_index + (fixed * obj.per_pose) | obj.attr2_base)
              emit_add_room_tiles(obj)
              orr_picked_attr2(obj)
              emit_store_acc_in_row(row, 4)
            else
              @lowering.value(obj.pose)                          # r0 = pose index
              @emitter.emit_number(TMP, obj.per_pose)   # r1 = stride between poses
              @emitter.emit(ASM.mul(2, ACC, TMP))                      # r2 = pose * stride (rd must differ from rm)
              @primitives.emit_add_const(ACC, 2, obj.tile_index, TMP)   # r0 = r2 + base tile
              emit_add_room_tiles(obj)
              orr_acc(obj.attr2_base) unless obj.attr2_base.zero?
              orr_picked_attr2(obj)
              emit_store_acc_in_row(row, 4)
            end
          end

          # r0 holds the row, or the column, a box is to stand at. Outside +places+, the ones
          # it is drawn at as put, make it +edge+: the first row below the screen, where a
          # box no taller than TALLEST_BOX_UNSEEN_BELOW shows nothing, or the first column
          # right of it, where no box is wide enough to reach back round. The sprite is
          # still in the table there, so anything reading the table back finds it, just off
          # the edge.
          #
          # One unsigned compare catches both ends, because a place too far up or left is
          # still below nought once the room above or to the left is added, and reads as a
          # very large number. Three instructions, none of them a branch.
          def emit_move_far_place_off_screen(places, edge)
            @emitter.emit(ASM.add_imm(TMP, ACC, -places.begin))
            @emitter.emit(ASM.cmp_imm(TMP, places.size))
            @emitter.emit(ASM.mov_imm_cond(:hs, ACC, edge))
          end

          # The first word of a sprite whose box no row keeps off the screen: 128 rows, where
          # only 96 are counted past the bottom edge. Standing at the first row below, its
          # end comes round onto the top.
          #
          # So when none of its picture is on the screen, it is stood at that row as a plain
          # sprite instead: the two bits that mean "turned" and "in a box twice the size" are
          # left out of the word, the console draws it in a box of its own 64 rows, and that
          # box is unseen there. It is still a row of the table, which is what tells it from
          # a sprite the game hid.
          #
          # r0 holds the row the box's top stands at, and comes back as the whole word. The
          # picture can reach only some rows of the box (see Affine#rows_reached), and it is
          # drawn turned while any of those is on the screen. The one compare decides both
          # the row and the bits, and nothing between it and them changes the flags.
          #
          # For a sprite that only turns, that is the whole answer: the rows that come round
          # are rows its picture never reaches, so nothing of it is seen at the other edge.
          # For one that resizes, the picture fills the box, and the rows it is drawn over
          # are more than the table counts. So part way off the top or the bottom, the far
          # end of such a sprite shows at the other edge, and nothing here can stop it
          # (see Reference::TurnedBox, which draws the same).
          def emit_tall_box_attr0(obj)
            reached = Affine.rows_reached(obj.width, obj.height, scales: obj.scales)
            @emitter.emit(ASM.add_imm(TMP, ACC, reached.end - 1))
            @emitter.emit_number(ADDR, reached.size - 1 + SCREEN_HEIGHT) # can be more bits than a compare carries
            @emitter.emit(ASM.cmp_reg(TMP, ADDR))
            @emitter.emit(ASM.mov_imm_cond(:hs, ACC, SCREEN_HEIGHT))
            mask_into_acc(0xFF)
            @emitter.emit_number(TMP, obj.attr0_base | OBJ_ROTSCALE | OBJ_DOUBLE_SIZE)
            @emitter.emit_number(ADDR, obj.attr0_base)
            @emitter.emit(ASM.mov_reg_cond(:hs, TMP, ADDR))
            @emitter.emit(ASM.orr_reg(ACC, ACC, TMP))
          end

          # Is +place+ a number settled while building, and one a box is drawn at as put
          # (one of +places+) wherever from +nearest+ to +furthest+ along from it the box
          # stands? Then it needs no test: the letters of a line of text, whose places are
          # written in the program.
          def drawn_as_put?(place, places, nearest, furthest = nearest)
            fixed = @primitives.const_int(place)
            !fixed.nil? && places.cover?(fixed + nearest) && places.cover?(fixed + furthest)
          end

          # r0 &= mask, using a scratch register so any mask width is fine.
          def mask_into_acc(mask)
            @emitter.emit_number(TMP, mask)
            @emitter.emit(ASM.and_reg(ACC, ACC, TMP))
          end

          # r0 |= value, via a scratch register (values here have bits too high for an
          # inline immediate).
          def orr_acc(value)
            @emitter.emit_number(TMP, value)
            @emitter.emit(ASM.orr_reg(ACC, ACC, TMP))
          end
        end
      end
    end
  end
end
