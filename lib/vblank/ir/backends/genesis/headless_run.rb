# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        # A Genesis cartridge played in the emulator with nobody watching, driven and read back through
        # the calls a test makes on Backends::Reference (CartridgeHeadlessRun says how a pass is read).
        # What is the Genesis's own: its work RAM read by address, high byte first, and a run of no
        # frames ending before the screen is on.
        #
        # THE EMULATOR'S FRAME STARTS AT THE VERTICAL BLANK, where the cartridge copies a pass's changes
        # to the console, and goes on through the lines of the picture, which are drawn after the copy. So
        # a pass's picture is on the frame that shows it, as it is on the Super Nintendo's emulator, and the
        # base run reads it there.
        class HeadlessRun < CartridgeHeadlessRun
          # The buttons a Genesis pad has, as the emulator names them: the same names as a game's.
          PAD_BUTTONS = Console::GENESIS.buttons

          # A Genesis cartridge has no rumble motor, so it never runs (Reference#motor_on?).
          def motor_on? = false

          # The sound log up to the moment the run ended, or the one at the frame boundary a watching block is
          # asked at, in the interpreter's words (the build's sound_entries, by the number the cartridge's own
          # log keeps: Runtime::Sound, read as Music.interpreter_entry). It is the test's to clear as it
          # watches, as the interpreter's is: what comes after is added to what the test left.
          def audio
            @audio.concat(in_interpreter_words(@logged_entries[@audio_handed...@sounds])) if @sounds > @audio_handed
            @audio_handed = [@audio_handed, @sounds].max
            @audio
          end
          
          # The sound log up to the moment the run ended, every entry, whatever a test did to #audio.
          def audio_played = in_interpreter_words(@logged_entries.take(@sounds))
          
          # Every entry the cartridge logged, as it logged them: a stop names the tune it stopped
          # ([:stop_music, name], Music.stop_entry), which the writes the stop means depend on.
          def audio_as_logged = @logged_entries.dup
          
          # What the chips held each time the game was found waiting at a pass's end, each with how many
          # entries the sound log held then: [entries, [the PSG's registers, the FM chip's]], oldest first. A
          # checked run holds them to the interpreter's sound log as far as those entries (ChipWrites.after).
          # Empty for a game that makes no sound.
          attr_reader :chip_reads
          
          # WHAT WAS HEARD: the loudest sample in each screen frame from power-on, left or right, as a number
          # from 0 to 32768. A frame is the finest it sees.
          attr_reader :loudest_each_frame
          
          # Every sample the console made in a run that asked for them (+keep_sound+), left and right in turn.
          attr_reader :sound_made
          
          # The recording sounding as the run ended (Reference#active_samples): the cartridge's own count
          # (Runtime::Recordings), at most the one a Genesis plays.
          def active_samples = @sounding || []
          
          # A Genesis plays a recording all or nothing, so one sounding is at full (Reference#level_of).
          def level_of(name) = active_samples.include?(name) ? Audio::Envelope::FULL : nil
          
          # Whose the recording sounding was as the run ended (Reference#sound_owners): :game for the game's own,
          # [:song, part] for a song's recorded part, [effect, part] for a sound effect's.
          def sound_owners
            return [] unless playing_recordings? && !half(place_of_recording + Runtime::Recordings::HELD).zero?
          
            owner = half(place_of_recording + Runtime::Recordings::OWNER)
            if owner.zero? then [:game]
            elsif owner < Runtime::Recordings::EFFECT_OWNER then [[:song, owner - 1]]
            else [[@places.sound_voicing.effects.fetch((owner >> 8) - 1), (owner & 0xFF) - 1]]
            end
          end
          
          # The plays and notes that found the place busy, and whether a song's held it at one of those moments
          # (Reference#sound_drops), as the cartridge counted them.
          def sound_drops
            return Diagnostics::SoundDrops::Reading.new(dropped: 0, music_held: 0, voices: 1) unless @drops
          
            Diagnostics::SoundDrops::Reading.new(dropped: @drops.first, music_held: @drops.last, voices: 1)
          end
          
          # +keep_sound+ keeps every sample the console makes, for a test of what they are: a run plays a good
          # deal of them, so only a test that asks for them pays for it.
          def initialize(save: SaveImage.new, keep_sound: false)
            super(save: save)
            @keep_sound = keep_sound
          end
          
          # The rest of what the interpreter answers, each refused by name.
          refuses :clock_at, :mixed_sound

          private

          def kit = Console.for(:genesis)

          # The Genesis's player keeps the interpreter's fields (CartridgeHeadlessRun#song_taken_up).
          def next_song_number = song_taken_up(Runtime::Music)

          def big_endian? = true

          def power_on = set_buttons(@held)

          # The buttons a game names, on the pad's: the same names. A button a Genesis pad lacks is
          # one no cartridge for it can read, so it is not pressed.
          def set_buttons(buttons) = @core.set_buttons(buttons.map(&:to_sym) & PAD_BUTTONS)

          # A RUN OF NO FRAMES ends as the first pass does, before anything is shown: the screen is
          # still switched off. The interpreter shows a display switched off as a plain white picture
          # (Reference::Framebuffer::HELD_OFF), so that is the picture the run ends on, and the game goes
          # no further.
          def ends_before_first_picture?(frames) = frames.zero?

          def end_before_first_picture(variables, lists, sprites, sounds, camera)
            hold_after_this_pass
            @sprites = sprites
            off = Array.new(@core.width * @core.height, Reference::Framebuffer::HELD_OFF)
            record_moment(:end, variables, lists, Picture.new(shown: off, width: @core.width, height: @core.height,
                                                              camera_x: camera[0], camera_y: camera[1]), sounds)
          end

          # A pass's moment waits for the count of its sounds (#sounds_counted?), but for the moment the run
          # ends on.
          def moment_ready?(pass, frames) = pass > frames || sounds_counted?(pass)
          
          # How many entries the cartridge's sound log holds now, those read into the log in the interpreter's
          # words, and the chips' registers kept beside the count (#chip_reads); 0 for a game that makes no sound.
          def read_sounds
            return 0 unless sound?
          
            logged = half(runtime_place(Runtime::Sound::LOGGED))
            read_sound_entries(logged)
            @chip_reads << [logged, [@core.psg_registers, @core.fm_registers]]
            logged
          end
          
          def sound? = @places.runtime.key?(Runtime::Sound::LOGGED)
          
          # How many entries the sound log held as pass +pass+'s wait ended.
          def logged_by_pass(pass) = half(logged_slot(pass) + 2)
          
          # Whether the cartridge has kept that count for +pass+ yet: its slot carries the pass's number. True
          # for a game that makes no sound.
          def sounds_counted?(pass) = !sound? || half(logged_slot(pass)) == (pass & 0xFFFF)
          
          def logged_slot(pass)
            runtime_place(Runtime::Sound::LOGGED_BY_PASS) + ((pass % Runtime::Frame::STEPS_KEPT) * Runtime::Sound::LOGGED_SLOT_BYTES)
          end
          
          # The cartridge's sound log read into the interpreter's words as far as +logged+ entries.
          def read_sound_entries(logged)
            if logged - @logged_entries.size > Runtime::Sound::LOG_LENGTH
              raise CannotAnswer, "the Genesis cartridge logged more than #{Runtime::Sound::LOG_LENGTH} sounds in one pass, " \
                                  "more than its sound log holds"
            end
          
            ring = runtime_place(Runtime::Sound::LOG)
            (@logged_entries.size...logged).each do |count|
              @logged_entries << @places.sound_entries.fetch(half(ring + ((count % Runtime::Sound::LOG_LENGTH) * 2)))
            end
          end
          
          def in_interpreter_words(entries) = entries.map { |entry| Music.interpreter_entry(entry) }
          
          def playing_recordings? = @places.runtime.key?(Runtime::Recordings::PLACE)
          
          def place_of_recording = runtime_place(Runtime::Recordings::PLACE)
          
          # The recording the place held at the moment of +frame+, as a list: as the pass's wait ended
          # (Runtime::Recordings::KEPT_BY_PASS), the interpreter's mix at that frame boundary, or as it is now
          # for the moment the run ended. None for a game that plays none.
          def recordings_at(frame)
            return [] unless playing_recordings?
          
            number = if frame == :end
                       half(place_of_recording + Runtime::Recordings::HELD)
                     else
                       half(runtime_place(Runtime::Recordings::KEPT_BY_PASS) + ((frame % Runtime::Frame::STEPS_KEPT) * 2))
                     end
            number.zero? ? [] : [@places.recording_names.fetch(number - 1)]
          end
          
          # THE BUTTONS ARE THE ONES HELD FROM POWER-ON for the first emulated frame, which is where the
          # cartridge reads them (Runtime::Boot), and from the second on each frame's own, decided before
          # the frame is played. The frames the runtime counts (Frame::FRAMES) start as the screen comes
          # on, a few emulated frames in, with the frame whose interrupt switches it on as the first: every
          # frame before it is the first's, and the interrupts of those read the buttons the script gave
          # for it.
          def start_run(_program)
            @frames_played = 0
            @deciding = true
            @logged_entries = []
            @sounds = 0
            @audio = []
            @audio_handed = 0
            @chip_reads = []
            @loudest_each_frame = []
            @sound_made = []
          end

          def next_screen_frame = screen_on? ? super : 1

          # The moment of +frame+ — a pass's number, or :end for the moment the run ended on. +sounds+ is how
          # many entries the sound log held as the game was found waiting (#read_sounds). A PASS'S SOUNDS
          # INCLUDE ITS FRAME BOUNDARY'S MUSIC, which the cartridge plays where the wait ends, after the game
          # was found waiting, so a pass's moment takes the count the cartridge kept as that wait ended
          # (Runtime::Sound::LOGGED_BY_PASS). The moment the run ended on has no boundary after it.
          def record_moment(frame, variables, lists, picture, sounds)
            @vars = variables
            @lists = lists
            @screen = picture
            @sounds = frame == :end || !sound? ? sounds : logged_by_pass(frame)
            read_sound_entries(@sounds) if sound?
            @sounding = recordings_at(frame)
            @drops = [half(runtime_place(Runtime::Recordings::DROPS)), half(runtime_place(Runtime::Recordings::DROPS_MUSIC))] if playing_recordings?
            @moments << Moment.new(frame: frame, variables: variables, picture: picture_check_of(picture.shown),
                                   sounds: @sounds, sprites: @sprites, collections: game_state.except(:vars), sounding: active_samples)
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
            @sprites = read_sprites
            record_moment(:end, read_variables, read_lists, picture_now(read_camera), read_sounds)
          end

          def play_frame
            @frames_played += 1
            decide_buttons unless @frames_played == 1
            @core.run_frame
            sound = @core.take_audio
            @loudest_each_frame << (sound.map(&:abs).max || 0)
            @sound_made.concat(sound) if @keep_sound
          end

          def screen_on? = half(runtime_place(Runtime::Frame::DISPLAY_ON)) == 1

          # The emulator's picture, each pixel the 15-bit colour the console holds (the three bits of
          # each channel it keeps, widened), and where the camera put the view, [x, y], as the pass
          # left it. Most frames show the picture the last one did, and the core hands the same list
          # back for those, so its colours are widened once.
          def picture_now(camera)
            colors = @core.colors
            unless colors.equal?(@colors_widened)
              @colors_widened = colors
              @shown_widened = colors.map { |color| COLORS.fetch(color) }
            end
            Picture.new(shown: @shown_widened, width: @core.width, height: @core.height, camera_x: camera[0], camera_y: camera[1])
          end

          # The picture's check, worked out once for a picture shown frame after frame.
          def picture_check_of(shown)
            return @check_of_shown if shown.equal?(@shown_checked)

            @shown_checked = shown
            @check_of_shown = RunComparison.picture_check(shown)
          end

          # The emulator's 9-bit colours (red in the low three bits, then green, then blue) as the
          # 15-bit colours of the rest of the library, each channel's three bits widened to five.
          COLORS = Ractor.make_shareable(Array.new(512) do |color|
            red = Console::GenesisHardware.widen(color & 7)
            green = Console::GenesisHardware.widen((color >> 3) & 7)
            blue = Console::GenesisHardware.widen((color >> 6) & 7)
            red | (green << 5) | (blue << 10)
          end)

          # Where a painted screen's camera puts the view; [0, 0] until a painted screen is made.
          def read_camera
            return [0, 0] unless @places.runtime.key?(Runtime::Paint::CAMERA)

            at = runtime_place(Runtime::Paint::CAMERA)
            [half(at), half(at + 2)].map { |word| word >= 0x8000 ? word - 0x10000 : word }
          end

          # The sprites the game placed in its last pass, back to front, as the interpreter gives them
          # (Reference#sprites): the runtime keeps a row for each (Runtime::Tiles::DRAWN) — whose, which
          # picture, where — and SpriteNames turns the numbers back into names. A game with no
          # sprites keeps no such place.
          def read_sprites
            return [] unless @places.runtime.key?(Runtime::Tiles::DRAWN)

            at = runtime_place(Runtime::Tiles::DRAWN)
            signed = ->(value) { value >= 0x8000 ? value - 0x10000 : value }
            Array.new(half(at)) do |i|
              whose, picture, x, y = @core.wram_bytes(at + 2 + (i * Runtime::Tiles::DRAWN_BYTES), 8).unpack("n4")
              @drawn_sprites.row(signed.call(whose), @places.sprite_picture_names.fetch(picture, picture), signed.call(x),
                                 signed.call(y))
            end
          end

          # The Genesis's work RAM, read and written by address.
          def byte(address) = @core.wram_read8(address)
          def half(address) = @core.wram_read16(address)
          def read32(address) = @core.wram_read32(address)
          def write32(address, value) = @core.wram_write32(address, value)

          def state = half(runtime_place(Runtime::Frame::STATE))
          def waiting? = half(runtime_place(Runtime::Frame::WAITING)) == 1

          # FAULT: what went wrong (a word), the list's place (a long), and two numbers that show how
          # (a long each).
          def read_fault
            at = runtime_place(Runtime::Frame::FAULT)
            [half(at), read32(at + Runtime::Frame::FAULT_LIST), word(at + Runtime::Frame::FAULT_FIRST),
             word(at + Runtime::Frame::FAULT_SECOND)]
          end

          def console_fault_message(code, _first, _second)
            words = FAULT_WORDS[code] or return super

            raise CannotAnswer, "the Genesis cartridge stopped: #{words}"
          end

          # What stopped a cartridge, for the stops only a Genesis's runtime makes in these words.
          FAULT_WORDS = Ractor.make_shareable({
            CartridgeFaults::CPU_EXCEPTION => "the processor met something it cannot do (an odd address, a division " \
                                              "it cannot make, or an instruction it does not know)",
            CartridgeFaults::CELLS_FULL => "the game changed more than #{Runtime::Tiles::MOST_CELLS} cells of its " \
                                           "backgrounds in one pass, more than its queue for the blank holds",
            CartridgeFaults::CAMERA_TOO_FAR => "the game moved the camera past #{Runtime::Paint::CAMERA_ACROSS} pixels " \
                                               "across or #{Runtime::Paint::CAMERA_DOWN} down, further than a painted " \
                                               "screen can show on a Genesis"
          })
        end
      end
    end
  end
end
