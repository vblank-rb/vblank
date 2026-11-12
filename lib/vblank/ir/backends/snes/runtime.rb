# frozen_string_literal: true

require_relative "runtime/carries"
require_relative "runtime/boot"
require_relative "runtime/int32"
require_relative "runtime/frame"
require_relative "runtime/blank"
require_relative "runtime/lists"
require_relative "runtime/picture"
require_relative "runtime/paint"
require_relative "runtime/paint_log"
require_relative "runtime/paint_turns"
require_relative "runtime/text_layer"
require_relative "runtime/tint"
require_relative "runtime/mosaic"
require_relative "runtime/collide"
require_relative "runtime/chip"
require_relative "runtime/chip_paint"
require_relative "runtime/chip_fill"
require_relative "runtime/chip_blit"
require_relative "runtime/chip_sums"
require_relative "runtime/chip_columns"
require_relative "runtime/letterbox"
require_relative "runtime/saving"
require_relative "runtime/sound"
require_relative "runtime/music"
require_relative "runtime/effects"
require_relative "runtime/recordings"

module VBlank
  module IR
    module Backends
      class SNES
        # THE RUNTIME every Super Nintendo cartridge carries: from power-on to the game's first line
        # (Boot), the arithmetic (Int32), the frame and the buttons (Frame), the lists (Lists), the
        # picture (Picture), and save memory (Saving) for a game that saves.
        #
        # HOW ITS ROUTINES ARE CALLED. With JSL (and they return with RTL), so a routine of the
        # game's in any bank calls them alike; with A, X and Y 16 bits wide, the direct page at
        # $0000 and the data bank at $80 (Boot sets all three, and every routine leaves them so);
        # with their numbers in the working numbers R0, R1, R2... on the direct page
        # (Memory.register), and their answer in R0. A routine may use every working number, A, X,
        # Y and the runtime's scratch as it likes.
        module Runtime
          module_function

          # The runtime's own places in work RAM, asked for before the game's, for a cartridge that
          # carries +carries+ (Carries). A cartridge with a Super FX keeps the chip's waiting loop and
          # the copy of the screen's interrupt it runs meanwhile after the rest, so a plain cartridge's places do not move.
          def reserve(memory, carries)
            c = carries
            Paint.reserve(memory, chip: c.chip?, text_layer: c.text_layer, turns: c.paint_turns) if c.painted
            Frame.reserve(memory, second_controller: c.second_controller)
            Picture.reserve(memory, bar: c.bar?, row_held: c.row_held, bends: c.bends, scene_bends: c.scene_bends,
                                    tile_runs: c.tile_runs, held_runs: c.held_runs, math_turns: c.math_turns,
                                    bar_covers: c.bar_covers, tile_sizes: c.tile_sizes, scene_tiles: c.scene_tiles,
                                    scene_background_tiles: c.scene_background_tiles, third_layer: c.third_layer)
            Tint.reserve(memory, changing_colors: c.changing_colors, dims: c.dims)
            Chip.reserve(memory, extra_buttons: c.extra_buttons, second_controller: c.second_controller) if c.chip?
            Letterbox.reserve(memory) if c.letterboxes?
            Sound.reserve(memory, queued: c.songs, effects: c.effects.positive?) if c.sound
            reserve_music(memory, c) if c.songs
            Recordings.reserve(memory, glides: c.glides, chip_envelopes: c.chip_envelopes) if c.samples
            Mosaic.reserve(memory) if c.mosaic
          end

          def reserve_music(memory, carries)
            c = carries
            Music.reserve(memory, follows_level: c.follows_level, effects: c.effects, holds: c.holds_music, wobbles: c.wobbles,
                                  steps_shapes: c.steps_shapes, swells: c.swells, slides: c.slides, sides: c.sides)
          end

          # The runtime's sections: the entry points in the first bank, and everything else in one, for
          # a cartridge that carries +carries+. +lowering+ gives what only lowering the game finds out:
          # the routine run at each frame boundary, the wave voice's waveforms, the sections of its
          # songs and of its plays of recordings, where it keeps its music volume, the layers it bends,
          # and how its layers and sprites are drawn.
          def sections(memory, carries, lowering)
            c = carries
            lowered = lowered_facts(c, lowering)
            vectors = W65816.new("runtime vectors", home: :first)
            Boot.emit_vectors(vectors)
            asm = W65816.new("runtime")
            Boot.emit(asm, main: Lowering::MAIN, fast: c.board.fast)
            Boot.emit_zero(asm)
            Int32.emit(asm, Int32.scratch(memory), divides: lowering.divides?)
            pad = memory.scratch(4)
            Frame.emit(asm, memory, pad: pad, sound: c.sound, extra_buttons: c.extra_buttons,
                                    second_controller: c.second_controller, dims: c.dims)
            Blank.emit(asm, memory, Blank.scratch(memory))
            lists = Lists.scratch(memory)
            Lists.emit(asm, memory, lists)
            run_count = c.tile_runs.length
            Picture.emit(asm, memory, work: memory.scratch(8), painted: c.painted, bar: c.bar?, bent: lowered[:bent], banded: lowered[:banded],
                                      tile_runs: run_count, straight_tile_runs: c.straight_tile_runs, held_runs: c.held_runs,
                                      run_scratch: (Picture.run_scratch(memory) if run_count.positive?),
                                      see_through: lowered[:see_through], sprite_depths: lowered[:sprite_depths], big_tiles: lowered[:big_tiles],
                                      sprite_squares: lowered[:sprite_squares], changing_colors: c.changing_colors,
                                      math_turns: c.math_turns, scene_bars: lowered[:scene_bars], third_layer: c.third_layer)
            Paint.emit(asm, memory, Paint.scratch(memory), chip: c.chip?, columns: lowering.paints_columns?) if c.painted
            Tint.emit(asm, memory, Tint.scratch(memory), colors_shown: lowered[:colors_shown], changing_colors: c.changing_colors, dims: c.dims,
                               scene_backdrops: c.scene_backdrops, backdrop_follows: c.backdrop_follows)
            Collide.emit(asm, memory, Collide.scratch(memory))
            Mosaic.emit(asm, memory, backgrounds: lowering.mosaic_backgrounds) if c.mosaic
            Chip.emit(asm, memory, pad: pad, extra_buttons: c.extra_buttons, second_controller: c.second_controller) if c.chip?
            Letterbox.emit(asm, memory, black_places: lowering.painted_art.black_places) if c.letterboxes?
            if c.saves
              saving = Saving.scratch(memory)
              Saving.emit(asm, memory, saving, bank: c.board.save_bank)
              Saving.emit_list_moves(asm, saving, lists) if lowering.moves_lists_to_save?
            end
            emit_sound_routines(asm, memory, c, lowered)
            emit_start(asm, chip: c.chip?, sound: c.sound)
            emit_frame_begins(asm, lowering.frame_begins)
            chip_paint = c.painted && c.chip? ? [ChipFill.section, ChipBlit.section] : []
            [vectors.section, asm.section, *chip_paint] +
              (c.sound ? Sound.sections(lowered[:waves], recordings: lowered[:recordings], whole_notes: memory.reserved?(Sound::AHEAD),
                                                         chip_envelopes: memory.reserved?(Recordings::CHIP_ENVELOPES)) : []) +
              [lowered[:music], lowered[:plays]].compact
          end

          # What +lowering+ reports the runtime needs, asked once and in this order, since a section
          # asked for is made then.
          def lowered_facts(carries, lowering)
            { waves: lowering.sound_waves, music: (lowering.music_section if carries.songs),
              level_at: (lowering.variables.fetch(IR::Tunes::LEVEL) if carries.follows_level),
              recordings: lowering.sound_recordings, plays: (lowering.recordings_section if carries.samples),
              bent: lowering.bent_layers, banded: lowering.bends_by_bands?, see_through: lowering.see_through_layers,
              big_tiles: lowering.big_tile_layers, recorded_parts: carries.songs && lowering.recorded_parts?,
              colors_shown: lowering.colors_shown, sprite_depths: !lowering.painted? && !lowering.sprite_depths.empty?,
              sprite_squares: lowering.sprite_squares?, scene_bars: lowering.scene_bars? }
          end

          def emit_sound_routines(asm, memory, carries, lowered)
            if carries.sound
              Sound.emit(asm, memory, lowered[:waves], recordings: lowered[:recordings], songs: !lowered[:music].nil?, samples: !lowered[:plays].nil?)
            end
            Music.emit(asm, memory, level_at: lowered[:level_at], effects: carries.effects, recorded: lowered[:recorded_parts]) if lowered[:music]
            Recordings.emit(asm, memory, voices: carries.recording_voices) if lowered[:plays]
          end

          # What a game needs before its first line: its variables that do not start at nought (the
          # table "game_starts": each place as a word and its number as two, and a place of nought
          # after the last), its lists' headers, the picture's start, the screen's interrupt
          # switched on, and the buttons held from power-on. A game that makes sound sends the sound
          # unit its program first, while the screen's interrupt is still off (Sound).
          def emit_start(asm, chip: false, sound: false)
            asm.label("rt_start")
            asm.jsl(asm.long("rt_chip_start")) if chip
            asm.jsl(asm.long("rt_sound_start")) if sound
            asm.ldx(0)
            asm.label("rt_start_next")
            asm.lda(asm.long_x("game_starts"))
            asm.beq("rt_start_lists")
            asm.tay
            asm.lda(asm.long_x("game_starts", 2))
            asm.sta(asm.abs_y(0))
            asm.lda(asm.long_x("game_starts", 4))
            asm.sta(asm.abs_y(2))
            asm.txa
            asm.clc
            asm.adc(6)
            asm.tax
            asm.bra("rt_start_next")
            asm.label("rt_start_lists")
            asm.jsl(asm.long("rt_lists_start"))
            asm.jsl(asm.long("rt_picture_start"))
            emit_interrupt_on(asm)
            asm.jml(asm.long("rt_buttons_from_power_on"))
          end

          # The screen's interrupt switched on, once, as setting up ends (A 16 bits wide, and so
          # again after). A blank already under way is not a frame the game showed: a blank sets
          # a flag as it begins, and switching the interrupt on while it is set calls the
          # interrupt at once, so a setting up that happened to end inside a blank would count one
          # frame more from power-on. Reading RDNMI clears the flag first.
          def emit_interrupt_on(asm)
            asm.sep(0x20)
            asm.lda(asm.abs(Console::SNESHardware::RDNMI))
            asm.lda(Console::SNESHardware::NMI_ON)
            asm.sta(asm.abs(Console::SNESHardware::NMITIMEN))
            asm.rep(0x20)
          end

          # What moves on at each frame boundary, once the buttons are read (Reference#advance_frame's
          # middle): the game's timers, through its routine +routine+, or nothing for a game with none.
          def emit_frame_begins(asm, routine)
            asm.label("rt_frame_begins")
            asm.jml(asm.long(routine)) if routine
            asm.rtl unless routine
          end
        end
      end
    end
  end
end
