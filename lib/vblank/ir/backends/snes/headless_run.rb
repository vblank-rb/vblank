# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # A Super Nintendo cartridge played in the emulator with nobody watching, driven and read back
        # through the calls a test makes on Backends::Reference (CartridgeHeadlessRun says how a pass
        # is read). Each frame starts with the vertical blank before it, and stops as the next blank
        # begins, so a pass's picture is copied to the console at the start of the frame that shows
        # it. What is the Super Nintendo's own: its work RAM read by offset, the sound log the
        # cartridge keeps and the sound unit's registers, the recordings sounding, a picture held
        # within a step for a see-through layer, and a run of no frames ending before the screen is
        # on.
        class HeadlessRun < CartridgeHeadlessRun
          # A PICTURE HELD WITHIN A STEP OF EACH CHANNEL, the picture of a Moment for a game with a
          # layer half see-through (Lowering::Picture#refuse_unmade_see_through!). The console adds
          # the two sides' 5-bit channels and halves the sum; the interpreter widens both to eight
          # bits, mixes them and narrows the mix back, which comes out a step higher for some pairs
          # (31 over 30 among them). So a pixel the interpreter mixed is held within a step of each
          # channel, and every other pixel exactly: the step belongs to the mix, and a fade or a
          # colour a step out anywhere else is a fault. A layer shown whole where it should be
          # halved, a pixel out of place or a wrong colour is many steps out. The pixels are kept
          # packed, two bytes each, as a check number reads them (RunComparison.picture_check).
          # +mixed+, on the interpreter's side only, is a byte a pixel: 1 where it mixed.
          #
          # Two pictures a step apart are equal, so all that #hash can say of a picture is its size.
          NearPicture = Data.define(:packed, :mixed) do
            def self.of(shown, mixed = nil) = new(packed: shown.pack("v*"), mixed: mixed&.pack("C*"))

            # Whether two 15-bit colours are within a step of each other in each channel.
            def self.within_one_step?(mine, theirs) = [0, 5, 10].all? { |at| (((mine >> at) & 31) - ((theirs >> at) & 31)).abs <= 1 }

            def ==(other)
              return false unless other.is_a?(NearPicture) && other.packed.bytesize == packed.bytesize
              return true if other.packed == packed

              near = mixed || other.mixed
              return false unless near

              packed.unpack("v*").zip(other.packed.unpack("v*"), near.bytes).all? do |mine, theirs, was_mixed|
                mine == theirs || (was_mixed == 1 && NearPicture.within_one_step?(mine, theirs))
              end
            end

            alias_method :eql?, :==

            def hash = packed.bytesize.hash

            # The check number the picture has held exactly, for #torn_frames.
            def check = Zlib.crc32(packed)
          end

          # What a Moment holds of the picture +shown+: its check number, or for a game with a
          # see-through layer (+near+) the picture itself (NearPicture), with which pixels were
          # +mixed+ where the interpreter says.
          def self.moment_picture(shown, near, mixed = nil) = near ? NearPicture.of(shown, mixed) : RunComparison.picture_check(shown)

          # Whether +program+'s pictures are held within a step (NearPicture).
          def self.near_pictures?(program) = !SeeThrough.layers(program).empty?

          # +watch_picture+ reads the picture after every frame the console draws, not only at the end
          # of each pass, to say which were all black (#black_frames). It is a whole screen read each
          # frame, so only a test that asks for it pays for it.
          def initialize(save: SaveImage.new, watch_picture: false)
            super(save: save)
            @watch_picture = watch_picture
          end

          # For a run made with +watch_picture+: the block is handed every frame the console draws,
          # as its pixels in rows, for a test of a frame that falls between two passes.
          def each_frame_drawn(&block)
            @frame_watcher = block
            self
          end

          # A Super Nintendo cartridge has no rumble motor, so it never runs (Reference#motor_on?).
          def motor_on? = false

          # The sound log up to the moment the run ended, or the one at the frame boundary a watching
          # block is asked at, in the interpreter's words (the build's sound_entries, by the number the
          # cartridge's own log keeps: Runtime::Sound, read as Music.interpreter_entry). It is the
          # test's to clear as it watches, as the interpreter's is: what comes after is added to what
          # the test left.
          def audio
            @audio.concat(in_interpreter_words(@logged_entries[@audio_handed...@sounds])) if @sounds > @audio_handed
            @audio_handed = [@audio_handed, @sounds].max
            @audio
          end

          # The sound log up to the moment the run ended, every entry, whatever a test did to #audio.
          def audio_played = in_interpreter_words(@logged_entries.take(@sounds))

          # Every entry the cartridge logged, past where the run ended too.
          def whole_audio = in_interpreter_words(@logged_entries)

          # Every entry the cartridge logged, as it logged them: the same as #whole_audio but that a
          # stop names the tune it stopped ([:stop_music, name], Music.stop_entry), which the
          # interpreter's log does not say and the writes the stop means depend on.
          def audio_as_logged = @logged_entries.dup

          # The S-DSP's 128 registers as the emulator held them each time the game was found waiting
          # at a pass's end, each with how many entries the sound log held then: [entries, registers],
          # oldest first — what the sound unit was really told, for a checked run to hold to the
          # interpreter's sound log as far as those entries (DSPWrites.after). Empty for a game that
          # makes no sound.
          attr_reader :dsp_reads

          # The registers as the run ended.
          def dsp_registers = @dsp_reads.last&.last

          # The registers this moment, for a test watching from #each_vblank. #dsp_registers keeps only
          # what it read with the sound queue empty, and a tune striking chords can keep the queue full
          # for many frames while the chip goes on changing.
          def live_dsp_registers = @core.dsp_registers

          # The recordings sounding as the run ended, in the order of their places, as the
          # interpreter says them (Reference#active_samples): the cartridge's own count
          # (Runtime::Recordings), heard or not.
          def active_samples = (@sounding || []).map(&:first)

          # How far through its shape the first place sounding recording +name+ is, out of
          # Audio::Envelope::FULL, at the same moment as #active_samples (Reference#level_of): FULL
          # for one with no shape. Nil when none sounds it.
          def level_of(name) = (@sounding || []).find { |sounding, _| sounding == name }&.last

          # Whose each place sounding a recording was as the run ended, in the order of the places
          # (Reference#sound_owners): :game for the game's own, [:song, part] for a song's recorded
          # part (its place among the song's recorded parts), [effect, part] for a sound effect's.
          def sound_owners = @owners || []

          # The plays and notes that found every place busy, and the most places songs held at one of
          # those moments (Reference#sound_drops), as the cartridge had counted them at the moment the
          # run ended or a watching block asks at.
          def sound_drops
            dropped, held = @drops || [0, 0]
            Diagnostics::SoundDrops::Reading.new(dropped: dropped, music_held: held, voices: Runtime::Recordings::PLACES)
          end

          # The sound unit's 64K of memory as the run ended — its program, the sample table and the
          # recordings — for a test to read a recording the DSP plays. Nil for a game with no sound.
          attr_reader :apu_ram

          # WHAT WAS HEARD: the loudest sample bsnes played in each screen frame from power-on, left
          # or right, as a number from 0 to 32768. The registers say what the sound unit was told
          # at the end of each pass; this says what came out between, so a test can measure a
          # sound's shape — a rest's silence, a fade's length — where the registers cannot see it.
          # Taking it every frame also keeps the emulator from holding every sample of the run.
          # A frame is the finest it sees: what happens inside one is not in it.
          attr_reader :loudest_each_frame

          # For a run made with +watch_picture+: the frames the console drew all black after the
          # first it drew anything, counted from nought. The interpreter has no frame between two
          # passes to compare with, so a black frame there — the screen switched off to copy a big
          # change to video RAM — is what the checked run never sees and a player does.
          def black_frames
            first_lit = @black_each_frame.index(false) || @black_each_frame.size
            (first_lit...@black_each_frame.size).select { |frame| @black_each_frame[frame] }
          end

          # For a run made with +watch_picture+: the frames the console drew, after the first it drew
          # anything, that show no pass's whole picture — a pass's change half copied, or its colours
          # sent before its tiles. A pass's picture is the one read once the pass was shown, as the
          # checked run holds it to the interpreter's; every frame between two passes is the first
          # of them or the second, unless the copy between is seen arriving.
          def torn_frames
            whole = @moments.map { |moment| moment.picture.is_a?(NearPicture) ? moment.picture.check : moment.picture }
            first_lit = @black_each_frame.index(false) || @black_each_frame.size
            (first_lit...@picture_each_frame.size).reject { |frame| whole.include?(@picture_each_frame[frame]) }
          end

          # The Advance's mix, a stream of sound its processor makes from every recording: a Super
          # Nintendo plays each recording on a voice of its sound chip, and makes no such stream.
          def mixed_sound
            raise CannotAnswer, "a Super Nintendo plays each recording on a voice of its own sound chip, so it has no " \
                                "mixed sound to read."
          end

          # The rest of what the interpreter answers, each refused by name.
          refuses :clock_at

          private

          def kit = Console.for(:snes)

          def start_run(program)
            @near = HeadlessRun.near_pictures?(program)
            @logged_entries = []
            @sounds = 0
            @audio = []
            @audio_handed = 0
            @dsp_reads = []
            @apu_ram = nil
            @sounding = nil
            @drops = nil
            @owners = nil
            @loudest_each_frame = []
            @black_each_frame = []
            @picture_each_frame = []
          end

          def power_on = set_buttons(@held)

          # The buttons a game names, on the controller's: the same names, A, B, the shoulders L and R.
          def set_buttons(buttons)
            first, second = Buttons.by_controller(buttons.map(&:to_sym))
            @core.set_buttons(first)
            @core.set_buttons(second, port: 1)
          end

          # A pass's moment waits for the count of its sounds (#sounds_counted?), but for the moment
          # the run ends on.
          def moment_ready?(pass, frames) = pass > frames || sounds_counted?(pass)

          # A RUN OF NO FRAMES ends as the first pass does, before anything is shown: the screen is
          # still switched off (Runtime::Frame turns it on as the first pass is shown). The interpreter
          # says a display switched off as a plain white picture (Reference::Framebuffer::HELD_OFF),
          # so that is the picture the run ends on, and the game goes no further.
          def ends_before_first_picture?(frames) = frames.zero?

          def end_before_first_picture(variables, lists, sprites, sounds, camera)
            hold_after_this_pass
            @sprites = sprites
            off = Array.new(@core.width * @core.height, Reference::Framebuffer::HELD_OFF)
            record_moment(:end, variables, lists, Picture.new(shown: off, width: @core.width, height: @core.height,
                                                              camera_x: camera[0], camera_y: camera[1]), sounds)
          end

          # FRAME 1 CAN BE READ BEFORE IT IS DECIDED. An emulated frame ends as the console starts its
          # vertical blank, and the blank's interrupt reads the controller as it starts — so a first
          # pass that ends late in a frame finds that frame's interrupt, frame 1's, taken before the
          # emulator stops and the pass is seen to be over: frame 1 read the buttons held from
          # power-on. Writing the right ones into the game's memory afterwards would hide a fault in
          # the very routine that reads them, so the frame is found first: a copy of the game is
          # played as far as the end of its first pass, on a console of its own, and the real one
          # is handed frame 1's buttons before that frame runs. Only a game told its buttons a frame
          # at a time needs the copy: any other holds the same ones from power-on. The block saying
          # them is asked for a frame's once, and only when that frame comes, since a test's block
          # can count from the first frame it is asked about.
          def play(frames)
            @frames_played = 0
            @frame_one_at = @input_script ? frame_first_pass_ended : nil
            super
          end

          # How many emulated frames the game takes to be found waiting at the end of its first
          # pass, played on a copy of the save memory, so the real run starts from what this one did.
          def frame_first_pass_ended
            Diagnostics::Emulator.with_cartridge(@rom, file_name: "game#{kit.description.extension}",
                                                       save: (@save.dup if SaveLayout.named_by?(@rom.built.source_program))) do |core|
              @core = core
              power_on
              ended_at = (1..LONGEST_PASS_FRAMES).find do
                core.run_frame
                state != Runtime::Frame::RUNNING || (waiting? && passes >= 1)
              end
              ended_at if frame_one_read_early?
            ensure
              @core = nil
            end
          end

          # Has the blank that reads frame 1 come, with the first pass ended and nothing shown? A
          # game that takes several frames to set up has not read frame 1 yet at all.
          def frame_one_read_early? = word(runtime_place(Runtime::Frame::FRAMES)) == 1 && shown_pass.zero?

          # Frame 1 was handed over in time, so it is not decided again.
          def first_pass_ended
            @decided = 1 if @deciding && frame_one_read_early?
          end

          # The moment of +frame+ — a pass's number, or :end for the moment the run ended on. +sounds+
          # is how many entries the sound log held as the game was found waiting (#read_sounds).
          #
          # A PASS'S SOUNDS INCLUDE ITS FRAME BOUNDARY'S MUSIC, which the interpreter plays after the
          # pass, before anything reads the frame (Reference#advance_frame). The cartridge plays it
          # where the wait ends (Runtime::Music), after the game was found waiting, so a pass's moment
          # takes the count the cartridge kept as that wait ended (Runtime::Sound::LOGGED_BY_PASS),
          # which #play_passes waits for (#sounds_counted?). The moment the run ended on has no
          # boundary after it.
          def record_moment(frame, variables, lists, picture, sounds)
            @vars = variables
            @lists = lists
            @screen = picture
            @sounds = frame == :end || !sound? ? sounds : logged_by_pass(frame)
            read_sound_entries(@sounds) if sound?
            @apu_ram = @core.apu_ram if frame == :end && sound?
            @sounding = recordings_at(frame)
            @drops = drops_now
            @owners = owners_now if frame == :end
            @moments << Moment.new(frame: frame, variables: variables, picture: HeadlessRun.moment_picture(picture.shown, @near),
                                   sounds: @sounds, sprites: @sprites, collections: game_state.except(:vars),
                                   sounding: active_samples.map { |name| [name, level_of(name)] })
            @on_vblank&.call(frame) unless frame == :end
          end

          # How many entries the cartridge's sound log holds now, those read into the log in the
          # interpreter's words, and the S-DSP's registers kept beside the count (#dsp_reads); 0 for
          # a game that makes no sound.
          def read_sounds
            return 0 unless sound?

            logged = half(runtime_place(Runtime::Sound::LOGGED))
            read_sound_entries(logged)
            @dsp_reads << [logged, @core.dsp_registers] unless sound_writes_waiting?
            logged
          end

          def sound? = @places.runtime.key?(Runtime::Sound::LOGGED)

          # Whether writes the log already counts are still queued for the sound unit, when its
          # registers cannot be held to the log yet.
          def sound_writes_waiting?
            sound = Runtime::Sound
            @places.runtime.key?(sound::QUEUE) && half(runtime_place(sound::QUEUE_HEAD)) != half(runtime_place(sound::QUEUE_TAIL))
          end

          # The recordings the cartridge's places held at the moment of +frame+, each [name, level], in
          # the order of their places: as the pass's wait ended (Runtime::Recordings::KEPT_BY_PASS and
          # LEVELS_BY_PASS), the interpreter's mix at that frame boundary, or as they are now for the
          # moment the run ended. None for a game that plays none.
          def recordings_at(frame)
            recordings = Runtime::Recordings
            return [] unless @places.runtime.key?(recordings::PLACES_STATE)

            held = if frame == :end
                     state = runtime_place(recordings::PLACES_STATE)
                     Array.new(recordings::PLACES) do |place|
                       at = state + (place * recordings::PLACE_BYTES)
                       [half(at), half(at + recordings::LEVEL)]
                     end
                   else
                     slot = (frame % Runtime::Frame::STEPS_KEPT) * recordings::PLACES
                     names = runtime_place(recordings::KEPT_BY_PASS) + slot
                     levels = runtime_place(recordings::LEVELS_BY_PASS) + slot
                     Array.new(recordings::PLACES) { |place| [byte(names + place), byte(levels + place)] }
                   end
            held.reject { |number, _| number.zero? }.map { |number, level| [@places.recording_names.fetch(number - 1), level] }
          end

          # Whose each held place is now, in the interpreter's words (#sound_owners), from each place's
          # OWNER (Runtime::Recordings: nought, a song's part one up, or a sound effect's number one up
          # in the high byte over its part one up).
          def owners_now
            recordings = Runtime::Recordings
            return [] unless @places.runtime.key?(recordings::PLACES_STATE)

            state = runtime_place(recordings::PLACES_STATE)
            Array.new(recordings::PLACES) { |place| state + (place * recordings::PLACE_BYTES) }
                 .reject { |at| half(at + recordings::HELD).zero? }
                 .map do |at|
                   owner = half(at + recordings::OWNER)
                   if owner.zero? then :game
                   elsif owner < recordings::EFFECT_OWNER then [:song, owner - 1]
                   else [@places.sound_voicing.effects.fetch((owner >> 8) - 1), (owner & 0xFF) - 1]
                   end
                 end
          end

          # The cartridge's count of drops now (Runtime::Recordings::DROPS and DROPS_MUSIC); none for a
          # game that plays no recording.
          def drops_now
            recordings = Runtime::Recordings
            return [0, 0] unless @places.runtime.key?(recordings::DROPS)

            [half(runtime_place(recordings::DROPS)), half(runtime_place(recordings::DROPS_MUSIC))]
          end

          # How many entries the sound log held as pass +pass+'s wait ended.
          def logged_by_pass(pass) = half(logged_slot(pass) + 2)

          # Whether the cartridge has kept that count for +pass+ yet: its slot carries the pass's
          # number. True for a game that makes no sound.
          def sounds_counted?(pass) = !sound? || half(logged_slot(pass)) == (pass & 0xFFFF)

          def logged_slot(pass)
            runtime_place(Runtime::Sound::LOGGED_BY_PASS) +
              ((pass % Runtime::Frame::STEPS_KEPT) * Runtime::Sound::LOGGED_SLOT_BYTES)
          end

          # The cartridge's sound log read into the interpreter's words as far as +logged+ entries.
          def read_sound_entries(logged)
            if logged - @logged_entries.size > Runtime::Sound::LOG_LENGTH
              raise CannotAnswer, "the Super Nintendo cartridge logged more than #{Runtime::Sound::LOG_LENGTH} sounds in " \
                                  "one pass, more than its sound log holds"
            end

            ring = runtime_place(Runtime::Sound::LOG)
            (@logged_entries.size...logged).each do |count|
              @logged_entries << @places.sound_entries.fetch(half(ring + ((count % Runtime::Sound::LOG_LENGTH) * 2)))
            end
          end

          def in_interpreter_words(entries) = entries.map { |entry| Music.interpreter_entry(entry) }

          # The game halted: its picture shown once more (a painted screen's copied over several
          # blanks, Runtime::Paint); the moment is the end of the run.
          def finish_after_halt
            (1..passes).last(Runtime::Frame::STEPS_KEPT).each { |pass| note_frames_took(pass) unless @frames_took.key?(pass) }
            frames = 0
            until shown_pass == Runtime::Frame::END_SHOWN || frames > LONGEST_PASS_FRAMES
              play_frame
              frames += 1
            end
            play_frame
            @sprites = read_sprites
            record_moment(:end, read_variables, read_lists, picture_now(read_camera), read_sounds)
          end

          def play_frame
            @frames_played += 1
            set_buttons(Array(@input_script.call(1))) if @frames_played == @frame_one_at
            decide_buttons
            @core.run_frame
            @loudest_each_frame << (@core.take_audio.map(&:abs).max || 0)
            return unless @watch_picture

            colors = @core.colors
            @black_each_frame << colors.none?(&:positive?)
            @picture_each_frame << RunComparison.picture_check(colors)
            @frame_watcher&.call(colors)
          end

          # The emulator's picture, each pixel the 15-bit colour the console holds, and where the
          # camera put the view, [x, y], as the pass left it.
          def picture_now(camera) = Picture.new(shown: @core.colors, width: @core.width, height: @core.height,
                                                camera_x: camera[0], camera_y: camera[1])

          # Where a painted screen's camera puts the view, as the game gave it (Runtime::Paint's
          # CAMERA); [0, 0] for a screen with no camera.
          def read_camera
            return [0, 0] unless @places.runtime.key?(Runtime::Paint::CAMERA)

            at = runtime_place(Runtime::Paint::CAMERA)
            [word(at + Runtime::Paint::CAMERA_X), word(at + Runtime::Paint::CAMERA_Y)]
          end

          # The sprites the game placed in its last pass, back to front, as the interpreter says them
          # (Reference#sprites): the runtime keeps a row for each (Runtime::Picture::DRAWN) — whose,
          # which picture, where — and SpriteNames turns the numbers back into names.
          def read_sprites = @places.drawn_sprite_rows(@drawn_sprites, method(:half))

          # The game's memory, work RAM or the Super FX chip's, by the address its code uses
          # (Diagnostics::SNESMemory, which the finished-cartridge reader reads through too).
          def byte(address) = Diagnostics::SNESMemory.read8(@core, address)
          def half(address) = Diagnostics::SNESMemory.read16(@core, address)
          def read32(address) = Diagnostics::SNESMemory.read32(@core, address)
          def write32(address, value) = @core.wram_write32(Diagnostics::SNESMemory.work_ram_offset(address), value)

          def state = half(runtime_place(Runtime::Frame::STATE))
          def waiting? = half(runtime_place(Runtime::Frame::WAITING)) == 1

          # FAULT: what went wrong (a word), the list's place (three bytes and a spare), and two
          # numbers that say how (four bytes each).
          def read_fault
            at = runtime_place(Runtime::Frame::FAULT)
            [half(at), read32(at + Runtime::Frame::FAULT_LIST) & 0xFFFFFF, word(at + Runtime::Frame::FAULT_FIRST),
             word(at + Runtime::Frame::FAULT_SECOND)]
          end

          def console_fault_message(code, first, second)
            return super unless code == CartridgeFaults::CELLS_FULL

            raise CannotAnswer, "the Super Nintendo cartridge stopped: the game changed more than " \
                                "#{Runtime::Picture::MOST_CELLS} cells of its backgrounds in one pass, more than its " \
                                "queue for the blank holds"
          end
        end
      end
    end
  end
end
