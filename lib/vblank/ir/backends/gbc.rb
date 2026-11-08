# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        # Raised when a program cannot be made into a Game Boy Color cartridge: it reaches something
        # the Color cannot do, or something its build does not make yet, or it is too big for the
        # cartridge or its memory. Said to the author in plain words.
        class LoweringError < VBlank::BuildError; end
      end
    end
  end
end

require_relative "gbc/sm83"
require_relative "gbc/linker"
require_relative "gbc/memory"
require_relative "gbc/runtime"
require_relative "gbc/art"
require_relative "gbc/square_colors"
require_relative "gbc/music"
require_relative "gbc/clips"
require_relative "gbc/sound_registers"
require_relative "gbc/lowering/picture"
require_relative "gbc/lowering/paint_reach"
require_relative "gbc/lowering/sound"
require_relative "gbc/lowering/tile_runs"
require_relative "gbc/lowering/sprite_tiles"
require_relative "gbc/lowering/clock"
require_relative "gbc/lowering/written_numbers"
require_relative "gbc/lowering/division"
require_relative "gbc/lowering/kept_variables"
require_relative "gbc/lowering"
require_relative "gbc/sound_log"
require_relative "gbc/headless_run"
require_relative "gbc/checked_run"

module VBlank
  module IR
    module Backends
      # The game as a GAME BOY COLOR cartridge: the same program every other backend runs, lowered
      # to the SM83, the Color's 8-bit processor, and laid out in a cartridge with a memory bank
      # controller.
      #
      # HOW IT IS MADE. GBC::Lowering walks the IR and emits SM83 machine code, as the GBA lowering
      # emits ARM. What it works out before writing an instruction — what a run reaches, how a
      # table is kept, where a routine too big for a bank is cut, how sections fill the banks — it
      # shares with the Super Nintendo's lowering (LoweringPlan, RoutineCuts, Sections), so the two
      # decide alike; the instructions are its own. The runtime the code calls (runtime/*.rb) is
      # written in SM83 here, in Ruby: the arithmetic of IR::Int32 a byte at a time
      # (Runtime::Int32), the frame and the buttons, the lists, and the console's own picture and
      # sound.
      #
      # What the picture is made of is the Color's, not the Advance's: a background of tiles of
      # four colours, forty sprites, eight lists of colours of each kind. What a game asks for is
      # answered by Console::ColorAnswers — it works, or it is refused, naming the hardware the
      # Color lacks — before anything is lowered.
      #
      # A game is checked by playing the cartridge in the emulator and the program on the
      # interpreter, given the Color's screen, and comparing every variable, list and pixel after
      # every pass of the game loop (GBC::CheckedRun).
      class GBC
        # WHERE A RUNNING CARTRIDGE KEEPS WHAT A READER WANTS, which nothing in its bytes shows:
        # every variable by the game's name, every list (its place, its capacity, its slot width),
        # where the runtime keeps how the run stands (Runtime::Frame's names), where every label of
        # the code went (the Linker's places), and where each of the game's routines is — a
        # GameRoutine each — for a profile to say whose time it was without reading a label. And what
        # the sound routines are handed is to the interpreter, for a run to read back what the
        # cartridge played (GBC::SoundLog): what each table of sound writes plays, by its label, the
        # songs' notes (GBC::Music#notes), whether the music follows a level the game sets, and the
        # sound effects' names, by their numbers. And what each of the cartridge's checks of its
        # picture groups asks — a sprite showing a picture whose group is not up (PictureCheck), and
        # groups up together that up_together does not allow (TogetherCheck) — by its number, so a
        # run one stops says what stopped it in the interpreter's words.
        Places = Data.define(:variables, :lists, :runtime, :source_program, :code, :routines, :sound_tables, :notes,
                             :music_follows_level, :sound_effects, :recordings, :picture_checks, :together_checks) do
          # THE SPRITES THE GAME PLACED IN ITS LAST PASS, as the interpreter gives them
          # (Reference#sprites): who each is, which picture it shows and where, back to front. The
          # runtime keeps them in a table of its own (Runtime::Picture::DRAWN), front-most first as
          # the console draws them, so anything reading a running cartridge asks the same of it.
          # +drawn+ is the program's SpriteNames, which turns the table's numbers into names;
          # +read8+ reads one byte of the running cartridge's memory, given its address.
          def drawn_sprite_rows(drawn, &read8)
            at = runtime.fetch(Runtime::Picture::DRAWN)
            little = ->(address, width) { (0...width).sum { |i| read8.call(address + i) << (8 * i) } }
            signed16 = ->(value) { value >= 0x8000 ? value - 0x10000 : value }
            rows = Array.new(read8.call(at)) do |i|
              place = at + 1 + (i * Runtime::Picture::DRAWN_BYTES)
              whose, picture, x, y = [[0, 1], [1, 2], [3, 2], [5, 2]].map { |from, width| little.call(place + from, width) }
              drawn.row(whose - 1, picture, signed16.call(x), signed16.call(y))
            end
            rows.reverse
          end

          # Where the runtime counts the times the game has waited for the screen (32 bits).
          def waits_counted_at = runtime.fetch(Runtime::Frame::PASSES)

          # The game's routine whose code holds the byte at +address+ of bank +bank+, or nil for one
          # that is not the game's (the runtime's, the art, the songs).
          def routine_at(bank, address) = routines.find { |held| held.bank == bank && held.addresses.cover?(address) }&.routine
        end

        # One of the cartridge's checks that a sprite's picture is up (Lowering::Picture
        # #emit_refuse_pictures_not_up): the sprite, by the game's name, the picture groups asked
        # about, the sprite's pictures by pose and the groups holding each, the numbers that name a
        # group, and where the number the game gave is kept for each of the groups' slots.
        PictureCheck = Data.define(:sprite, :groups, :poses, :holdings, :group_numbers, :said_at)

        # One of the cartridge's checks that a set's groups up can be up together (Lowering::Picture
        # #emit_refuse_groups_not_together): the picture groups, the numbers that name a group, and
        # where the number the game gave is kept for each of their slots.
        TogetherCheck = Data.define(:groups, :group_numbers, :said_at)

        # One routine of the game's in the cartridge: its bank, the addresses its code takes there,
        # and what it is to the author (Lowering#section_routines).
        GameRoutine = Data.define(:bank, :addresses, :routine)

        # How one try at a build keeps the art (#build): whether its sprites' lists of colours borrow
        # the console's eight as it runs (false, true, or :by_scene with each scene numbering its own),
        # and whether each screen brings its own background tiles in, and its own colours too.
        ArtSettings = Data.define(:lends, :tile_rooms, :room_colors)

        # What one try at a build keeps in the cartridge's banks rather than the part always in view
        # (#build_in_view): its songs' notes, its sprites' tables of poses, its backgrounds' tables of
        # colours, every table of its own at least +banked_table_bytes+ long, its sound effects, and
        # the indexes that record where each thing is. Each is Lowering's setting of the same name.
        ViewSettings = Data.define(:banked_songs, :bank_pose_tables, :bank_background_colors, :banked_table_bytes,
                                   :effects_in_banks, :indexes_in_banks) do
          # Everything in view that can be: a game that fits so builds the bytes it always has.
          def self.first = new(false, false, false, Lowering::BANKED_TABLE_BYTES, false, false)
        end

        # One try's lowering before it is linked: the lowering, the work memory it placed things in,
        # and every section of the cartridge.
        Lowered = Data.define(:lowering, :memory, :sections)

        # +program+ as a cartridge (Cartridge::GBCROM), carrying its Places.
        #
        # A BUILD IS A SERIES OF TRIES, each a whole lowering, until one fits. The first keeps
        # everything the simple way. A try stops at the first thing that does not fit, which decides
        # what the next try changes:
        #
        # - sprites that wear more lists of colours than the console holds: the lists borrow them as
        #   it runs (Art::TooManySpriteLists), and with more than a byte numbers, each scene numbers
        #   its own (Art::TooManyLentLists);
        # - backgrounds that need more tiles than the console holds at once: each screen brings its
        #   own tiles in (Art::TooManyBackgroundTiles), and with more lists of colours than it holds,
        #   its own colours as well (Art::TooManyBackgroundLists);
        # - sprite pictures that between them need more tiles than the console holds: each scene
        #   brings its own pictures in (Art::TooManySpriteTiles);
        # - a part of the cartridge always in view too full: more of the game kept in the banks
        #   (#build_in_view).
        #
        # Each of those is a fact about the game, not about the try that found it: lending the
        # sprites' lists does not change how many tiles the backgrounds need, nor the other way
        # round. So a later try keeps what every earlier try found it needs, and never finds it
        # again. Lists of colours and sprite tiles are refused the moment their count passes what the
        # console holds, part way through a lowering (Art#added_palette_number,
        # Art#refuse_sprite_tiles_past_most!), so a try that cannot fit stops early. The part in view
        # is only known once everything is made, which is why #build_in_view skips the tries it can
        # tell will not fit.
        #
        # What a lowering works out from the program alone, and not from how this try is built, is
        # kept from one try to the next in +cache+ (BuildCache), made for this build and handed to each try.
        def build(program, title: "RUBYGBA", cache: BuildCache.for(GBC, program))
          @scene_pictures = false
          @tries = 0
          art = ArtSettings.new(lends: false, tile_rooms: false, room_colors: false)
          loop do
            return build_in_view(program, title, art, cache)
          rescue Art::TooManySpriteTiles
            raise if @scene_pictures

            @scene_pictures = true
          rescue Art::TooManyBackgroundTiles
            raise if art.tile_rooms

            art = art.with(tile_rooms: true)
          rescue Art::TooManyBackgroundLists
            raise if art.room_colors

            art = art.with(tile_rooms: true, room_colors: true)
          rescue Art::TooManySpriteLists
            raise if art.lends

            art = art.with(lends: true)
          rescue Art::TooManyLentLists
            raise if art.lends == :by_scene

            art = art.with(lends: :by_scene)
          end
        end

        # How many times the last #build lowered the game: one for a game that fits as it first tries.
        attr_reader :tries

        # What the build found to say about what it decided (Cartridge::LoweredBuild): nothing yet.
        def findings = []

        private

        # THE PART OF THE CARTRIDGE ALWAYS IN VIEW is 16384 bytes, and a game that does not fit there
        # is built again keeping more of itself in the banks, in this order (#roomier_view): its
        # songs' notes (GBC::Music#sections); its sprites' tables of poses in each list
        # (Lowering::Picture); the tables of what its backgrounds' palettes show at each step of a
        # fade; and its own tables, the smaller ones last, since those are the ones a game reads
        # most. All of that failing, it starts again with its sound effects kept in the banks, which
        # make the most room and play a little slower, and a game that fits without them keeps its
        # bytes. And that failing too, with everything in the banks at once and the indexes besides.
        # A game whose framework code alone fills the part, which only its sound effects can grow,
        # goes straight to keeping them in the banks.
        #
        # Each step costs the game a little speed, so the build takes the first that fits. But a try
        # is a whole lowering, and only once all of it is made is the part in view known; a game
        # past it by a long way would make every try in turn to find the last. So the try that did
        # not fit is measured: its part in view, and how much of it each later step would move to
        # the banks (#bytes_moved_by). A step that would move too little to fit is skipped untried.
        def build_in_view(program, title, art, cache)
          view = ViewSettings.first
          loop do
            lowered = lower(program, art, view, cache)
            begin
              linked = Linker.new(lowered.sections, fixed_from: Console::GBCHardware::HEADER_END,
                                                    clock: lowered.lowering.clock?).link
            rescue Linker::FrameworkFillsView
              music = lowered.lowering.music
              raise if view.effects_in_banks || music.effects.empty?

              # Nothing else here shrinks the framework's own code, so go straight to what does.
              view = ViewSettings.first.with(effects_in_banks: true)
              next
            rescue Linker::TooBigForView => e
              view = roomier_view(view, lowered, e.needed) || raise
              next
            end
            return cartridge(program, title, lowered, linked)
          end
        end

        # The next try that can fit after +view+ did not: the next step (#next_view), past every step
        # that +lowered+'s part in view, +needed+ bytes, shows cannot fit. Nil for none left.
        def roomier_view(view, lowered, needed)
          music = lowered.lowering.music
          spans = in_view_spans(lowered.sections)
          following = next_view(view, songs: music.any?, effects: music.effects.any?)
          while following && needed - bytes_moved_by(view, following, spans, lowered.lowering) > Linker::BANK_SIZE
            following = next_view(following, songs: music.any?, effects: music.effects.any?)
          end
          following
        end

        # The step after +view+ (#build_in_view), nil after the last: for a game with +songs+ and
        # sound +effects+.
        #
        # THE LAST WAY TO FIT THE PART ALWAYS IN VIEW: everything kept in the banks that the build
        # can keep there — its songs' notes, its sound effects, its sprites' pose tables, its fades'
        # colour tables and every table of its own but the smallest — and the INDEXES as well, the
        # small tables that record where each of those things is. Each is a few bytes, but a few bytes
        # for every song, every sprite picture, every screen and every routine a call picks from
        # add up, so a game that keeps adding songs and screens fills the part always in view with
        # them long after the things themselves went to the banks. Kept there, a song or a screen
        # more costs nothing in view that grows with it. Each index is read with its bank put in
        # view (Runtime::Music copies a song's entry out as it starts; Runtime::Picture reads where a
        # picture, a screen's tiles or its colours are), or sits in the bank of the code that reads
        # it (Lowering#routine_data_label). A game whose sprites borrow the eight lists has each
        # scene number its own, so a screen's lists are kept with it in a bank as well (#lower).
        def next_view(view, songs:, effects:)
          smaller = Lowering::SMALLER_BANKED_TABLE_BYTES.find { |bytes| bytes < view.banked_table_bytes }
          if view.bank_background_colors && !smaller
            return ViewSettings.first.with(effects_in_banks: true) if effects && !view.effects_in_banks
            return nil if view.indexes_in_banks

            return ViewSettings.new(banked_songs: songs, bank_pose_tables: true, bank_background_colors: true,
                                    banked_table_bytes: Lowering::SMALLER_BANKED_TABLE_BYTES.min,
                                    effects_in_banks: view.effects_in_banks, indexes_in_banks: true)
          end

          moves_songs = songs && !view.banked_songs
          view.with(banked_songs: view.banked_songs || moves_songs, bank_pose_tables: view.bank_pose_tables || !moves_songs,
                    bank_background_colors: view.bank_pose_tables,
                    banked_table_bytes: view.bank_background_colors ? smaller : view.banked_table_bytes)
        end

        # AT MOST HOW MANY BYTES +later+ MOVES OUT OF VIEW that +view+ kept there, read off the try
        # that +spans+ measured (#in_view_spans) and +lowering+ made. Moving a thing to the banks
        # never shrinks the rest of what is in view: what stays to record where it went, and the code
        # that puts its bank in view, is the same size or bigger. So a try's part in view, less these bytes, is the least
        # the later one's can be. A later step that changes how the sound effects or the indexes are
        # kept is not measured here (Infinity): those move things this try's parts do not name, and
        # the build makes that try rather than guess.
        def bytes_moved_by(view, later, spans, lowering)
          return Float::INFINITY if later.effects_in_banks != view.effects_in_banks
          return Float::INFINITY if later.indexes_in_banks != view.indexes_in_banks

          moved = 0
          if later.banked_songs && !view.banked_songs
            # Each part's entry keeps the bank its notes went to: a byte more in view.
            moved += spans.sum(SONG_NOTES) - spans.count(SONG_PARTS)
          end
          moved += spans.sum(POSE_TABLES) if later.bank_pose_tables && !view.bank_pose_tables
          moved += spans.sum(BACKGROUND_COLORS) if later.bank_background_colors && !view.bank_background_colors
          if later.banked_table_bytes < view.banked_table_bytes
            # A table in the banks keeps where each of its parts is in view, three bytes at least.
            # One a list is filled from stays in view.
            copied = lowering.tables_copied_to_lists.map { |name| "table #{name}" }
            tables = spans.select(GAME_TABLES) do |bytes, label|
              bytes >= later.banked_table_bytes && !copied.include?(label)
            end
            moved += tables.sum { |bytes| bytes - 3 }
          end
          moved
        end

        # The labels in the part always in view of what each step moves to the banks: a song's list
        # of notes (Music#emit_song), a sprite's tables of poses (Lowering::Picture#pose_tables and
        # #posed_sprite_block), a background's table of colours
        # (Picture#emit_background_colors_for_declaration), and one of the game's tables
        # (Lowering#data_section).
        SONG_NOTES = /\Amusic_notes_/
        SONG_PARTS = /\Amusic_notes_\d+_\d+_first\z/
        POSE_TABLES = /\A(?:pose_pictures|pose_attributes|pose_lent_palettes|posed_sprite) \d+\z/
        BACKGROUND_COLORS = /\Abackground_colors \d+\z/
        GAME_TABLES = /\Atable (?!.* parts\z)/ # And not where the parts of one already in the banks are

        # Every label in the part always in view, with how many bytes run from it to the next label
        # after it: what it labels. Labels at one place each count what follows them all, so a sum of
        # these is never less than what the labels hold.
        InViewSpans = Data.define(:bytes_by_label) do
          # The bytes of each label +pattern+ matches that +keep+ (given them and the label) keeps.
          def select(pattern, &keep)
            keep ||= proc { true }
            bytes_by_label.filter_map { |label, bytes| bytes if label.match?(pattern) && keep.call(bytes, label) }
          end

          def sum(pattern) = select(pattern).sum
          def count(pattern) = select(pattern).length
        end

        def in_view_spans(sections)
          in_view = sections.reject { |section| %i[banked aligned16].include?(section.home) || section.home.is_a?(String) }
          spans = in_view.flat_map do |section|
            starts = (section.labels.values + [section.size]).uniq.sort
            section.labels.map { |label, at| [label, (starts.find { |start| start > at } || at) - at] }
          end
          InViewSpans.new(bytes_by_label: spans)
        end

        # One try lowered with +art+ and +view+, every section of the cartridge made, reading what the
        # build worked out once from +cache+.
        def lower(program, art, view, cache)
          @tries += 1
          memory = Memory.new
          # The last step of #build_in_view keeps each scene's record of its lists with its code in a
          # bank, so the lists the sprites borrow are numbered by scene.
          lends = view.indexes_in_banks && art.lends == true ? :by_scene : art.lends
          lowering = Lowering.new(program, memory: memory, lends_sprite_colors: lends, tile_rooms: art.tile_rooms,
                                           scene_pictures: @scene_pictures, room_colors: art.room_colors,
                                           banked_songs: view.banked_songs, bank_pose_tables: view.bank_pose_tables,
                                           bank_background_colors: view.bank_background_colors,
                                           banked_table_bytes: view.banked_table_bytes,
                                           effects_in_banks: view.effects_in_banks,
                                           indexes_in_banks: view.indexes_in_banks, cache: cache)
          # The runtime's places first, so they are in the half of work memory always in view.
          Runtime.reserve(memory, art: lowering.art, effects: lowering.music.effects, together: lowering.groups_up_together?,
                                  bar_rows: lowering.bar_rows, slides: lowering.music.slides?,
                                  wobbles: lowering.music.wobbles?, shapes: lowering.music.shapes?,
                                  swells: lowering.holds_swells?, noise_swells: lowering.holds_noise_swells?,
                                  banked_songs: lowering.music.banked?, clips: lowering.clips.any?,
                                  clip_laps: lowering.clips.loops?,
                                  dark: lowering.counts_dark_frames?, rumble: lowering.rumbles?,
                                  kept_sprites: lowering.keeps_unchanged_sprites?,
                                  holds_music: lowering.holds_music?, effect_table: lowering.music.effects_in_banks?,
                                  song_entries_in_banks: lowering.music.entries_in_banks?,
                                  cells_shown_now: lowering.cells_shown_now?,
                                  bar_covers: lowering.bar_covers_sprites?, tile_loads: lowering.loads_sprite_tiles?)
          game = lowering.sections
          runs = lowering.run_uploads
          clips = lowering.clips if lowering.clips.any?
          runtime = Runtime.sections(memory, main: Lowering::MAIN, art: lowering.art, frame_begins: lowering.frame_begins,
                                             music_level: lowering.music_level, songs: lowering.music.any?,
                                             music: lowering.music, runs: runs, drawn_palettes: lowering.drawn_palettes,
                                             big_maps: lowering.big_map_places, together: lowering.groups_up_together?,
                                             bar_rows: lowering.bar_rows, bar_maps: lowering.bar_shows_maps?, clips: clips,
                                             count_at: (lowering.variables[Frames::COUNT] if lowering.counts_dark_frames?),
                                             banked_colors: view.bank_background_colors && !lowering.drawn_palettes.nil?,
                                             byte_fills: lowering.fills_byte_lists?, queues: lowering.keeps_queues?,
                                             half_queues: lowering.keeps_half_queues?,
                                             sprites_over_picture: IR::SpritesOverPicture.any?(program),
                                             indexes_in_banks: view.indexes_in_banks,
                                             byte_divides: lowering.divides_by_written_bytes?)
          data = [*lowering.art.sections, *(lowering.music.any? ? lowering.music.sections : []), *clips&.sections]
          Lowered.new(lowering: lowering, memory: memory, sections: runtime + game + data)
        end

        # The cartridge of +lowered+, placed as +linked+ sets.
        def cartridge(program, title, lowered, linked)
          lowering = lowered.lowering
          routines = lowering.section_routines.map do |label, routine|
            placed = linked.sections.fetch(label)
            GameRoutine.new(bank: placed.bank, addresses: placed.address...(placed.address + placed.section.size), routine: routine)
          end
          built = Places.new(variables: lowering.variables, lists: lowering.lists, runtime: runtime_places(lowered.memory),
                             source_program: program, code: linked.places, routines: routines,
                             sound_tables: lowering.sound_tables, notes: lowering.music.notes,
                             music_follows_level: !lowering.music_level.nil?,
                             sound_effects: lowering.music.effects.map(&:name), recordings: lowering.clips.recordings,
                             picture_checks: lowering.picture_checks,
                             together_checks: lowering.together_checks)
          save_bytes = SaveLayout.named_by?(program) ? Runtime::Saving::SIZE : 0
          Cartridge::GBCROM.new(linked.banks, title: title, save_bytes: save_bytes, clock: lowering.clock?,
                                              rumble: lowering.rumbles?, built: built)
        end

        # Where the runtime keeps how the run stands (Runtime::Frame's names and the rest).
        def runtime_places(memory) = memory.places.select { |name, _| name.start_with?("rt ") }
      end
    end
  end
end
