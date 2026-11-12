# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # A PlayStation program played in the emulator with nobody watching, driven and read back through
        # the calls a test makes on Backends::Reference (CartridgeHeadlessRun says how a pass is read).
        # What is the PlayStation's own: its RAM read by address, low byte first; its picture read from
        # video RAM where the graphics chip is told to show it; its pad's buttons by the shared names; and
        # a run of no frames ending before the picture is on.
        #
        # THE PROGRAM STARTS ON THE EMULATOR'S FIRST FRAME. Beetle PSX runs OpenBIOS when no BIOS of Sony's
        # is in its system folder, and ruby-ps1-emulator's patch starts the program at power-on there, so
        # no frames go by in a BIOS first. The frames the runtime counts start as the picture comes on, at
        # the end of the first pass, as every cartridge console's do.
        class HeadlessRun < CartridgeHeadlessRun
          # The buttons a game names, as the emulator names the PlayStation pad's (Runtime::Pads says
          # which is which).
          PAD_BUTTONS = Ractor.make_shareable({ a: :cross, b: :circle, x: :triangle, y: :square, l: :l1, r: :r1,
                                                select: :select, start: :start, up: :up, down: :down, left: :left,
                                                right: :right })

          # The pad the build reads has no motor, so it never runs (Reference#motor_on?).
          def motor_on? = false

          # The sound log up to the moment the run ended, or the one at the frame boundary a watching block is
          # asked at, in the interpreter's words (the build's sound_entries, by the number the program's own
          # log keeps: Runtime::Sound). It is the test's to clear as it watches, as the interpreter's is: what
          # comes after is added to what the test left.
          def audio
            @audio.concat(in_interpreter_words(@logged_entries[@audio_handed...@sounds])) if @sounds > @audio_handed
            @audio_handed = [@audio_handed, @sounds].max
            @audio
          end

          # The sound log up to the moment the run ended, every entry, whatever a test did to #audio.
          def audio_played = in_interpreter_words(@logged_entries.take(@sounds))

          # Every entry the program logged, as it logged them: a stop names the tune it stopped
          # ([:stop_music, name], SongTable.stop_entry), which the writes the stop means depend on.
          def audio_as_logged = @logged_entries.dup

          # What the sound chip's registers held each time the game was found waiting at a pass's end, each
          # with how many entries the sound log held then: [entries, registers by their distance from
          # 1F801C00h], oldest first. A checked run holds them to the interpreter's sound log as far as those
          # entries (SPUWrites.after). Empty for a game that makes no sound.
          attr_reader :spu_reads

          # WHAT WAS HEARD: the loudest sample in each frame from power-on, left or right, as a number from 0
          # to 32768.
          attr_reader :loudest_each_frame

          # Every sample the console made in a run that asked for them (+keep_sound+), left and right in turn,
          # 44100 pairs a second.
          attr_reader :sound_made

          # +keep_sound+ keeps every sample the console makes, for a test of what they are.
          def initialize(save: SaveImage.new, keep_sound: false)
            super(save: save)
            @keep_sound = keep_sound
          end

          # THE RECORDINGS SOUNDING at the moment the run ended, or the one a watching block is asked at
          # (Reference#active_samples): the program's own count (Runtime::Recordings), place by place, as the
          # interpreter's mixer keeps them voice by voice.
          def active_samples = (@sounding || []).map(&:name)

          # How loud recording +name+ sounds by its shape, out of Audio::Envelope::FULL: its first place's
          # level, as the program keeps it (Reference#level_of); nil when it is not sounding.
          def level_of(name) = (@sounding || []).find { |held| held.name == name }&.level

          # Whose each recording sounding is as the run ended (Reference#sound_owners): :game for the game's
          # own, [:song, part] for a song's recorded part, [effect, part] for a sound effect's.
          def sound_owners
            effects = @places.sound_voicing&.effects || []
            (@held_at_end || []).map do |held|
              owner = held.owner
              if owner.zero? then :game
              elsif owner < Runtime::Recordings::EFFECT_OWNER then [:song, owner - 1]
              else [effects.fetch((owner >> 8) - 1), (owner & 0xFF) - 1]
              end
            end
          end

          # The plays that found every place busy, and the most of them songs held at one of those moments
          # (Reference#sound_drops), as the program counted them.
          def sound_drops
            places = Console::PLAYSTATION.recordings_at_once
            dropped, music_held = @drops || [0, 0]
            Diagnostics::SoundDrops::Reading.new(dropped: dropped, music_held: music_held, voices: places)
          end

          # The rest of what the interpreter answers, each refused by name.
          refuses :clock_at, :mixed_sound

          # HOW MANY LINES THE SCREEN HAD DRAWN since the last blank began when +pass+ went to sleep, by
          # the pass's number as #frames_took has it, read off the console's line timer
          # (Runtime::Frame::END_LINES). For a pass that took several frames a blank began while it ran,
          # so this is how many lines too late it went to sleep to take a frame fewer. Nothing the
          # interpreter can answer: it has no screen drawing a line at a time.
          def lines_after_blank(pass) = @lines_after_blank.fetch(pass)

          private

          def note_frames_took(pass)
            super
            @lines_after_blank[pass] = half(runtime_place(Runtime::Frame::END_LINES) + ((pass % Runtime::Frame::STEPS_KEPT) * 2))
          end

          def kit = Console.for(:ps1)

          # The PlayStation's player keeps the interpreter's fields (CartridgeHeadlessRun#song_taken_up), a word
          # each, whose low half is the number.
          def next_song_number = song_taken_up(Runtime::Music)

          def in_interpreter_words(entries) = entries.map { |entry| SongTable.interpreter_entry(entry) }

          def playing_recordings? = @places.runtime.key?(Runtime::Recordings::PLACES_STATE)

          # The recordings the places held at the moment of +frame+, place by place: as the pass's wait ended
          # (Runtime::Recordings::KEPT_BY_PASS), the interpreter's mix at that frame boundary, or as they are
          # now for the moment the run ended. None for a game that plays none.
          def recordings_at(frame)
            return [] unless playing_recordings?

            r = Runtime::Recordings
            held = if frame == :end
                     Array.new(r::PLACES) do |place|
                       at = runtime_place(r::PLACES_STATE) + (place * r::PLACE_BYTES)
                       [read32(at + r::HELD), read32(at + r::LEVEL), read32(at + r::OWNER)]
                     end
                   else
                     kept = (frame % Runtime::Frame::STEPS_KEPT) * r::PLACES
                     Array.new(r::PLACES) do |place|
                       [byte(runtime_place(r::KEPT_BY_PASS) + kept + place), byte(runtime_place(r::LEVELS_BY_PASS) + kept + place), nil]
                     end
                   end
            held.reject { |number, *| number.zero? }.map do |number, level, owner|
              HeldRecording.new(name: @places.recording_names.fetch(number - 1), level: level, owner: owner)
            end
          end

          # A place's recording as a run reads it: its name, its level, and whose it is (nil where not read).
          HeldRecording = Data.define(:name, :level, :owner)

          def power_on = set_buttons(@held)

          # The buttons a game names, on the pad's. One the pad lacks is one no program for it can read, so
          # it is not pressed.
          def set_buttons(buttons) = @core.set_buttons(buttons.filter_map { |button| PAD_BUTTONS[button.to_sym] })

          # A RUN OF NO FRAMES ends as the first pass does, before anything is shown: the picture is still
          # off. The interpreter shows a display switched off as a plain white picture
          # (Reference::Framebuffer::HELD_OFF), so that is the picture the run ends on, and the game goes no
          # further.
          def ends_before_first_picture?(frames) = frames.zero?

          def end_before_first_picture(variables, lists, sprites, sounds, _camera)
            hold_after_this_pass
            @sprites = sprites
            off = Array.new(@core.width * @core.height, Reference::Framebuffer::HELD_OFF)
            record_moment(:end, variables, lists, Picture.new(shown: off, width: @core.width, height: @core.height,
                                                              camera_x: 0, camera_y: 0), sounds)
          end

          def start_run(_program)
            @frames_played = 0
            @lines_after_blank = {}
            @logged_entries = []
            @sounds = 0
            @audio = []
            @audio_handed = 0
            @spu_reads = []
            @loudest_each_frame = []
            @sound_made = []
          end

          # A pass's moment waits for the count of its sounds (#sounds_counted?), but for the moment the run
          # ends on.
          def moment_ready?(pass, frames) = pass > frames || sounds_counted?(pass)

          # How many entries the program's sound log holds now, those read into the log in the interpreter's
          # words, and the chip's registers kept beside the count (#spu_reads); 0 for a game that makes no
          # sound.
          def read_sounds
            return 0 unless sound?

            logged = read32(runtime_place(Runtime::Sound::LOGGED))
            read_sound_entries(logged)
            @spu_reads << [logged, @core.spu_registers]
            logged
          end

          def sound? = @places.runtime.key?(Runtime::Sound::LOGGED)

          # How many entries the sound log held as pass +pass+'s wait ended.
          def logged_by_pass(pass) = half(logged_slot(pass) + 2)

          # Whether the program has kept that count for +pass+ yet: its slot carries the pass's number. True
          # for a game that makes no sound.
          def sounds_counted?(pass) = !sound? || half(logged_slot(pass)) == (pass & 0xFFFF)

          def logged_slot(pass)
            runtime_place(Runtime::Sound::LOGGED_BY_PASS) + ((pass % Runtime::Frame::STEPS_KEPT) * Runtime::Sound::LOGGED_SLOT_BYTES)
          end

          # The program's sound log read into the interpreter's words as far as +logged+ entries.
          def read_sound_entries(logged)
            if logged - @logged_entries.size > Runtime::Sound::LOG_LENGTH
              raise CannotAnswer, "the PlayStation program logged more than #{Runtime::Sound::LOG_LENGTH} sounds in one pass, " \
                                  "more than its sound log holds"
            end

            ring = runtime_place(Runtime::Sound::LOG)
            (@logged_entries.size...logged).each do |count|
              @logged_entries << @places.sound_entries.fetch(half(ring + ((count % Runtime::Sound::LOG_LENGTH) * 2)))
            end
          end

          def next_screen_frame = screen_on? ? super : 1

          # A page of the screen in video RAM: its top line, and its pixels as they were read.
          PageRead = Data.define(:top_line, :colors)

          # THE PICTURE A PASS DREW IS READ AS THE GAME WAITS AT ITS END, from the page it drew into
          # (Runtime::Paint::PASS_PAGE_Y). The graphics chip draws into video RAM the moment it is told
          # to, and on a screen of one page that is the page shown: by the time the reader finds the pass
          # on the screen, the game has gone on into the next pass and drawn some of it there.
          def read_picture_drawn
            top = read32(runtime_place(Runtime::Paint::PASS_PAGE_Y))
            PageRead.new(top_line: top, colors: read_page_colors(top))
          end

          # ...AND IT COUNTS ONLY IF IT IS THE PAGE SHOWN. As the pass went on the screen the runtime kept
          # which page the chip was showing (Runtime::Paint::PASS_SHOWN_PAGE_Y); that has to be the page the
          # pass drew. And what the runtime keeps of the page it last told the chip to show
          # (Runtime::Paint::SHOWN_PAGE_Y) has to be what the chip's display start holds now, so a command the
          # chip never took is seen too. The page shown is read at the pass's moment and not now, since the
          # next pass may already have changed it, as a screen becoming tear-free does. Where either does not
          # hold — a tear-free screen whose pages did not trade places — the picture is the one the chip
          # showed or shows, which the interpreter never drew.
          def picture_of_pass(_camera, drawn)
            state = @core.gpu_state
            told = read32(runtime_place(Runtime::Paint::SHOWN_PAGE_Y))
            return picture_now(nil) unless state.fetch(:display_x).zero? && state.fetch(:display_y) == told

            shown_top = read32(runtime_place(Runtime::Paint::PASS_SHOWN_PAGE_Y))
            picture_of_colors(shown_top == drawn.top_line ? drawn.colors : read_page_colors(shown_top))
          end

          # The sprites the pass placed, as the runtime keeps them (Runtime::Tiles::DRAWN): none on a painted
          # screen, which has no sprites of its own.
          def read_sprites = @places.drawn_sprite_rows(@drawn_sprites) { |address| read32(address) }

          # The moment of +frame+ — a pass's number, or :end for the moment the run ended on. +sounds+ is how
          # many entries the sound log held as the game was found waiting (#read_sounds). A PASS'S SOUNDS
          # ARE COUNTED AS ITS WAIT ENDS, where the program keeps the count (Runtime::Sound::LOGGED_BY_PASS),
          # as the music of the frame boundary will be played there. The moment the run ended on has no
          # boundary after it.
          def record_moment(frame, variables, lists, picture, sounds)
            @vars = variables
            @lists = lists
            @screen = picture
            @sounds = frame == :end || !sound? ? sounds : logged_by_pass(frame)
            read_sound_entries(@sounds) if sound?
            @sounding = recordings_at(frame)
            if playing_recordings? # read while the console is still there, for #sound_drops and #sound_owners
              @drops = [read32(runtime_place(Runtime::Recordings::DROPS)), read32(runtime_place(Runtime::Recordings::DROPS_MUSIC))]
              @held_at_end = recordings_at(:end) if frame == :end
            end
            @moments << Moment.new(frame: frame, variables: variables, picture: picture_check_of(picture.shown),
                                   sounds: @sounds, sprites: @sprites, collections: game_state.except(:vars),
                                   sounding: active_samples.map { |name| [name, level_of(name)] })
            @on_vblank&.call(frame) unless frame == :end
          end

          # The game halted: its last picture is shown by the blank that marks it, and the moment is the end
          # of the run.
          def finish_after_halt
            (1..passes).last(Runtime::Frame::STEPS_KEPT).each { |pass| note_frames_took(pass) unless @frames_took.key?(pass) }
            frames = 0
            until shown_pass == Runtime::Frame::END_SHOWN || frames > LONGEST_PASS_FRAMES
              play_frame
              frames += 1
            end
            # A game that halts shows the page it showed, not the page it was drawing into; and the sprites
            # its halting pass placed (Reference#place_pass_end_before_halt).
            @sprites = read_sprites
            record_moment(:end, read_variables, read_lists, picture_now(nil), read_sounds)
          end

          def play_frame
            @frames_played += 1
            decide_buttons unless @frames_played == 1
            @core.run_frame
            sound = @core.take_audio
            @loudest_each_frame << (sound.map(&:abs).max || 0)
            @sound_made.concat(sound) if @keep_sound
          end

          def screen_on? = read32(runtime_place(Runtime::Frame::DISPLAY_ON)) == 1

          # The picture the chip shows now. The painted screen has no camera yet.
          def picture_now(_camera) = picture_of_colors(@core.colors)

          # +colors+ as a Picture: each pixel the 15-bit colour video RAM holds, which is the library's own
          # layout (red in the low five bits).
          def picture_of_colors(colors)
            Picture.new(shown: colors, width: @core.width, height: @core.height, camera_x: 0, camera_y: 0)
          end

          # The screen's page whose top line is +top+, read from video RAM: the picture's size from the
          # chip's display mode, at the left edge, the top bit of each pixel dropped as the chip shows it.
          def read_page_colors(top) = @core.colors_at(0, top, @core.width, @core.height)

          # The picture's check, worked out once for a picture shown frame after frame.
          def picture_check_of(shown)
            return @check_of_shown if shown == @shown_checked

            @shown_checked = shown
            @check_of_shown = RunComparison.picture_check(shown)
          end

          # The PlayStation's RAM and scratchpad, read and written by address.
          def byte(address) = Diagnostics::PS1Memory.read8(@core, address)
          def half(address) = Diagnostics::PS1Memory.read16(@core, address)
          def read32(address) = Diagnostics::PS1Memory.read32(@core, address)
          def write32(address, value) = Diagnostics::PS1Memory.write32(@core, address, value)

          def state = read32(runtime_place(Runtime::Frame::STATE))
          def waiting? = read32(runtime_place(Runtime::Frame::WAITING)) == 1

          # FAULT: what went wrong, the list's place, and two numbers that show how, a word each.
          def read_fault
            at = runtime_place(Runtime::Frame::FAULT)
            [read32(at), read32(at + Runtime::Frame::FAULT_LIST), word(at + Runtime::Frame::FAULT_FIRST),
             word(at + Runtime::Frame::FAULT_SECOND)]
          end
        end
      end
    end
  end
end
