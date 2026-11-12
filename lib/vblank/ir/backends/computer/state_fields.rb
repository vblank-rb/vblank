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
        # :held_tiles, four a change), the game's backgrounds (:backgrounds, BACKGROUND_NUMBERS each), or what those
        # hold (:own_cells, a cell of each copy; :bent_lines, a screen's lines each), and the sprites
        # (:sprites_drawn and :sprites_kept, PLACED_SPRITE_NUMBERS each; :sprite_cuts, two a slice; :sprite_places,
        # three for each sprite there is room for), and the sound (:mix_voices, MIX_VOICE_NUMBERS a voice of the
        # mixer; :slice_samples, a slice's samples; :song_parts, two a part of the playing tune;
        # :held_notes, six a note; :sound_effects, EFFECT_NUMBERS an effect).
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

          # How many numbers a runtime writes for one of each thing below: the runtimes' layouts.
          BACKGROUND_NUMBERS = 21 # one background in "tiled.backgrounds"
          PLACED_SPRITE_NUMBERS = 10 # one sprite in "sprites.drawing" and "sprites.kept"
          LOUDNESS_NUMBERS = 4 # a voice's loudness: now, samples a step holds, samples left, swelling
          SOUND_NUMBERS = 3 + 4 # the sound's carry, slide clock and waveform, and a speaker for each of four voices
          SQUARE_VOICES = 2 # the square voices
          SQUARE_NUMBERS = 7 + LOUDNESS_NUMBERS # one square voice
          WAVE_NUMBERS = 32 + 6 # the wave voice's 32 steps, and six more
          NOISE_NUMBERS = 7 + LOUDNESS_NUMBERS # the noise voice
          # One voice of the sound chip: its start, loop and whether the loop was written, pitch, two
          # volumes and the two it scales by, where it reads, its block's flags, shift and filter, the two
          # samples decoded last, where the ring is written and read and how much is in it, its wait,
          # pitch counter, envelope (level, count, stage), whether it is started, the loop it plays; then
          # the ring of 32 samples.
          SPU_VOICE_NUMBERS = 24 + 32
          SPU_NUMBERS = 13 + (20 * SPU_VOICE_NUMBERS) # the sound chip's own thirteen, the game's four voices and sixteen for recordings
          MIX_NUMBERS = 5 # the mixer's own counts
          MIX_VOICE_NUMBERS = 22 # one voice of the mixer
          MUSIC_NUMBERS = 10 # the music's own counts
          WOBBLE_VOICES = 3 # the voices that wobble: the squares and the wave
          WOBBLE_NUMBERS = 6 # one voice's wobble
          SWELL_VOICES = 4 # the voices that swell: every voice
          SWELL_NUMBERS = 7 # one voice's swell
          SHAPE_NUMBERS = 3 # one square voice's shape
          HOLDER_NUMBERS = 4 + 4 # who holds each of four voices, then the voices in the order first held
          MUSIC_VOICE_NUMBERS = (WOBBLE_VOICES * WOBBLE_NUMBERS) + (SWELL_VOICES * SWELL_NUMBERS) +
                                (SQUARE_VOICES * SHAPE_NUMBERS) + HOLDER_NUMBERS # every voice's wobble, swell, shape and holder
          EFFECT_NUMBERS = 5 + 20 # one sound effect: five counts, and a cursor for each of 20 parts at most

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
            Field.new(name: "sprites.over_picture", count: :screen_cells, feature: :sprites),
            # The sound, after the screen: the part of a sample a frame carried, the slide clock, the
            # waveform a tune last put in the wave voice, and which speaker each voice plays from.
            Field.new(name: "sound", count: SOUND_NUMBERS),
            # Each square voice: its wave's ticks, eighths high, the eighth it is in and how far
            # through, its slide, the slide's ticks left and where it has slid to, then its loudness
            # (now, samples a step holds, samples left, swelling).
            Field.new(name: "sound.squares", count: SQUARE_VOICES * SQUARE_NUMBERS),
            # The wave voice's 32 steps, whether it is on, its wave's ticks, its quarters, their sum,
            # the step it is on and how far through.
            Field.new(name: "sound.wave", count: WAVE_NUMBERS),
            # The noise voice: a step's ticks, the bits in its row, the row, which way it stands and
            # stood when last heard, how far through a step and to the next hand-over, then its
            # loudness.
            Field.new(name: "sound.noise", count: NOISE_NUMBERS),
            # The sound chip of a console whose voices read sound memory (runtime/rg_spu.c), all nought
            # on any other: the voices a song struck, the game struck in this pass and in the pass
            # before, and whose loudness the pass set; those to start and to let go; the chip's
            # samples owed to the speaker, its newest sample on each side, the wave voice's waveform
            # the frames since each square voice's note started, and the recordings' voices the game
            # stopped in the pass; then each of its twenty voices' SPU_VOICE_NUMBERS.
            Field.new(name: "sound.spu", count: SPU_NUMBERS),
            # The mixer: slices made, the most voices at once, plays dropped and the most the music
            # held then, and sounds the game has started; then each voice's MIX_VOICE_NUMBERS, and the
            # newest slice.
            Field.new(name: "mix", count: MIX_NUMBERS, feature: :mix),
            Field.new(name: "mix.voices", count: :mix_voices, feature: :mix),
            Field.new(name: "mix.slice", count: :slice_samples, feature: :mix),
            # The music: the tune wanted, playing and ended, stops asked and seen, held, how far into
            # the tune, the volume its notes were set at, how many notes are held and voices have
            # been held; each part's walk (after its first time through, and its next note); each
            # held note (voice, lane, volume, ticks, eighths high, fade); each voice's wobble, swell
            # and shapes and who holds it; and each sound effect's place.
            Field.new(name: "music", count: MUSIC_NUMBERS, feature: :music),
            Field.new(name: "music.parts", count: :song_parts, feature: :music),
            Field.new(name: "music.holding", count: :held_notes, feature: :music),
            Field.new(name: "music.voices", count: MUSIC_VOICE_NUMBERS, feature: :music),
            Field.new(name: "music.effects", count: :sound_effects, feature: :music)
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
