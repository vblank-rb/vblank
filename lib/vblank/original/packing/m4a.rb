# frozen_string_literal: true

module VBlank
  module Original
    module Packing
      # THE ADVANCE'S COMMON SOUND DRIVER, MusicPlayer2000 (the "m4a" library; "Sappy" to rippers),
      # read from the copy into what a song of the pack is: the notes of each part as
      # Original::PackNote records, the song's length and where it comes round, and each recording
      # and its settings. Most Advance games keep their music in this driver, so these are offered
      # with the Advance's other formats:
      #
      #   copy.unpack_m4a_track at: SONG, into: pack[:title_0], track: 0           # one track's notes
      #   copy.unpack_m4a_track at: SONG, into: pack[:drums], track: 6, kind: 4    # ...on one voice only
      #   copy.unpack_m4a_track at: SONG, into: pack[:beat], track: 5, kit_from: 8 # ...a kit's keys from 8
      #   copy.unpack_m4a_length at: SONG, into: pack[:title_length]               # length, loop frame
      #   copy.unpack_m4a_recording at: VOICE, into: pack[:piano]                  # a recording's samples
      #   copy.unpack_m4a_voice at: VOICE, into: pack[:piano_settings]             # its rate, hold (or none), length, envelope
      #   copy.unpack_m4a_voice at: WAVE_VOICE, into: pack[:pattern]               # the wave voice's pattern, sixteen bytes
      #   copy.unpack_m4a_voiced_track at: SONG, into: pack[:lead], track: 1       # notes with their voices' settings
      #
      # SONG is where the song's header is in the copy, and VOICE where a voice's twelve bytes are (the
      # song's voice group, then 12 bytes a voice, or a voice of a drum kit or key split; a routine
      # works these out with `copy.word`, each a cartridge address, 0x08000000 the copy's first byte).
      # A port that keeps its songs another way writes its own unpacking (original.md), and nothing
      # here is in the song model, the IR or a runtime: this is game code that writes records.
      #
      # THE ANSWER KEY is the driver's own source, as the decompilations of Advance games have it
      # (tmc and pokeemerald: asm/lib/m4a_asm.s, MPlayMain, ply_note, ChnVolSetAsm and the ply_
      # commands; src/gba/m4a.c, MPlayStart, TrkVolPitSet, MidiKeyToCgbFreq, CgbPan, CgbModVol, the
      # tables and ply_memacc), and test/m4a_answers.rb is a decoder written from it.
      #
      # TIME IS IN FRAMES. The driver adds the tempo (beats a minute, times 2) to a count each frame
      # and plays a tick of every track each time the count reaches 150, keeping what is left; a song
      # starts at 150, a tick a frame, and its first tick plays on its first frame. So a tick lands on a
      # frame no fixed tick rate gives, and every track is walked tick by tick, since a TEMPO in any
      # track moves all of them. Each record's tick is that frame, from the song's start, and its
      # length the frames to the tick that lets it go; the song's Score plays a tick a frame
      # (`tempo: 3600, ticks_per_beat: 1`).
      #
      # A SONG ENDS where its first track to jump back does (GOTO, or REPT with no count): that
      # tick's frame is its length, and the frame of the tick that track first reached the place it
      # jumps to is where it comes round. A song no track jumps back in ends when its last track
      # ends (FINE), and has no loop frame (NO_LOOP). A song whose tracks come round at different
      # ticks is cut where the first does.
      #
      # EACH NOTE, as ply_note strikes it: its voice is the track's (VOICE), or for a drum kit the
      # kit's voice of the note's key, and for a key split the split's voice its table names for the
      # key; a split or kit inside one plays nothing. Its key is the note's key (a drum kit's: its
      # voice's own) moved by KEYSH, and by TUNE and BEND times BENDR in whole keys as TrkVolPitSet
      # works them out (what is left of a key, and a bend while the note sounds, are not kept). Its
      # loudness is the note's velocity and the track's VOL and PAN, as ChnVolSetAsm works out its
      # two sides:
      #
      # - On a recording (DirectSound): the instrument byte is a number for the voice (THE
      #   INSTRUMENT BYTE, below); a voice whose recording is played at a fixed rate is key 60; the
      #   loudness is the two sides added, in 512ths, as the mixer adds them. A recording plays from
      #   both speakers, so PAN moves nothing here (the song model has no pan on a recorded part).
      # - On the console's voices: the volume is the two sides added over 16, at most 15 (CgbModVol),
      #   and the speaker is the side that is twice the other or more, else both (CgbPan). A square or
      #   wave note under key 36 is key 36 (MidiKeyToCgbFreq); a noise note's clock is the driver's
      #   table entry for its key (gNoiseTable).
      #
      # `kind:` keeps only the notes of one kind of voice: KIND_RECORDING, 1 or 2 for the squares, 3
      # for the wave, 4 for the noise, ANY_KIND (the default) for all. A track that drums on recordings
      # and on the noise voice at once is two parts, one each.
      #
      # THE INSTRUMENT BYTE names which of the part's instruments a recorded note plays, so one track
      # that changes VOICE must give each voice it plays a number of its own. A voice the track
      # names itself is its number in the song's voice group, VOICE's byte, 0 to 127. A drum kit
      # numbers its voices by key and a key split by its own table's entry, each from 0 as the group
      # does, so each is moved to a range of its own: a kit's voice for key k is `kit_from:` + k, and
      # a split's entry e is `split_from:` + e, both 128 (KIT_AND_SPLIT_NUMBERS_FROM) unless the port sets
      # them. So by default a track of plain voices and one kit, or plain voices and one split,
      # cannot give two voices one number; a track that plays a kit and a split, or two kits, sets
      # one of them apart. A port sets them lower to keep a part's list short: its instruments: list
      # has an entry for every number up to the highest it plays, with no gaps, so a track of
      # the group's voices 0 to 7 and a kit's keys 36 to 40 reads best with `kit_from: 8 - 36`, the
      # kit's keys then 8 to 12. A number past 254 or under 0 is written 255, the part's own
      # instrument. A key split's or a kit's voice is the same twelve bytes as the group's, so
      # unpack_m4a_recording and unpack_m4a_voice read it where the kit's or split's voices are (the
      # second word of its entry in the group) plus 12 a key, or 12 an entry.
      #
      # WHAT IS NOT KEPT, since the song model has no place for it: a VOL, PAN, BEND or TUNE while a
      # note sounds (each note keeps what it was struck with); LFOS, LFODL, MOD and MODT (vibrato);
      # PRIO and which notes the driver's channels drop when too many sound; XCMD's changes to the
      # track's voice; PORT's sound register writes; a console voice's length byte, which cuts its
      # notes short. A console voice's own settings are read by unpack_m4a_voiced_track into a slot of
      # `voiced_notes`, each note with its voice's duty, slide and fade (Walk#emit_voice_settings
      # says how the driver's envelope is matched), and the wave voice's pattern by unpack_m4a_voice;
      # unpack_m4a_track leaves them to the part. A track sounds one note at a time as a
      # part, so of two struck on one frame the part plays the later. More than MOST_SOUNDING notes of
      # one track sounding at once: the later ones last until the next note. With `kind:`, EOT lets go
      # of the newest kept note on its key, where the driver looks at all of the track's.
      #
      # THE LOOP IS THE FIRST PASS'S. The song comes round to the frame its loop point was first
      # reached on, and plays the first pass again. A song whose second pass differs from its first
      # (MEMACC counting passes, the tempo's leftover count moving a later tick by a frame) is played
      # as its first.
      module M4A
        # The bits of a cartridge address that are a place in the copy, 0x08000000 its first byte.
        ADDRESS_BITS = 0x01FF_FFFF
        MOST_TRACKS = 16
        # The count each tick takes from the tempo's, and a song's tempo before its first TEMPO.
        TEMPO_COUNT_PER_TICK = 150
        STARTING_TEMPO = 150
        # The most frames a song is walked for: a record's tick and length are two bytes.
        MOST_FRAMES = 0xFFFE
        # The most ticks one frame can play (a tempo of 255 adds 510), and the most commands one
        # track can read before it waits.
        MOST_TICKS_A_FRAME = 4
        MOST_COMMANDS_A_TICK = 256
        # The most notes of the walked track kept sounding at once, to be given their lengths.
        MOST_SOUNDING = 16
        MOST_PATTERN_LEVELS = 3
        MEMACC_BYTES = 256
        VOICE_BYTES = 12

        KIND_RECORDING = 0
        KIND_FIRST_SQUARE = 1
        KIND_SECOND_SQUARE = 2
        KIND_WAVE = 3
        KIND_NOISE = 4
        ANY_KIND = 255
        # The loop frame of a song that ends (unpack_m4a_length).
        NO_LOOP = 0xFFFF

        # The commands (MPlayMain; gMPlayJumpTable as MPlayExtender sets it). Each code from FINE
        # to EOT is a command; below them a wait, above them a note.
        WAIT = 0x80
        FINE = 0xB1
        GOTO = 0xB2
        PATT = 0xB3
        PEND = 0xB4
        REPT = 0xB5
        MEMACC = 0xB9
        PRIO = 0xBA
        TEMPO = 0xBB
        KEYSH = 0xBC
        VOICE = 0xBD
        VOL = 0xBE
        PAN = 0xBF
        BEND = 0xC0
        BENDR = 0xC1
        LFOS = 0xC2
        LFODL = 0xC3
        MOD = 0xC4
        MODT = 0xC5
        TUNE = 0xC8
        PORT = 0xCC
        XCMD = 0xCD
        EOT = 0xCE
        TIE = 0xCF
        # The commands that read one byte and keep nothing the records hold.
        DROPPED_ONE_BYTE = [PRIO, LFOS, LFODL, MOD, MODT].freeze
        # A byte below this repeats the command before it, from VOICE on (the running status).
        RUNNING_STATUS_FROM = VOICE
        # The middle of PAN, BEND and TUNE, and BENDR at a track's start.
        CENTER = 0x40
        STARTING_BEND_RANGE = 2
        STARTING_VOLUME_X = 64

        # A voice's kind (its first byte): a key split and a drum kit pick another voice; the low three
        # bits name the console voice (0 a recording); a recording at a fixed rate.
        KEY_SPLIT = 0x40
        DRUM_KIT = 0x80
        CONSOLE_VOICE_BITS = 7
        FIXED_RATE = 0x08
        # A voice of the squares or the wave plays no key under this (MidiKeyToCgbFreq).
        LOWEST_TONE_KEY = 36
        # The noise table's first key and its last entry (MidiKeyToCgbFreq).
        LOWEST_NOISE_KEY = 21
        NOISE_ENTRIES = 60
        # The key a recording at a fixed rate is written at, which an instrument names as its own.
        OWN_KEY = 60
        MOST_KEY = 127
        # The instrument number a drum kit's or a key split's first voice is given where the port
        # sets no kit_from: or split_from:, past the 128 voices a VOICE names (0 to 127).
        KIT_AND_SPLIT_NUMBERS_FROM = 128

        # gClockTable: the ticks of each wait and each note length.
        CLOCKS = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 28, 30, 32, 36, 40,
                  42, 44, 48, 52, 54, 56, 60, 64, 66, 68, 72, 76, 78, 80, 84, 88, 90, 92, 96].freeze

        # gNoiseTable: the noise register's setting for each key from LOWEST_NOISE_KEY, four dividers,
        # 7 down to 4, for each number of halvings from 13 down to 1, then every divider with none.
        NOISE_TABLE = [*13.downto(1).flat_map { |halvings| 7.downto(4).map { |divider| (halvings << 4) | divider } },
                       *7.downto(0).to_a].freeze

        # One sound driver's song, walked tick by tick as MPlayMain plays it, written as game code
        # into an unpacking routine. +block+ is the format's BlockKit. +lists+ keeps the lists the walk
        # reads, one set for each routine, made the first time a walk asks.
        #
        # +track+ (a setting) is the track whose notes are written, with +kind+ the kind of voice kept
        # and +kit_from+ and +split_from+ the instrument numbers a kit's and a split's first voice
        # are given; all four are nil for a walk that writes no notes. +watch+ is a walk that finds
        # where the song comes round: it stops on the tick the track +watch_track+ first reaches the
        # place +watch_place+, keeping that frame in +found_frame+.
        #
        # +voiced+ writes each record as a voiced Original::PackNote, with its console voice's own
        # settings from the voice's twelve bytes (VoicedTrack says which).
        class Walk
          def initialize(block, lists, track: nil, kind: nil, kit_from: nil, split_from: nil, watch: false, voiced: false)
            @block = block
            @lists = lists
            @track = track
            @kind = kind
            @kit_from = kit_from
            @split_from = split_from
            @watch = watch
            @voiced = voiced
          end

          def var(name) = @block.variable(:"m4a_#{name}")

          def list(name, capacity) = @lists[name] ||= @block.list(:"m4a_#{name}", capacity: capacity)

          def track_list(name) = list(name, MOST_TRACKS)

          def sounding_list(name) = list(name, MOST_SOUNDING)

          # A cartridge address read from the copy at +at+, as a place in the copy.
          def address_at(at) = M4A.word_at(@block, at) & ADDRESS_BITS

          # +value+ as a signed byte, into +into+.
          def emit_signed_byte(into, value)
            into.store!(value)
            into.store!(into - 256) if into >= 128
          end

          # The walk: every track from its start, a frame at a time, until the song ends.
          def emit
            emit_start
            ended = var(:ended)
            tempo_count = var(:tempo_count)
            tempo = var(:tempo)
            frame = var(:frame)
            ticking = var(:ticking)
            @block.repeat(MOST_FRAMES, stop_when: ended == 1) do
              tempo_count.store!(tempo_count + tempo)
              ticking.store!(0)
              ticking.store!(1) if tempo_count >= TEMPO_COUNT_PER_TICK
              @block.repeat(MOST_TICKS_A_FRAME, stop_when: ticking == 0) do
                emit_tick
                tempo_count.store!(tempo_count - TEMPO_COUNT_PER_TICK)
                ticking.store!(0) if tempo_count < TEMPO_COUNT_PER_TICK
                ticking.store!(0) if ended == 1
              end
              frame.increase!(1) if ended == 0
            end
            var(:end_frame).store!(frame)
            emit_release_all if @track
          end

          # MPlayStart and a track's first tick (MPlayMain, a track with MPT_FLG_START): the header
          # read, every track at its start.
          def emit_start
            emit_lists
            from = @block.from
            var(:ended).store!(0)
            var(:frame).store!(0)
            var(:tempo).store!(STARTING_TEMPO)
            var(:tempo_count).store!(0)
            var(:sequence).store!(0)
            var(:group).store!(address_at(from + 4))
            count = var(:track_count)
            count.store!(@block.byte(from))
            count.store!(MOST_TRACKS) if count > MOST_TRACKS
            clocks = list(:clocks, CLOCKS.length)
            CLOCKS.each_with_index { |ticks, at| clocks[at] = ticks }
            noise = list(:noise, NOISE_TABLE.length)
            NOISE_TABLE.each_with_index { |setting, at| noise[at] = setting }
            area = list(:memacc, MEMACC_BYTES)
            @block.repeat(MEMACC_BYTES) { |at| area[at] = 0 }
            @block.repeat(MOST_TRACKS) do |t|
              %i[wait status level repeats key velocity shift voice_number volume pan bend tune].each { |name| track_list(name)[t] = 0 }
              track_list(:place)[t] = 0
              track_list(:active)[t] = 0
              track_list(:voice)[t] = -1
              track_list(:bend_range)[t] = STARTING_BEND_RANGE
            end
            @block.repeat(count) do |t|
              track_list(:place)[t] = address_at(from + 8 + (t * 4))
              track_list(:active)[t] = 1
            end
            @block.repeat(MOST_SOUNDING) { |s| sounding_list(:used)[s] = 0 }
          end

          # Every list the walk reads, made before any of it runs: a list is made where it is first
          # asked for, and one first asked for in a branch would be made only when that branch runs.
          def emit_lists
            TRACK_LISTS.each { |name| track_list(name) }
            SOUNDING_LISTS.each { |name| sounding_list(name) }
            list(:stack, MOST_TRACKS * MOST_PATTERN_LEVELS)
          end

          TRACK_LISTS = %i[place wait status active level repeats key velocity shift voice voice_number volume pan bend
                           bend_range tune].freeze
          SOUNDING_LISTS = %i[used gate key record start sequence].freeze

          # One tick of every track, in order (MPlayMain), and the song's end once none plays on. A
          # track counts as playing on a tick it starts playing, so the song stops on the tick after
          # its last track's FINE, as the driver stops it.
          def emit_tick
            playing = var(:playing)
            playing.store!(0)
            active = track_list(:active)
            @block.repeat(var(:track_count), stop_when: var(:ended) == 1) do |t|
              if active[t] == 1
                playing.store!(1)
                emit_gates if @track && t == @track
                emit_commands(t)
                track_list(:wait)[t] = track_list(:wait)[t] - 1 if active[t] == 1
              end
            end
            emit_song_end if playing == 0
          end

          def emit_song_end
            var(:ended).store!(1)
          end

          # Each note of the walked track whose length runs out on this tick is let go (MPlayMain
          # counts every channel's gate down before the track reads).
          def emit_gates
            used = sounding_list(:used)
            gate = sounding_list(:gate)
            @block.repeat(MOST_SOUNDING) do |s|
              if used[s] == 1 && gate[s] > 0
                gate[s] = gate[s] - 1
                emit_release(s) if gate[s] == 0
              end
            end
          end

          # The commands of track +t+ until it waits or ends (MPlayMain): a byte under 0x80 repeats
          # the command before it.
          def emit_commands(t)
            reading = var(:reading)
            place = var(:at)
            command = var(:command)
            byte = var(:byte)
            wait = track_list(:wait)
            active = track_list(:active)
            reading.store!(0)
            reading.store!(1) if wait[t] == 0
            @block.repeat(MOST_COMMANDS_A_TICK, stop_when: reading == 0) do
              place.store!(track_list(:place)[t])
              emit_watch(t) if @watch
              byte.store!(@block.byte(place))
              if byte < WAIT
                command.store!(track_list(:status)[t])
              else
                command.store!(byte)
                place.increase!(1)
                track_list(:status)[t] = byte if byte >= RUNNING_STATUS_FROM
              end
              if command < WAIT
                emit_fine(t) # a byte under 0x80 with no command before it: the driver reads past its table
              elsif command >= TIE
                emit_note(t, command - TIE)
              elsif command >= FINE
                emit_command(t, command)
              else
                wait[t] = list(:clocks, CLOCKS.length)[command - WAIT]
              end
              track_list(:place)[t] = place
              reading.store!(0) if wait[t] != 0 || active[t] == 0 || var(:ended) == 1
            end
          end

          # The watching walk stops where the track it watches first reads the place it jumps to.
          def emit_watch(t)
            if t == var(:watch_track) && var(:at) == var(:watch_place)
              var(:found_frame).store!(var(:frame))
              emit_song_end
            end
          end

          # A command of FINE to EOT: what each does to the track (the ply_ routines).
          def emit_command(t, command)
            place = var(:at)
            arg = var(:arg)
            arg.store!(@block.byte(place))
            if command == GOTO
              emit_jump_back(t, place)
            elsif command == PATT
              emit_pattern(t)
            elsif command == PEND
              level = track_list(:level)
              if level[t] > 0
                level[t] = level[t] - 1
                place.store!(list(:stack, MOST_TRACKS * MOST_PATTERN_LEVELS)[(t * MOST_PATTERN_LEVELS) + level[t]])
              end
            elsif command == REPT
              emit_repeat(t)
            elsif command == MEMACC
              emit_memacc
            elsif command == TEMPO
              var(:tempo).store!(arg * 2)
              place.increase!(1)
            elsif command == KEYSH
              emit_signed_byte(var(:signed), arg)
              track_list(:shift)[t] = var(:signed)
              place.increase!(1)
            elsif command == VOICE
              track_list(:voice_number)[t] = arg
              track_list(:voice)[t] = var(:group) + (arg * VOICE_BYTES)
              place.increase!(1)
            elsif command == VOL
              track_list(:volume)[t] = arg
              place.increase!(1)
            elsif command == PAN
              track_list(:pan)[t] = arg - CENTER
              place.increase!(1)
            elsif command == BEND
              track_list(:bend)[t] = arg - CENTER
              place.increase!(1)
            elsif command == BENDR
              track_list(:bend_range)[t] = arg
              place.increase!(1)
            elsif command == TUNE
              track_list(:tune)[t] = arg - CENTER
              place.increase!(1)
            elsif command == PORT
              place.increase!(2)
            elsif command == XCMD
              emit_xcmd(t)
            elsif command == EOT
              emit_end_of_tie(t)
            elsif dropped_command_test(command)
              place.increase!(1)
            else
              emit_fine(t)
            end
          end

          # The test the routine makes of whether +command+ is one of DROPPED_ONE_BYTE.
          def dropped_command_test(command)
            DROPPED_ONE_BYTE.map { |code| command == code }.reduce { |either, test| either | test }
          end

          # FINE (ply_fine): the track stops, and lets go of its notes.
          def emit_fine(t)
            track_list(:active)[t] = 0
            emit_release_all if @track && t == @track
          end

          # GOTO (ply_goto) to the address at +place+. One back is the song's end: where it jumps to
          # is kept for the walk that watches for it, and the walk stops on this tick. One forward is
          # only a jump.
          def emit_jump_back(t, place)
            target = var(:target)
            target.store!(address_at(place))
            if target < place
              if var(:jumped) == 0
                var(:jumped).store!(1)
                var(:watch_track).store!(t)
                var(:watch_place).store!(target)
              end
              emit_song_end
            else
              place.store!(target)
            end
          end

          # PATT (ply_patt): the place after the pattern's address kept on the track's stack and the
          # pattern played, three deep at most; a fourth is FINE.
          def emit_pattern(t)
            level = track_list(:level)
            place = var(:at)
            if level[t] < MOST_PATTERN_LEVELS
              list(:stack, MOST_TRACKS * MOST_PATTERN_LEVELS)[(t * MOST_PATTERN_LEVELS) + level[t]] = place + 4
              level[t] = level[t] + 1
              place.store!(address_at(place))
            else
              emit_fine(t)
            end
          end

          # REPT (ply_rept): a count, then an address played that many times; a count of 0 plays it for
          # ever, which is the song's end as GOTO is.
          def emit_repeat(t)
            place = var(:at)
            count = var(:arg)
            repeats = track_list(:repeats)
            if count == 0
              place.increase!(1)
              emit_jump_back(t, place)
            else
              repeats[t] = repeats[t] + 1
              if repeats[t] < count
                place.store!(address_at(place + 1))
              else
                repeats[t] = 0
                place.increase!(5)
              end
            end
          end

          # MEMACC (ply_memacc): an operation, a byte of the driver's memory and a number; an
          # operation from 6 on is a test, which jumps to the address after it when it holds. The
          # driver's memory is the game's, set by its own code, so it starts at zeros here.
          def emit_memacc
            place = var(:at)
            operation = var(:arg)
            area = list(:memacc, MEMACC_BYTES)
            spot = var(:memacc_spot)
            data = var(:memacc_data)
            other = var(:memacc_other)
            held = var(:memacc_held)
            spot.store!(@block.byte(place + 1))
            data.store!(@block.byte(place + 2))
            place.increase!(3)
            other.store!(area[data])
            if operation == 0
              area[spot] = data
            elsif operation == 1
              area[spot] = (area[spot] + data) & 0xFF
            elsif operation == 2
              area[spot] = (area[spot] - data) & 0xFF
            elsif operation == 3
              area[spot] = other
            elsif operation == 4
              area[spot] = (area[spot] + other) & 0xFF
            elsif operation == 5
              area[spot] = (area[spot] - other) & 0xFF
            elsif operation >= 6 && operation <= 17
              held.store!(0)
              data.store!(other) if operation >= 12
              emit_memacc_test(operation, area[spot], data, held)
              if held == 1
                place.store!(address_at(place))
              else
                place.increase!(4)
              end
            end
          end

          # Whether the test of +operation+ holds for +value+ against +data+, into +held+: equal,
          # unequal, more, at least, at most, less, from operation 6 (and again from 12).
          def emit_memacc_test(operation, value, data, held)
            test = var(:memacc_test)
            test.store!(operation - 6)
            test.store!(test - 6) if test >= 6
            held.store!(1) if test == 0 && value == data
            held.store!(1) if test == 1 && value != data
            held.store!(1) if test == 2 && value > data
            held.store!(1) if test == 3 && value >= data
            held.store!(1) if test == 4 && value <= data
            held.store!(1) if test == 5 && value < data
          end

          # XCMD (ply_xcmd): a number, then what it changes in the track's voice, none of which the
          # records hold. One the driver's table sends to FINE stops the track.
          def emit_xcmd(t)
            place = var(:at)
            which = var(:arg)
            place.increase!(1)
            if which == 1
              place.increase!(4)
            elsif which == 2 || (which >= 4 && which <= 11)
              place.increase!(1)
            else
              emit_fine(t)
            end
          end

          # EOT (ply_endtie): an optional key, then the newest note of the track still held on that
          # key let go.
          def emit_end_of_tie(t)
            place = var(:at)
            key = track_list(:key)
            if var(:arg) < WAIT
              key[t] = var(:arg)
              place.increase!(1)
            end
            emit_release_key(key[t]) if @track && t == @track
          end

          def emit_release_key(key)
            used = sounding_list(:used)
            newest = var(:newest)
            newest.store!(-1)
            @block.repeat(MOST_SOUNDING) do |s|
              if used[s] == 1 && sounding_list(:key)[s] == key
                if newest < 0
                  newest.store!(s)
                elsif sounding_list(:sequence)[s] > sounding_list(:sequence)[newest]
                  newest.store!(s)
                end
              end
            end
            emit_release(newest) if newest >= 0
          end

          # A note (ply_note), +length+ the place of its length in CLOCKS: then up to three bytes under
          # 0x80, its key, its velocity and ticks added to its length, each kept from the note before
          # where it is left out.
          def emit_note(t, length)
            place = var(:at)
            gate = var(:gate)
            byte = var(:byte)
            gate.store!(list(:clocks, CLOCKS.length)[length])
            byte.store!(@block.byte(place))
            if byte < WAIT
              track_list(:key)[t] = byte
              place.increase!(1)
              byte.store!(@block.byte(place))
              if byte < WAIT
                track_list(:velocity)[t] = byte
                place.increase!(1)
                byte.store!(@block.byte(place))
                if byte < WAIT
                  gate.store!(gate + byte)
                  place.increase!(1)
                end
              end
            end
            emit_strike(t) if @track && t == @track
          end

          # The walked track's note struck: its voice and key found, its record written, and kept
          # sounding to be given its length.
          def emit_strike(t)
            voice = var(:sounding_voice)
            kind = var(:voice_kind)
            key = var(:sounding_key)
            instrument = var(:instrument)
            side_pan = var(:rhythm_pan)
            plays = var(:plays)
            raw = track_list(:key)[t]
            plays.store!(1)
            side_pan.store!(0)
            voice.store!(track_list(:voice)[t])
            key.store!(raw)
            instrument.store!(track_list(:voice_number)[t])
            kind.store!(1)
            kind.store!(@block.byte(voice)) if voice >= 0
            emit_picked_voice(raw) if (kind & (KEY_SPLIT | DRUM_KIT)) != 0
            if plays == 1
              channel = var(:channel)
              channel.store!(kind & CONSOLE_VOICE_BITS)
              emit_record(t, channel) if @kind == ANY_KIND || channel == @kind
            end
          end

          # A key split's or a drum kit's voice for the note's key +raw+: its instrument number, from
          # the split's or the kit's own first number, its own kind, and a kit's voice its own key
          # and pan. A split or kit inside one plays nothing.
          def emit_picked_voice(raw)
            voice = var(:sounding_voice)
            kind = var(:voice_kind)
            picked = var(:picked)
            panned = var(:panned)
            instrument = var(:instrument)
            if (kind & KEY_SPLIT) != 0
              picked.store!(@block.byte(address_at(voice + 8) + raw))
              instrument.store!(@split_from + picked)
            else
              picked.store!(raw)
              instrument.store!(@kit_from + picked)
            end
            panned.store!(kind & DRUM_KIT)
            voice.store!(address_at(voice + 4) + (picked * VOICE_BYTES))
            kind.store!(@block.byte(voice))
            if (kind & (KEY_SPLIT | DRUM_KIT)) != 0
              var(:plays).store!(0)
            elsif panned != 0
              pan = var(:voice_pan)
              pan.store!(@block.byte(voice + 3))
              var(:rhythm_pan).store!((pan - 0xC0) * 2) if pan >= 0x80
              var(:sounding_key).store!(@block.byte(voice + 1))
            end
          end

          # The record of the note on +channel+ (0 a recording, 1 to 4 the console's voices), and a
          # place among those sounding.
          def emit_record(t, channel)
            key = var(:sounding_key)
            right = var(:right)
            left = var(:left)
            emit_key_moved(t, key)
            emit_sides(t, right, left)
            at = var(:record_at)
            at.store!(@block.written)
            frame = var(:frame)
            @block.write(frame)
            @block.write(frame >> 8)
            @block.write(0)
            @block.write(0)
            if channel == KIND_RECORDING
              emit_recorded_fields(key, right + left)
            else
              emit_console_fields(channel, key, right, left)
            end
            @block.write(0)
            emit_voice_settings(channel, at) if @voiced
            emit_sounding(t, at)
          end

          # A VOICED RECORD'S SETTINGS (Original::PackNote's bytes 12 on), from the voice's twelve
          # bytes as the driver sets a console voice up for a note (ply_note, CgbSound, CgbModVol):
          #
          # - a square's duty, the low two bits of its fifth byte (NRx1's top two), every frame;
          # - the first square's slide, its fourth byte, the sweep register (NR10), where it moves
          #   (bits 4 to 6 and 0 to 2 each set, bit 7 clear); where it does not (ply_note writes 8)
          #   the note names none, so a part that cannot slide takes the track as well;
          # - the envelope (bytes 8 to 10, attack, decay and sustain), the nearest the voice's own
          #   counting makes of the driver's (CgbSound, CgbModVol). The driver swells a note from
          #   silence to its volume at the attack's step, falls at the decay's step to the sustain
          #   level (the volume times the sustain over 16, rounded up) and holds there; at a sustain
          #   of 0 it falls to silence. The voice can only count all the way up or down, so: a note at
          #   full volume with an attack swells from silence; a note with a decay and a sustain of 0
          #   fades at the decay's step; any other note holds at the sustain level, which its volume
          #   byte is rewritten to (a short swell or fall is not heard). The wave voice counts nothing,
          #   so its note only holds at the sustain level.
          #
          # A recording's note names none of them (the wave's pattern is its voice's,
          # unpack_m4a_voice).
          def emit_voice_settings(channel, at)
            voice = var(:sounding_voice)
            names = var(:voiced_names)
            duty = var(:voiced_duty)
            slide = var(:voiced_slide)
            fade = var(:voiced_fade)
            [names, duty, slide, fade].each { |each| each.store!(0) }
            if channel == KIND_FIRST_SQUARE || channel == KIND_SECOND_SQUARE
              duty.store!((@block.byte(voice + 4) & 3) * DUTY_EVERY_FRAME)
              names.store!(PackNote::NAMES.fetch(:duty))
            end
            if channel == KIND_FIRST_SQUARE
              sweep = var(:voiced_sweep)
              sweep.store!(@block.byte(voice + 3))
              if (sweep & 0x80) == 0 && (sweep & 0x70) != 0 && (sweep & 7) != 0
                slide.store!(sweep & 0x7F)
                names.store!(names | PackNote::NAMES.fetch(:slide))
              end
            end
            emit_voice_envelope(channel, at, fade, names) if channel != KIND_RECORDING
            # The pitch number, the fade, the duty, the vibrato, the slide, the shade, the names.
            [0, 0, fade, duty, 0, 0, slide, 0, names, names >> 8].each { |byte| @block.write(byte) }
            @block.repeat(PackNote::VOICED_BYTES - PackNote::BYTES - 10) { @block.write(0) }
          end

          # The envelope of a note on +channel+ into +fade+ (emit_voice_settings), and its volume
          # byte, at +at+ + 6, rewritten where the note holds at the sustain level.
          def emit_voice_envelope(channel, at, fade, names)
            voice = var(:sounding_voice)
            attack = var(:voiced_attack)
            decay = var(:voiced_decay)
            sustain = var(:voiced_sustain)
            volume = var(:cgb_volume)
            attack.store!(@block.byte(voice + 8) & 7)
            decay.store!(@block.byte(voice + 9) & 7)
            sustain.store!(@block.byte(voice + 10) & 15)
            if channel != KIND_WAVE && attack != 0 && volume == 15
              fade.store!(SWELLS | attack)
              names.store!(names | PackNote::NAMES.fetch(:fade))
              @block.rewrite(at + 6, 0)
            elsif channel != KIND_WAVE && decay != 0 && sustain == 0
              fade.store!(decay)
              names.store!(names | PackNote::NAMES.fetch(:fade))
            else
              held = var(:voiced_held)
              held.store!(((volume * sustain) + 15) >> 4)
              @block.rewrite(at + 6, held)
              names.store!(names | PackNote::NAMES.fetch(:fade)) if channel != KIND_WAVE
            end
          end

          # A duty's number on each of four frames (Audio::Duty#bits), and a fade's swell bit
          # (Audio::NoteFade#bits).
          DUTY_EVERY_FRAME = 0x55
          SWELLS = 8

          # TrkVolPitSet's keyM added to +key+, held to 0 and up: KEYSH whole, and TUNE plus BEND
          # times BENDR in 64ths of a key, taken down to the whole key below.
          def emit_key_moved(t, key)
            moved = var(:moved)
            moved.store!(((track_list(:tune)[t] + (track_list(:bend)[t] * track_list(:bend_range)[t])) * 4) +
                         (track_list(:shift)[t] * 256))
            key.store!(key + (moved >> 8))
            key.store!(0) if key < 0
          end

          # Each side's loudness, 0 to 255, as TrkVolPitSet and ChnVolSetAsm work them out from VOL,
          # PAN, the note's velocity and a drum's own pan.
          def emit_sides(t, right, left)
            x = var(:volume_x)
            y = var(:pan_y)
            x.store!((track_list(:volume)[t] * STARTING_VOLUME_X) >> 5)
            y.store!(track_list(:pan)[t] * 2)
            y.store!(-128) if y < -128
            y.store!(127) if y > 127
            velocity = track_list(:velocity)[t]
            side_pan = var(:rhythm_pan)
            right.store!(((((128 + side_pan) * velocity) * (((y + 128) * x) >> 8)) >> 14))
            left.store!(((((127 - side_pan) * velocity) * (((127 - y) * x) >> 8)) >> 14))
            right.store!(255) if right > 255
            left.store!(255) if left > 255
          end

          # A recording's note: its key (60 for one at a fixed rate), its instrument (one no byte
          # under PackNote::PART_OWN holds is the part's own), no volume or speaker of its own, its
          # loudness in 512ths, no noise clock.
          def emit_recorded_fields(key, loudness)
            kind = var(:voice_kind)
            instrument = var(:instrument)
            key.store!(MOST_KEY) if key > MOST_KEY
            key.store!(OWN_KEY) if (kind & FIXED_RATE) != 0
            instrument.store!(PackNote::PART_OWN) if instrument < 0 || instrument > PackNote::PART_OWN
            @block.write(key)
            @block.write(instrument)
            @block.write(PackNote::PART_OWN)
            @block.write(PackNote::PART_OWN)
            @block.write(loudness)
            @block.write(loudness >> 8)
            @block.write(PackNote::PART_OWN)
          end

          # A note of the console's voices: its key, the part's instrument, its volume and speaker
          # (CgbModVol, CgbPan), no loudness, and on the noise voice its clock.
          def emit_console_fields(channel, key, right, left)
            volume = var(:cgb_volume)
            side = var(:cgb_side)
            clock = var(:cgb_clock)
            if channel == KIND_NOISE
              clock.store!(key - LOWEST_NOISE_KEY)
              clock.store!(0) if clock < 0
              clock.store!(NOISE_ENTRIES - 1) if clock > NOISE_ENTRIES - 1
              clock.store!(list(:noise, NOISE_TABLE.length)[clock])
            else
              clock.store!(PackNote::PART_OWN)
              key.store!(LOWEST_TONE_KEY) if key < LOWEST_TONE_KEY
            end
            key.store!(MOST_KEY) if key > MOST_KEY
            volume.store!((right + left) >> 4)
            volume.store!(15) if volume > 15
            side.store!(0)
            if right >= left
              side.store!(2) if (right >> 1) >= left
            elsif (left >> 1) >= right
              side.store!(1)
            end
            @block.write(key)
            @block.write(PackNote::PART_OWN)
            @block.write(volume)
            @block.write(side)
            @block.write(PackNote::NO_LOUDNESS)
            @block.write(PackNote::NO_LOUDNESS >> 8)
            @block.write(clock)
          end

          # The note just written kept among those sounding, with the record's place, its length's
          # ticks (0 for a tie) and the key that lets go of it; with no room it lasts until the next.
          def emit_sounding(t, at)
            free = var(:free)
            used = sounding_list(:used)
            free.store!(-1)
            @block.repeat(MOST_SOUNDING) { |s| free.store!(s) if free < 0 && used[s] == 0 }
            if free >= 0
              used[free] = 1
              sounding_list(:gate)[free] = var(:gate)
              sounding_list(:key)[free] = track_list(:key)[t]
              sounding_list(:record)[free] = at
              sounding_list(:start)[free] = var(:frame)
              sounding_list(:sequence)[free] = var(:sequence)
              var(:sequence).increase!(1)
            end
          end

          # Sounding note +s+ let go on this frame: its record given the frames since it started, one
          # at least.
          def emit_release(s)
            length = var(:length)
            record = sounding_list(:record)[s]
            length.store!(var(:frame) - sounding_list(:start)[s])
            length.store!(1) if length < 1
            @block.rewrite(record + 2, length)
            @block.rewrite(record + 3, length >> 8)
            sounding_list(:used)[s] = 0
          end

          def emit_release_all
            @block.repeat(MOST_SOUNDING) { |s| emit_release(s) if sounding_list(:used)[s] == 1 }
          end
        end

        # One track's notes as Original::PackNote records, from the song whose header is at at:, then
        # the record that ends the part where the slot has room for it. `track:` counts from 0;
        # `kind:` keeps one kind of voice's notes; `kit_from:` and `split_from:` are the instrument
        # numbers a drum kit's and a key split's first voice are given (M4A).
        module Track
          extend Format
          unpacks :m4a_track, track: 0, kind: ANY_KIND, kit_from: KIT_AND_SPLIT_NUMBERS_FROM, split_from: KIT_AND_SPLIT_NUMBERS_FROM
          called "MusicPlayer2000 track"

          def self.routine(block) = M4A.emit_track(block, voiced: false)
        end

        # One track's notes as voiced Original::PackNote records, for a slot of `voiced_notes`: as
        # Track writes them, each with its console voice's duty, slide and fade (Walk#emit_voice_settings).
        module VoicedTrack
          extend Format
          unpacks :m4a_voiced_track, track: 0, kind: ANY_KIND, kit_from: KIT_AND_SPLIT_NUMBERS_FROM,
                                     split_from: KIT_AND_SPLIT_NUMBERS_FROM
          called "MusicPlayer2000 track with its voices' settings"

          def self.routine(block) = M4A.emit_track(block, voiced: true)
        end

        # The walk of a track writing its records, +voiced+ or not, then the record that ends the part.
        def self.emit_track(block, voiced:)
          record_bytes = voiced ? PackNote::VOICED_BYTES : PackNote::BYTES
          Walk.new(block, {}, track: block.setting(:track), kind: block.setting(:kind), kit_from: block.setting(:kit_from),
                              split_from: block.setting(:split_from), voiced: voiced).emit
          if block.room >= record_bytes
            block.write(PackNote::END_OF_PART)
            block.write(PackNote::END_OF_PART >> 8)
            block.repeat(record_bytes - 2) { block.write(0) }
          end
        end

        # The song's length in frames and the frame it comes round to (NO_LOOP for a song that ends),
        # two numbers of two bytes, low byte first: for a Score's `length:` and `loop_from:`.
        module Length
          extend Format
          unpacks :m4a_length
          called "MusicPlayer2000 song length"

          def self.routine(block)
            lists = {}
            jumped = block.variable(:m4a_jumped)
            jumped.store!(0)
            Walk.new(block, lists).emit
            length = block.variable(:m4a_song_length)
            length.store!(block.variable(:m4a_end_frame))
            found = block.variable(:m4a_found_frame)
            found.store!(NO_LOOP)
            Walk.new(block, lists, watch: true).emit if jumped == 1
            block.write(length)
            block.write(length >> 8)
            block.write(found)
            block.write(found >> 8)
          end
        end

        # WHERE A VOICE'S RECORDING IS (its WaveData): the voice's place at at:, a recording's voice,
        # whose second word is where the recording is. A recording's header is two bytes of kind, two
        # of status (0x4000 or 0x8000: it loops), its pitch (its rate times 1024), the sample it loops
        # back to, how many samples, then the samples, signed, a byte each. A voice that is not a
        # recording's is the fault the build stops on.
        def self.emit_recording_place(block, wave)
          kind = block.variable(:m4a_kind)
          kind.store!(block.byte(block.from))
          if (kind & (KEY_SPLIT | DRUM_KIT | CONSOLE_VOICE_BITS)) == 0
            wave.store!(word_at(block, block.from + 4) & ADDRESS_BITS)
          else
            block.emit_wrong_format_fault
          end
        end

        # A word of the copy at +at+, low byte first.
        def self.word_at(block, at)
          block.byte(at) | (block.byte(at + 1) << 8) | (block.byte(at + 2) << 16) | (block.byte(at + 3) << 24)
        end

        # A recording's samples, signed, a byte each, for a slot of samples (`slots.samples`).
        module Recording
          extend Format
          unpacks :m4a_recording
          called "MusicPlayer2000 recording"

          def self.routine(block)
            wave = block.variable(:m4a_wave)
            M4A.emit_recording_place(block, wave)
            unless block.finished
              size = block.variable(:m4a_size)
              size.store!(M4A.word_at(block, wave + 12))
              block.expect_size(size)
              block.repeat(size, stop_when: block.finished) { |i| block.write(block.byte(wave + 16 + i)) }
            end
          end
        end

        # A recording's settings, four numbers of four bytes, low byte first, for a slot of numbers
        # `width: :word`: its rate (its pitch over 1024, or `mix_rate:` for a voice played at a fixed
        # rate, where a port gives the rate its game mixes at), the sample a held note goes back to
        # (where it loops; one that does not loop, NO_HOLD, every bit set, which `holds_from:` takes
        # as no hold, so the voice plays once), how many samples it has, and the voice's attack,
        # decay, sustain and release, a byte each
        # (`as_numbers(at: 12, count: 4, width: :byte, signed: false).envelope(0)`).
        module Voice
          extend Format
          unpacks :m4a_voice, mix_rate: 0
          called "MusicPlayer2000 voice"

          # Where each byte of a number of four bytes is, low byte first.
          WORD_SHIFTS = [0, 8, 16, 24].freeze
          # The hold of a voice that does not loop: every bit set (IR::StartFile.no_hold?).
          NO_HOLD = -1

          def self.routine(block)
            wave = block.variable(:m4a_wave)
            if (block.byte(block.from) & (KEY_SPLIT | DRUM_KIT | CONSOLE_VOICE_BITS)) == KIND_WAVE
              emit_wave_pattern(block, wave)
            else
              emit_recording_settings(block, wave)
            end
          end

          # THE WAVE VOICE'S PATTERN (a voice of KIND_WAVE): the sixteen bytes its second word
          # points at, two steps a byte, the earlier in the high four bits, as CgbSound copies them
          # into the wave memory, for a Score part's `plays: pack[:slot].wave(0)` (DSL::PackWave).
          def self.emit_wave_pattern(block, wave)
            wave.store!(M4A.word_at(block, block.from + 4) & ADDRESS_BITS)
            block.expect_size(DSL::PackWave::BYTES)
            block.repeat(DSL::PackWave::BYTES, stop_when: block.finished) { |i| block.write(block.byte(wave + i)) }
          end

          def self.emit_recording_settings(block, wave)
            M4A.emit_recording_place(block, wave)
            unless block.finished
              rate = block.variable(:m4a_rate)
              hold = block.variable(:m4a_hold)
              size = block.variable(:m4a_size)
              rate.store!(M4A.word_at(block, wave + 4) >> 10)
              rate.store!(block.setting(:mix_rate)) if (block.byte(block.from) & FIXED_RATE) != 0 && block.setting(:mix_rate) > 0
              size.store!(M4A.word_at(block, wave + 12))
              hold.store!(NO_HOLD)
              hold.store!(M4A.word_at(block, wave + 8)) if (block.byte(wave + 3) & 0xC0) != 0
              block.expect_size(16)
              [rate, hold, size].each do |number|
                WORD_SHIFTS.each { |shift| block.write(number >> shift) }
              end
              4.times { |at| block.write(block.byte(block.from + 8 + at)) }
            end
          end
        end

        # The voiced track last, so the others keep the numbers a fault names them by.
        FORMATS = [Track, Length, Recording, Voice, VoicedTrack].freeze
      end
    end
  end
end
