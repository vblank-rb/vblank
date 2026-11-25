# frozen_string_literal: true

module VBlank
  module Original
    module Packing
      # The Advance's common sound driver, MusicPlayer2000 (the "m4a" library; "Sappy" to rippers),
      # read from the copy into what a song of the pack is: the notes of each part as
      # Original::PackNote records, the song's length and where it comes round, and each recording
      # and its settings. Most Advance games keep their music in this driver, so these are offered
      # with the Advance's other formats:
      #
      #   copy.unpack_m4a_track at: song, into: pack[:title_0], track: 0           # one track's notes
      #   copy.unpack_m4a_track at: song, into: pack[:drums], track: 6, kind: 4    # ...on one voice only
      #   copy.unpack_m4a_track at: song, into: pack[:beat], track: 5, kit_from: 8 # ...a kit's keys from 8
      #   copy.unpack_m4a_length at: song, into: pack[:title_length]               # length, loop frame
      #   copy.unpack_m4a_recording at: VOICE, into: pack[:piano]                  # a recording's samples
      #   copy.unpack_m4a_voice at: VOICE, into: pack[:piano_settings]             # its rate, hold (or none), length, envelope
      #   copy.unpack_m4a_voice at: WAVE_VOICE, into: pack[:pattern]               # the wave voice's pattern, sixteen bytes
      #   copy.unpack_m4a_voiced_track at: song, into: pack[:lead], track: 1       # notes with their voices' settings
      #
      # SONG is where the song's header is in the copy, and VOICE where a voice's twelve bytes are (the
      # song's voice group, then 12 bytes a voice, or a voice of a drum kit or key split; a routine
      # works these out with `copy.word`, each a cartridge address, 0x08000000 the copy's first byte).
      # A port that keeps its songs another way writes its own unpacking (original.md), and nothing
      # here is in the song model, the IR or a runtime: this is game code that writes records.
      #
      # The answer key is the driver's own source, as the decompilations of Advance games have it
      # (tmc and pokeemerald: asm/lib/m4a_asm.s, MPlayMain, ply_note, ChnVolSetAsm and the ply_
      # commands; src/gba/m4a.c, MPlayStart, TrkVolPitSet, MidiKeyToCgbFreq, CgbPan, CgbModVol, the
      # tables and ply_memacc), and test/m4a_answers.rb is a decoder written from it.
      #
      # Time is in frames. The driver adds the tempo (beats a minute, times 2) to a count each frame
      # and plays a tick of every track each time the count reaches 150, keeping what is left; a song
      # starts at 150, a tick a frame, and its first tick plays on its first frame. So a tick lands on a
      # frame no fixed tick rate gives, and every track is walked tick by tick, since a TEMPO in any
      # track moves all of them. Each record's tick is that frame, from the song's start, and its
      # length the frames to the tick that lets it go; the song's Score plays a tick a frame
      # (`tempo: 3600, ticks_per_beat: 1`).
      #
      # A song comes round where every track is playing its loop again. Each track jumps back on its
      # own (GOTO, or REPT with no count), so a short figure goes round many times to a long melody's
      # once, and a part may come in late, first sounding on its second time round. The walk counts
      # in ticks, as the driver's song data does, and plays the song from its start three times:
      #
      # 1. Until every track still playing has jumped back once: where each jumps back to (its
      #    loop's start) and on which tick (its loop's end). A track that ends (FINE) falls silent
      #    when it does, or when its last note ends if that is later.
      # 2. Until every track has played its loop twice: the notes each strikes the first time round,
      #    from the tick it first reaches its loop's start, and the second time, from its first jump,
      #    each folded into one number (Walk#emit_fold_note), with the notes still sounding from
      #    before, and on the first track the tempo. Where the two are the same, the track repeats
      #    from its loop's start; otherwise its first time round is heard once, and it repeats from
      #    its first jump. The song repeats from the latest of these (and of where a track falls
      #    silent), and one time round of it is the least span every loop fits whole.
      # 3. To where the song repeats and MOST_LAPS times round past it: the frame each time round
      #    starts on, and what is left of the tempo's count then. The count can leave one time round
      #    starting a frame later than the one before, and a MEMACC can count times round in the
      #    driver's memory, so the notes are written out until both come back: the first time round
      #    that starts with the count and the memory as an earlier one did is the song's length, that
      #    earlier one where it comes round to. Failing that, the song comes round to its second time
      #    round and ends where the third starts, a frame off at most.
      #
      # A track's notes are then walked once more, to the song's length. The notes from the loop
      # frame play over and over as the driver plays them; a MEMACC counting rounds plays each as it
      # falls. A song no track jumps back in ends when its last track ends (FINE), and has no loop
      # frame (NO_LOOP). A note sounding as the song comes round is let go there, as Score plays one
      # (sound.md).
      #
      # Why the reader writes the rounds out, not a Score part that loops on its own: every song
      # player there is (the interpreter, the Advance's and every console's, the C, JavaScript and
      # Ruby runtimes) comes round at one moment for every part, and a part with its own loop point
      # would be a change to each of them, while a round that differs from the one before (MEMACC,
      # the tempo's count) needs the notes written out whatever the parts can do. Writing them costs
      # the slots room: a port sizes a track's slot, and a Score's `longest:`, for the rounds its
      # song comes round in.
      #
      # A plain voice's key byte (its base key) plays no part in the pitch: ply_note hands MidiKeyToFreq
      # the note's own key (the track's key moved by KEYSH, TUNE and BEND) and the recording's own rate,
      # and a voice's key byte is read only for a drum kit's entry, where it is the key the note plays.
      #
      # Each note, as ply_note strikes it: its voice is the track's (VOICE), or for a drum kit the
      # kit's voice of the note's key, and for a key split the split's voice its table names for the
      # key; a split or kit inside one plays nothing. Its key is the note's key (a drum kit's: its
      # voice's own) moved by KEYSH, and by TUNE and BEND times BENDR in whole keys as TrkVolPitSet
      # works them out (what is left of a key is kept only in a voiced record, below). Its
      # loudness is the note's velocity and the track's VOL and PAN, as ChnVolSetAsm works out its
      # two sides:
      #
      # - On a recording (DirectSound): the instrument byte is a number for the voice (the
      #   instrument byte, below); a voice whose recording is played at a fixed rate is key 60; the
      #   loudness is the two sides added, in 512ths, as the mixer adds them. A plain record has no
      #   place for where it sits between the speakers; a voiced one names it (below).
      # - On the console's voices: the volume is the two sides added over 16, at most 15 (CgbModVol),
      #   and the speaker is the side that is twice the other or more, else both (CgbPan). A square or
      #   wave note under key 36 is key 36 (MidiKeyToCgbFreq); a noise note's clock is the driver's
      #   table entry for its key (gNoiseTable).
      #
      # `kind:` keeps only the notes of one kind of voice: KIND_RECORDING, 1 or 2 for the squares, 3
      # for the wave, 4 for the noise, ANY_KIND (the default) for all. A track that drums on recordings
      # and on the noise voice at once is two parts, one each.
      #
      # The instrument byte names which of the part's instruments a recorded note plays, so one track
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
      # A recording's note, voiced (unpack_m4a_voiced_track), keeps three things more:
      #
      # - where it sits between the speakers, from its two sides (PAN, and a drum kit voice's own
      #   pan): Original::PackNote's shade, which the Super Nintendo and the PlayStation play where
      #   it sits and the Advance's one mix from both (Walk#emit_recorded_settings);
      # - a pitch between keys, where TUNE and BEND leave part of a key, as the record's hz, read as
      #   MidiKeyToFreq reads it, on a straight line between the two keys (Walk#emit_pitch_hz);
      # - a change while it sounds: a KEYSH, BEND, BENDR, TUNE, VOL or PAN while the part's newest note
      #   sounds moves its pitch or its sides, as the driver moves every sounding note of the track, so
      #   the reader writes a record that glides (`glides: true`) at the note's pitch, loudness and
      #   shade then, on that frame, one a frame at most (Walk#emit_change_sounding). A bend that
      #   sweeps is a glide a frame, so a port sizes a voiced slot for the glides as well as the
      #   notes. A note on a console voice is changed by the driver too, which the song model does
      #   not glide, so that is not kept.
      #
      # What is not kept, since the song model has no place for it: a change while a note sounds on
      # a console voice or in a plain record; LFOS, LFODL, MOD and MODT (vibrato); PRIO and which
      # notes the driver's channels drop when too many sound; XCMD's changes to the track's voice; PORT's sound register writes; a
      # console voice's length byte, which cuts its notes short. A console voice's own settings are read by unpack_m4a_voiced_track into a slot of
      # `voiced_notes`, each note with its voice's duty, slide and fade (Walk#emit_voice_settings
      # says how the driver's envelope is matched), and the wave voice's pattern by unpack_m4a_voice;
      # unpack_m4a_track leaves them to the part. A track sounds one note at a time as a
      # part, so of two struck on one frame the part plays the later. More than MOST_SOUNDING notes of
      # one track sounding at once: the later ones last until the next note. With `kind:`, EOT lets go
      # of the newest kept note on its key, where the driver looks at all of the track's.
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
        # How many times round the song's loop past the first the tempo's count is followed for, to
        # find it come back (a song comes round).
        MOST_LAPS = 5
        # The longest loop of a song in ticks that is followed: past it, the least span every
        # track's loop fits whole is taken as this, which no song reaches in MOST_FRAMES.
        MOST_LAP_TICKS = 0x3FFFF
        # How many of a track's notes are kept to tell which still sound as it reaches its loop's
        # start and its first jump, and how many of its ties.
        NOTES_KEPT = 16

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
        # The commands that move the pitch or the sides of a track's notes, those sounding too (TrkVolPitSet).
        SOUNDING_CHANGE_COMMANDS = [KEYSH, BEND, BENDR, TUNE, VOL, PAN].freeze
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

        # The highest key MidiKeyToFreq reads its tables at; past it the key is this, a 256th short of
        # the next.
        MOST_DRIVER_KEY = 178
        # Each key's pitch to MOST_DRIVER_KEY and one past, in 16ths of a hertz, tuned from A above
        # middle C (key 69) at 440 Hz as a Score::Note's key is: what a voiced record's hz names
        # (Original::PackNote, bytes 22-24). MidiKeyToFreq reads a key between two of these on a
        # straight line from the one below to the one above, by 256ths of a key, and so does the
        # reader (Walk#emit_pitch_hz). A recording's own note, key 60, is the instrument's.
        KEY_HZ = (0..(MOST_DRIVER_KEY + 1)).map { |key| (440 * (2**((key - 69) / 12r)) * PackNote::HZ_SIXTEENTHS).round }.freeze
        # The 256ths of a key, the most a fine pitch can be.
        FINE_BITS = 0xFF

        # gNoiseTable: the noise register's setting for each key from LOWEST_NOISE_KEY, four dividers,
        # 7 down to 4, for each number of halvings from 13 down to 1, then every divider with none.
        NOISE_TABLE = [*13.downto(1).flat_map { |halvings| 7.downto(4).map { |divider| (halvings << 4) | divider } },
                       *7.downto(0).to_a].freeze

        # One sound driver's song, walked tick by tick as MPlayMain plays it, written as game code
        # into an unpacking routine. +block+ is the format's BlockKit. +lists+ keeps the lists the walk
        # reads, one set for each routine, made the first time a walk asks.
        #
        # +pass+ is which walk of a song comes round this is, each from the song's start and each
        # leaving what the next reads in the routine's lists and variables: :first_jumps, :repeats
        # and :laps (M4A.emit_song_timing runs the three); or :notes, a walk to the song's length
        # writing +track+'s notes (a setting), with +kind+ the kind of voice kept and +kit_from+ and
        # +split_from+ the instrument numbers a kit's and a split's first voice are given.
        #
        # +voiced+ writes each record as a voiced Original::PackNote, with its console voice's own
        # settings from the voice's twelve bytes (VoicedTrack says which).
        class Walk
          def initialize(block, lists, pass:, track: nil, kind: nil, kit_from: nil, split_from: nil, voiced: false)
            @block = block
            @lists = lists
            @pass = pass
            @track = track
            @kind = kind
            @kit_from = kit_from
            @split_from = split_from
            @voiced = voiced
          end

          def var(name) = @block.variable(:"m4a_#{name}")

          def list(name, capacity) = @lists[name] ||= @block.list(:"m4a_#{name}", capacity: capacity)

          def track_list(name) = list(name, MOST_TRACKS)

          # A list of the notes sounding, named apart from the tracks' lists: both have sixteen
          # entries, so a sounding note's key under the name a track's key has would be the same list,
          # and striking a note in entry 3 would change track 3's key.
          def sounding_list(name) = list(:"sounding_#{name}", MOST_SOUNDING)

          # A cartridge address read from the copy at +at+, as a place in the copy.
          def address_at(at) = M4A.word_at(@block, at) & ADDRESS_BITS

          # +value+ as a signed byte, into +into+.
          def emit_signed_byte(into, value)
            into.store!(value)
            into.store!(into - 256) if into >= 128
          end

          # The walk: every track from its start, a frame at a time, until the song ends, the pass has
          # what it walks for, or the notes walked reach the song's length (var(:stop_frame), -1 for
          # a song that ends of itself).
          def emit
            emit_start
            ended = var(:ended)
            tempo_count = var(:tempo_count)
            tempo = var(:tempo)
            frame = var(:frame)
            ticking = var(:ticking)
            @block.repeat(MOST_FRAMES, stop_when: ended == 1) do
              emit_song_end if @pass == :notes && frame == var(:stop_frame)
              if ended == 0
                tempo_count.store!(tempo_count + tempo)
                ticking.store!(0)
                ticking.store!(1) if tempo_count >= TEMPO_COUNT_PER_TICK
                @block.repeat(MOST_TICKS_A_FRAME, stop_when: ticking == 0) do
                  emit_tick
                  tempo_count.store!(tempo_count - TEMPO_COUNT_PER_TICK)
                  emit_lap_mark if @pass == :laps
                  var(:tick).increase!(1)
                  ticking.store!(0) if tempo_count < TEMPO_COUNT_PER_TICK
                  ticking.store!(0) if ended == 1
                end
                frame.increase!(1) if ended == 0
                emit_first_jumps_done if @pass == :first_jumps
                emit_repeats_done if @pass == :repeats
              end
            end
            emit_open_ties_folded if @pass == :repeats
            emit_release_all if @track
          end

          # MPlayStart and a track's first tick (MPlayMain, a track with MPT_FLG_START): the header
          # read, every track at its start.
          def emit_start
            emit_lists
            from = @block.from
            var(:ended).store!(0)
            var(:frame).store!(0)
            var(:tick).store!(0)
            var(:tempo).store!(STARTING_TEMPO)
            var(:tempo_count).store!(0)
            var(:sequence).store!(0)
            var(:group).store!(address_at(from + 4))
            count = var(:track_count)
            count.store!(@block.byte(from))
            count.store!(MOST_TRACKS) if count > MOST_TRACKS
            emit_pass_start
            clocks = list(:clocks, CLOCKS.length)
            CLOCKS.each_with_index { |ticks, at| clocks[at] = ticks }
            noise = list(:noise, NOISE_TABLE.length)
            NOISE_TABLE.each_with_index { |setting, at| noise[at] = setting }
            if @voiced
              key_hz = list(:key_hz, KEY_HZ.length)
              KEY_HZ.each_with_index { |hz, at| key_hz[at] = hz }
              var(:newest_sounding).store!(-1)
            end
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
            (TRACK_LISTS + LOOP_LISTS).each { |name| track_list(name) }
            SOUNDING_LISTS.each { |name| sounding_list(name) }
            VOICED_SOUNDING_LISTS.each { |name| sounding_list(name) } if @voiced
            list(:key_hz, KEY_HZ.length) if @voiced
            list(:stack, MOST_TRACKS * MOST_PATTERN_LEVELS)
            KEPT_LISTS.each { |name| kept_list(name) }
            LAP_LISTS.each { |name| list(name, MOST_LAPS + 1) }
          end

          # Each track's state, which the driver plays on from.
          TRACK_LISTS = %i[place wait status active level repeats key velocity shift voice voice_number volume pan bend
                           bend_range tune].freeze
          # Each track's loop, the walk's own: the tick it first jumps back on (-1 before) and where to,
          # the tick its last note ends, the tick it first reaches its loop's start (-1 before), and
          # its notes the first time round and the second, each folded into one number; and where
          # its next note is kept (KEPT_LISTS).
          LOOP_LISTS = %i[jump_tick target held_until arrival first_sound second_sound note_next].freeze
          # NOTES_KEPT of each track's notes, newest over oldest: the tick each is struck, the tick it
          # ends and what it sounds (#emit_note_sound), and where the next goes; and as many of its
          # ties, the key that lets go of each and 1 where it still sounds.
          KEPT_LISTS = %i[note_tick note_end note_sound tie_tick tie_key tie_sound tie_held].freeze
          # The frame each time round of the song starts on, what is left of the tempo's count, and
          # the driver's memory folded into one number.
          LAP_LISTS = %i[lap_frames lap_counts lap_memories].freeze

          def kept_list(name) = list(name, MOST_TRACKS * NOTES_KEPT)

          # What each pass starts from: no track yet jumped back, reached its loop's start or heard,
          # no time round marked.
          def emit_pass_start
            @block.repeat(MOST_TRACKS) do |t|
              if @pass == :first_jumps
                track_list(:jump_tick)[t] = -1
                track_list(:held_until)[t] = 0
              end
              track_list(:arrival)[t] = -1
              track_list(:first_sound)[t] = 0
              track_list(:second_sound)[t] = 0
              track_list(:note_next)[t] = 0
            end
            @block.repeat(MOST_TRACKS * NOTES_KEPT) do |i|
              kept_list(:note_end)[i] = -1
              kept_list(:tie_held)[i] = 0
            end
            if @pass == :first_jumps
              var(:looped_count).store!(0)
              var(:silent_from).store!(-1)
            end
            var(:arrived_count).store!(0)
            var(:repeats_until).store!(0)
            var(:lead_tempo).store!(-1)
            var(:marks_made).store!(0)
          end

          # First jumps: the walk is done once a track has jumped back and every track still playing
          # has.
          def emit_first_jumps_done
            unlooped = var(:unlooped_playing)
            unlooped.store!(0)
            @block.repeat(var(:track_count)) do |t|
              unlooped.increase!(1) if track_list(:active)[t] == 1 && track_list(:jump_tick)[t] < 0
            end
            emit_song_end if var(:looped_count) > 0 && unlooped == 0
          end

          # REPEATS: the walk is done once every looping track has reached its loop's start and played
          # its loop through twice.
          def emit_repeats_done
            emit_song_end if var(:arrived_count) == var(:looped_count) && var(:tick) >= var(:repeats_until)
          end

          # Track +t+ reaching its loop's start for the first time, this tick: its notes struck before
          # and still sounding are the first of its first time round.
          def emit_arrival(t)
            tick = var(:tick)
            jump = track_list(:jump_tick)[t]
            track_list(:arrival)[t] = tick
            emit_held_notes_folded(t, tick, track_list(:first_sound))
            until_tick = var(:until_tick)
            until_tick.store!((jump * 2) - tick)
            var(:repeats_until).store!(until_tick) if until_tick > var(:repeats_until)
            var(:arrived_count).increase!(1)
          end

          # Track +t+'s notes struck before tick +at+ and still sounding then, folded into its +into+.
          def emit_held_notes_folded(t, at, into)
            @block.repeat(NOTES_KEPT) do |k|
              i = (t * NOTES_KEPT) + k
              if kept_list(:note_end)[i] > at && kept_list(:note_tick)[i] < at
                into[t] = into[t] + emit_note_hash(kept_list(:note_tick)[i] - at, kept_list(:note_sound)[i])
              end
            end
          end

          # What a note sounds, one number for its voice, its key moved by KEYSH, its velocity, the
          # track's VOL, then its length in ticks (0 for a tie never let go): +length+ times
          # NOTE_SOUND_BASE added to the rest, which a tie keeps until it is let go. A number apart
          # for each note a track can play, near enough that two times round with the same notes, and
          # only those, fold into the same number.
          def emit_note_sound(t)
            sound = var(:note_sound)
            sound.store!((((((track_list(:voice_number)[t] * NOTE_SOUND_BASE) + track_list(:key)[t] + track_list(:shift)[t]) *
                           NOTE_SOUND_BASE) + track_list(:velocity)[t]) * NOTE_SOUND_BASE) + track_list(:volume)[t])
            sound
          end

          NOTE_SOUND_BASE = 131

          # A note's +sound+ with its +length+.
          def note_with_length(sound, length) = (sound * NOTE_SOUND_BASE) + length

          # A number for a note struck +offset+ ticks from where a time round starts, sounding
          # +sound+: the two mixed so that the sum of a time round's notes tells one set of them from
          # another whatever order they are added in (the mixing step of MurmurHash2).
          def emit_note_hash(offset, sound)
            mixed = var(:mixed)
            mixed.store!((sound * 31) + offset)
            mixed.store!(mixed ^ (mixed >> 13))
            mixed.store!(mixed * MIX_MULTIPLIER)
            mixed.store!(mixed ^ (mixed >> 15))
            mixed
          end

          MIX_MULTIPLIER = 0x5BD1_E995

          # REPEATS: a note of track +t+ struck this tick, of +gate+ ticks (0 a tie), kept, and folded
          # into the time round it falls in.
          def emit_note_kept(t, gate)
            tick = var(:tick)
            sound = emit_note_sound(t)
            at = var(:kept_at)
            if gate == 0
              at.store!(-1)
              @block.repeat(NOTES_KEPT, stop_when: at >= 0) do |k|
                at.store!((t * NOTES_KEPT) + k) if kept_list(:tie_held)[(t * NOTES_KEPT) + k] == 0
              end
              if at >= 0
                kept_list(:tie_held)[at] = 1
                kept_list(:tie_tick)[at] = tick
                kept_list(:tie_key)[at] = track_list(:key)[t]
                kept_list(:tie_sound)[at] = sound
              end
            else
              sound.store!(note_with_length(sound, gate))
              at.store!((t * NOTES_KEPT) + track_list(:note_next)[t])
              track_list(:note_next)[t] = (track_list(:note_next)[t] + 1) % NOTES_KEPT
              kept_list(:note_tick)[at] = tick
              kept_list(:note_end)[at] = tick + gate
              kept_list(:note_sound)[at] = sound
              emit_struck_note_folded(t, tick, sound)
            end
          end

          # A note of track +t+ struck on tick +struck+ and sounding +sound+ folded into the time round
          # it is struck in, if either.
          def emit_struck_note_folded(t, struck, sound)
            arrival = track_list(:arrival)[t]
            jump = track_list(:jump_tick)[t]
            if arrival >= 0
              if struck >= arrival && struck < jump
                track_list(:first_sound)[t] = track_list(:first_sound)[t] + emit_note_hash(struck - arrival, sound)
              end
              if struck >= jump && struck < (jump * 2) - arrival
                track_list(:second_sound)[t] = track_list(:second_sound)[t] + emit_note_hash(struck - jump, sound)
              end
            end
          end

          # REPEATS: track +t+'s newest tie on its key let go this tick. It lasted until now, one tick at
          # least, and is folded into the time round it was struck in, and into the one it was still
          # sounding as it started.
          def emit_tie_let_go(t)
            newest = var(:newest_tie)
            newest.store!(-1)
            @block.repeat(NOTES_KEPT) do |k|
              i = (t * NOTES_KEPT) + k
              if kept_list(:tie_held)[i] == 1 && kept_list(:tie_key)[i] == track_list(:key)[t]
                newest.store!(i) if newest < 0
                newest.store!(i) if newest >= 0 && kept_list(:tie_tick)[i] >= kept_list(:tie_tick)[newest]
              end
            end
            if newest >= 0
              kept_list(:tie_held)[newest] = 0
              struck = var(:tie_struck)
              length = var(:tie_length)
              sound = var(:tie_sounding)
              struck.store!(kept_list(:tie_tick)[newest])
              length.store!(var(:tick) - struck)
              length.store!(1) if length < 1
              sound.store!(note_with_length(kept_list(:tie_sound)[newest], length))
              emit_struck_note_folded(t, struck, sound)
              emit_tie_held_folded(t, struck, length, sound)
            end
          end

          # A let-go tie of track +t+, struck on +struck+ and +length+ ticks long, folded into each time
          # round it was still sounding as it started.
          def emit_tie_held_folded(t, struck, length, sound)
            arrival = track_list(:arrival)[t]
            jump = track_list(:jump_tick)[t]
            if arrival >= 0 && struck < arrival && struck + length > arrival
              track_list(:first_sound)[t] = track_list(:first_sound)[t] + emit_note_hash(struck - arrival, sound)
            end
            if struck < jump && struck + length > jump
              track_list(:second_sound)[t] = track_list(:second_sound)[t] + emit_note_hash(struck - jump, sound)
            end
          end

          # REPEATS, at its end: each tie still sounding is one never let go, with no length, folded
          # into the time round it was struck in.
          def emit_open_ties_folded
            @block.repeat(var(:track_count)) do |t|
              @block.repeat(NOTES_KEPT) do |k|
                i = (t * NOTES_KEPT) + k
                if kept_list(:tie_held)[i] == 1
                  emit_struck_note_folded(t, kept_list(:tie_tick)[i], note_with_length(kept_list(:tie_sound)[i], 0))
                end
              end
            end
          end

          # REPEATS: the first track's tempo in force as a time round of it starts (-1 where it has set
          # none), folded in, after the track's reads on that tick.
          def emit_lead_tempo_folded
            tick = var(:tick)
            if track_list(:arrival)[0] == tick
              track_list(:first_sound)[0] = track_list(:first_sound)[0] + emit_note_hash(TEMPO_IN_FORCE, -1 - var(:lead_tempo))
            end
            if track_list(:jump_tick)[0] == tick
              track_list(:second_sound)[0] = track_list(:second_sound)[0] + emit_note_hash(TEMPO_IN_FORCE, -1 - var(:lead_tempo))
            end
          end

          # Where the tempo in force as a time round starts is folded in: no note's offset.
          TEMPO_IN_FORCE = -0x4_0000

          # REPEATS: a TEMPO of the first track this tick, folded into the time round it falls in after
          # that round's start, as a note apart from every note (a sound under 0).
          def emit_lead_tempo_change
            tick = var(:tick)
            arrival = track_list(:arrival)[0]
            jump = track_list(:jump_tick)[0]
            var(:lead_tempo).store!(var(:tempo))
            if arrival >= 0
              if tick > arrival && tick < jump
                track_list(:first_sound)[0] = track_list(:first_sound)[0] + emit_note_hash(tick - arrival, -1 - var(:tempo))
              end
              if tick > jump && tick < (jump * 2) - arrival
                track_list(:second_sound)[0] = track_list(:second_sound)[0] + emit_note_hash(tick - jump, -1 - var(:tempo))
              end
            end
          end

          # LAPS: after a tick, the frame it plays on, what is left of the tempo's count and the
          # driver's memory folded into one number, where it starts a time round of the song
          # (var(:repeat_from) and every var(:lap) ticks after), up to MOST_LAPS past the first.
          def emit_lap_mark
            made = var(:marks_made)
            if var(:tick) == var(:repeat_from) + (made * var(:lap))
              list(:lap_frames, MOST_LAPS + 1)[made] = var(:frame)
              list(:lap_counts, MOST_LAPS + 1)[made] = var(:tempo_count)
              memory = var(:memory_folded)
              memory.store!(0)
              area = list(:memacc, MEMACC_BYTES)
              @block.repeat(MEMACC_BYTES) { |at| memory.store!(memory + emit_note_hash(at, area[at])) }
              list(:lap_memories, MOST_LAPS + 1)[made] = memory
              made.increase!(1)
              emit_song_end if made > MOST_LAPS
            end
          end

          # After REPEATS: the tick the song repeats from, var(:repeat_from), each track from its loop's
          # start where its two times round sound alike and else from its first jump, and from where a
          # track that ends falls silent; and one time round of it, var(:lap), the least span every
          # track's loop fits whole, MOST_LAP_TICKS at most.
          def emit_repeat_from
            from = var(:repeat_from)
            lap = var(:lap)
            start = var(:track_start)
            span = var(:loop_span)
            from.store!(var(:silent_from))
            lap.store!(1)
            @block.repeat(var(:track_count)) do |t|
              if track_list(:jump_tick)[t] >= 0
                start.store!(track_list(:arrival)[t])
                start.store!(track_list(:jump_tick)[t]) if start < 0 || track_list(:first_sound)[t] != track_list(:second_sound)[t]
                from.store!(start) if start > from
                span.store!(track_list(:jump_tick)[t] - track_list(:arrival)[t])
                emit_lap_fitting(lap, span) if track_list(:arrival)[t] >= 0 && span > 0
              end
            end
          end

          # +lap+ made the least span both it and +span+ fit whole (the larger over their greatest
          # common divisor, times the smaller), MOST_LAP_TICKS where that is more.
          def emit_lap_fitting(lap, span)
            larger = var(:gcd_larger)
            smaller = var(:gcd_smaller)
            left = var(:gcd_left)
            larger.store!(lap)
            smaller.store!(span)
            @block.repeat(LONGEST_DIVISOR_STEPS, stop_when: smaller == 0) do
              left.store!(larger % smaller)
              larger.store!(smaller)
              smaller.store!(left)
            end
            larger.store!(lap / larger)
            if larger > MOST_LAP_TICKS / span
              lap.store!(MOST_LAP_TICKS)
            else
              lap.store!(larger * span)
            end
          end

          # Euclid's steps for two numbers under 2^18 are fewer than this.
          LONGEST_DIVISOR_STEPS = 32

          # After LAPS: the song's length and its loop frame. The first time round that starts with the
          # tempo's count and the driver's memory as an earlier one did ends the song, coming round to
          # that one (a MEMACC can count times round in the memory, so that one round plays apart
          # from the next, and the song repeats only as the count does); failing that,
          # the third ends it, coming round to the second; with fewer marked, the second to the first;
          # with fewer still, MOST_FRAMES to the first, or to none.
          def emit_laps_timing
            made = var(:marks_made)
            frames = list(:lap_frames, MOST_LAPS + 1)
            counts = list(:lap_counts, MOST_LAPS + 1)
            memories = list(:lap_memories, MOST_LAPS + 1)
            first = var(:lap_first)
            again = var(:lap_again)
            first.store!(-1)
            again.store!(-1)
            @block.repeat(MOST_LAPS, stop_when: again >= 0) do |before|
              later = var(:lap_later)
              later.store!(before + 1)
              if later < made
                @block.repeat(later, stop_when: again >= 0) do |earlier|
                  if counts[earlier] == counts[later] && memories[earlier] == memories[later]
                    first.store!(earlier)
                    again.store!(later)
                  end
                end
              end
            end
            if again < 0
              if made > 2
                first.store!(1)
                again.store!(2)
              elsif made == 2
                first.store!(0)
                again.store!(1)
              end
            end
            if again >= 0
              var(:end_frame).store!(frames[again])
              var(:loop_frame).store!(frames[first])
            else
              var(:end_frame).store!(MOST_FRAMES)
              var(:loop_frame).store!(NO_LOOP)
              var(:loop_frame).store!(frames[0]) if made > 0
            end
          end
          SOUNDING_LISTS = %i[used gate key record start sequence].freeze
          # ...and in a voiced walk, what changes a sounding recorded note (#emit_change_sounding): the
          # key its voice was struck at before the track moved it, 1 where it is a recording and 1
          # where that recording plays at a fixed rate, the note's velocity and a drum's own pan, and
          # where its newest glide record is (-1 for none) and the frame that record starts.
          VOICED_SOUNDING_LISTS = %i[pitch_key recorded fixed velocity rhythm_pan glide_record glide_start].freeze

          # One tick of every track, in order (MPlayMain), and the song's end once none plays on. A
          # track counts as playing on a tick it starts playing, so the song stops on the tick after
          # its last track's FINE, as the driver stops it. Walking REPEATS, a track's notes still
          # sounding as it first jumps back are the first of its second time round, and the first
          # track's tempo as each time round starts is folded in after its reads.
          def emit_tick
            playing = var(:playing)
            playing.store!(0)
            active = track_list(:active)
            @block.repeat(var(:track_count), stop_when: var(:ended) == 1) do |t|
              if active[t] == 1
                playing.store!(1)
                emit_gates if @track && t == @track
                if @pass == :repeats && var(:tick) == track_list(:jump_tick)[t]
                  emit_held_notes_folded(t, var(:tick), track_list(:second_sound))
                end
                emit_commands(t)
                emit_lead_tempo_folded if @pass == :repeats && t == 0
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
              if @pass == :repeats && track_list(:arrival)[t] < 0 && track_list(:jump_tick)[t] >= 0 && place == track_list(:target)[t]
                emit_arrival(t)
              end
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
                stack = list(:stack, MOST_TRACKS * MOST_PATTERN_LEVELS)
                place.store!(stack[(t * MOST_PATTERN_LEVELS) + level[t]])
                stack[(t * MOST_PATTERN_LEVELS) + level[t]] = 0
              end
            elsif command == REPT
              emit_repeat(t)
            elsif command == MEMACC
              emit_memacc
            elsif command == TEMPO
              var(:tempo).store!(arg * 2)
              emit_lead_tempo_change if @pass == :repeats && t == 0
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
            emit_change_sounding(t) if @voiced && sounding_change_test(command, t)
          end

          # The test the routine makes of whether +command+ is one of +codes+.
          def command_in_test(command, codes)
            codes.map { |code| command == code }.reduce { |either, test| either | test }
          end

          # ...of whether it is one of DROPPED_ONE_BYTE.
          def dropped_command_test(command) = command_in_test(command, DROPPED_ONE_BYTE)

          # ...and of whether it changes track +t+'s sounding notes (TrkVolPitSet's keyM, pitM, and the
          # sides: KEYSH, BEND, BENDR, TUNE, VOL, PAN), on the walked track.
          def sounding_change_test(command, t) = command_in_test(command, SOUNDING_CHANGE_COMMANDS) & (t == @track)

          # FINE (ply_fine): the track stops, and lets go of its notes. Walking first jumps, where it
          # falls silent is kept: now, or where its last note ends.
          def emit_fine(t)
            if @pass == :first_jumps && track_list(:active)[t] == 1
              silent = var(:silent_at)
              silent.store!(var(:tick))
              silent.store!(track_list(:held_until)[t]) if track_list(:held_until)[t] > silent
              var(:silent_from).store!(silent) if silent > var(:silent_from)
            end
            track_list(:active)[t] = 0
            emit_release_all if @track && t == @track
          end

          # GOTO (ply_goto) to the address at +place+. Walking first jumps, a track's first jump back
          # is kept: on which tick, and where to (a song comes round).
          def emit_jump_back(t, place)
            target = var(:target)
            target.store!(address_at(place))
            if @pass == :first_jumps && target < place && track_list(:jump_tick)[t] < 0
              track_list(:jump_tick)[t] = var(:tick)
              track_list(:target)[t] = target
              var(:looped_count).increase!(1)
            end
            place.store!(target)
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
            emit_tie_let_go(t) if @pass == :repeats
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
            if @pass == :first_jumps && var(:tick) + gate > track_list(:held_until)[t]
              track_list(:held_until)[t] = var(:tick) + gate
            end
            emit_note_kept(t, gate) if @pass == :repeats
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
            if @voiced # what the note was struck at before the track moves it, for #emit_change_sounding
              var(:pitch_key).store!(key)
              var(:struck_velocity).store!(track_list(:velocity)[t])
            end
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
            emit_voice_settings(t, channel, at) if @voiced
            emit_sounding(t, at)
            emit_changeable_note(channel) if @voiced
          end

          # A voiced record's settings (Original::PackNote's bytes 12 on), from the voice's twelve
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
          # unpack_m4a_voice). It names instead where it sits between the speakers and a pitch
          # between keys (#emit_recorded_settings).
          def emit_voice_settings(t, channel, at)
            voice = var(:sounding_voice)
            names = var(:voiced_names)
            duty = var(:voiced_duty)
            slide = var(:voiced_slide)
            fade = var(:voiced_fade)
            shade = var(:voiced_shade)
            hz = var(:voiced_hz)
            [names, duty, slide, fade, shade, hz].each { |each| each.store!(0) }
            emit_recorded_settings(t, shade, hz, names) if channel == KIND_RECORDING
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
            # The pitch number, the fade, the duty, the vibrato, the slide, the shade, the names, the hz.
            [0, 0, fade, duty, 0, 0, slide, shade, names, names >> 8, hz, hz >> 8, hz >> 16].each { |byte| @block.write(byte) }
            @block.repeat(PackNote::VOICED_BYTES - PackNote::BYTES - VOICED_WRITTEN) { @block.write(0) }
          end

          # The bytes of a voiced record's settings #emit_voice_settings writes, up to the hz's last.
          VOICED_WRITTEN = 13
          # Where in a voiced record its key, loudness, shade, names and hz are (Original::PackNote).
          RECORD_KEY = 4
          RECORD_LOUDNESS = 8
          RECORD_SHADE = 19
          RECORD_NAMES = 20
          RECORD_HZ = 22

          # A recorded note's speakers and pitch, into +shade+, +hz+ and +names+: where it sits
          # between the speakers (#emit_shade), and a pitch between keys (#emit_pitch_hz) where TUNE
          # and BEND leave one, or a key past 127, which the key byte cannot name. A recording played
          # at a fixed rate has no pitch to move.
          def emit_recorded_settings(t, shade, hz, names)
            emit_shade(var(:right), var(:left), shade, names)
            emit_pitch_hz(t, var(:pitch_key), hz, names) if (var(:voice_kind) & FIXED_RATE) == 0
          end

          # Where a recorded note sits between the speakers, into +shade+, with shade set in +names+,
          # from the two sides ChnVolSetAsm works out (#emit_sides), +right+ and +left+: Audio::Pan
          # keeps the near side whole and turns the far side down by how far off the middle it sits,
          # so the shade is the share of the near side the far side lacks, in 64ths, rounded, to the
          # left below 0. A note in the middle names none. Its loudness stays the two sides added, as
          # the Advance's one mix plays it.
          def emit_shade(right, left, shade, names)
            near = var(:near_side)
            far = var(:far_side)
            near.store!(right)
            near.store!(left) if left > right
            far.store!(right + left - near)
            if near > 0
              shade.store!((((near - far) * PackNote::MOST_SHADE) + (near >> 1)) / near)
              shade.store!(0 - shade) if left > right
              names.store!(names | PackNote::NAMES.fetch(:shade)) if shade != 0
            end
          end

          # The pitch a note of track +t+ struck at +raw+ plays at now, into +hz+, in 16ths of a hertz,
          # with HZ set in +names+, where it is not a whole key the record's key byte can name:
          # TrkVolPitSet's keyM and pitM (#emit_key_moved) added to the key, read as MidiKeyToFreq
          # reads it, on a straight line between two keys by 256ths. A key past MOST_DRIVER_KEY is
          # that key and 255 256ths. Leaves +hz+ and +names+ alone for a whole key up to 127.
          # The key it comes to is in var(:moved_key).
          def emit_pitch_hz(t, raw, hz, names)
            moved = var(:moved)
            key = var(:moved_key)
            fine = var(:fine_pitch)
            key_hz = list(:key_hz, KEY_HZ.length)
            moved.store!(((track_list(:tune)[t] + (track_list(:bend)[t] * track_list(:bend_range)[t])) * 4) +
                         (track_list(:shift)[t] * 256))
            key.store!(raw + (moved >> 8))
            fine.store!(moved & FINE_BITS)
            if key < 0
              key.store!(0)
              fine.store!(0)
            end
            if key > MOST_DRIVER_KEY
              key.store!(MOST_DRIVER_KEY)
              fine.store!(FINE_BITS)
            end
            if fine != 0 || key > MOST_KEY
              hz.store!(key_hz[key] + (((key_hz[key + 1] - key_hz[key]) * fine) >> 8))
              names.store!(names | PackNote::NAMES.fetch(:hz))
            end
          end

          # The note just struck kept for changing as it sounds, in the place #emit_sounding found it
          # (var(:free)): it is the part's newest, which a pitch, VOL or PAN command changes
          # (#emit_change_sounding). What ChnVolSetAsm works its sides out from again is the note's own:
          # its velocity and a drum's own pan.
          def emit_changeable_note(channel)
            free = var(:free)
            var(:newest_sounding).store!(free)
            if free >= 0
              sounding_list(:pitch_key)[free] = var(:pitch_key)
              recorded = sounding_list(:recorded)
              recorded[free] = 0
              recorded[free] = 1 if channel == KIND_RECORDING
              fixed = sounding_list(:fixed)
              fixed[free] = 0
              fixed[free] = 1 if (var(:voice_kind) & FIXED_RATE) != 0
              sounding_list(:velocity)[free] = var(:struck_velocity)
              sounding_list(:rhythm_pan)[free] = var(:rhythm_pan)
              sounding_list(:glide_record)[free] = -1
            end
          end

          # A pitch, vol or pan command while the part's note sounds (keysh, bend, bendr, tune, vol,
          # PAN): the driver moves the track's sounding notes too (MPlayMain calls MidiKeyToFreq and
          # ChnVolSetAsm for each of them after TrkVolPitSet), and a part sounds its newest, so that one
          # is changed, with a gliding record (Original::PackNote's GLIDES: `glides: true`) at its pitch,
          # loudness and side now: the key, the hz where it is between keys, the two sides added, and the
          # shade. A recording at a fixed rate keeps its pitch (its own note, key 60). A glide already on
          # this frame, or the note struck on it, is written again, so a part has one event a frame. Its
          # length is given as the note is let go (#emit_release). A note on a console voice is changed
          # by the driver too, which the song model does not glide, so it is left as it was struck.
          def emit_change_sounding(t)
            s = var(:newest_sounding)
            if s >= 0
              if sounding_list(:recorded)[s] == 1
                right = var(:right)
                left = var(:left)
                hz = var(:glide_hz)
                names = var(:glide_names)
                shade = var(:glide_shade)
                key = var(:moved_key)
                emit_sides_for_note(t, sounding_list(:velocity)[s], sounding_list(:rhythm_pan)[s], right, left)
                [hz, names, shade].each { |each| each.store!(0) }
                emit_shade(right, left, shade, names)
                names.store!(names | PackNote::NAMES.fetch(:shade)) # a glide names its side, the middle too
                if sounding_list(:fixed)[s] == 1
                  key.store!(OWN_KEY)
                else
                  emit_pitch_hz(t, sounding_list(:pitch_key)[s], hz, names)
                  key.store!(MOST_KEY) if key > MOST_KEY
                end
                loudness = var(:glide_loudness)
                loudness.store!(right + left)
                change = SoundingChange.new(key: key, loudness: loudness, shade: shade, hz: hz, names: names)
                glide = sounding_list(:glide_record)[s]
                if glide >= 0 && sounding_list(:glide_start)[s] == var(:frame)
                  emit_rewritten_record(glide, change, PackNote::NAMES.fetch(:glides))
                elsif glide < 0 && sounding_list(:start)[s] == var(:frame)
                  emit_rewritten_record(sounding_list(:record)[s], change, 0)
                else
                  emit_glide_record(s, change)
                end
              end
            end
          end

          # What a sounding note plays now (#emit_change_sounding): its key, its loudness (the two
          # sides added), its shade, its hz, and the names a voiced record gives them.
          SoundingChange = Data.define(:key, :loudness, :shade, :hz, :names)

          # The record at +at+ written again as +change+ says, its names those and +more_names+.
          def emit_rewritten_record(at, change, more_names)
            names = change.names | more_names
            @block.rewrite(at + RECORD_KEY, change.key)
            @block.rewrite(at + RECORD_LOUDNESS, change.loudness)
            @block.rewrite(at + RECORD_LOUDNESS + 1, change.loudness >> 8)
            @block.rewrite(at + RECORD_SHADE, change.shade)
            @block.rewrite(at + RECORD_NAMES, names)
            @block.rewrite(at + RECORD_NAMES + 1, names >> 8)
            @block.rewrite(at + RECORD_HZ, change.hz)
            @block.rewrite(at + RECORD_HZ + 1, change.hz >> 8)
            @block.rewrite(at + RECORD_HZ + 2, change.hz >> 16)
          end

          # A gliding record for sounding note +s+ on this frame, as +change+ says: its instrument and
          # volume the part's own, since it reads on the recording the note struck.
          def emit_glide_record(s, change)
            at = var(:record_at)
            frame = var(:frame)
            names = change.names | PackNote::NAMES.fetch(:glides)
            at.store!(@block.written)
            [frame, frame >> 8, 0, 0, change.key, PackNote::PART_OWN, PackNote::PART_OWN, PackNote::PART_OWN,
             change.loudness, change.loudness >> 8, PackNote::PART_OWN, 0,
             0, 0, 0, 0, 0, 0, 0, change.shade, names, names >> 8, change.hz, change.hz >> 8,
             change.hz >> 16].each { |byte| @block.write(byte) }
            @block.repeat(PackNote::VOICED_BYTES - RECORD_HZ - 3) { @block.write(0) }
            sounding_list(:glide_record)[s] = at
            sounding_list(:glide_start)[s] = frame
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
          def emit_sides(t, right, left) = emit_sides_for_note(t, track_list(:velocity)[t], var(:rhythm_pan), right, left)

          # ...for a note of +velocity+ and a drum's own pan +side_pan+, on track +t+ as it is now.
          def emit_sides_for_note(t, velocity, side_pan, right, left)
            x = var(:volume_x)
            y = var(:pan_y)
            x.store!((track_list(:volume)[t] * STARTING_VOLUME_X) >> 5)
            y.store!(track_list(:pan)[t] * 2)
            y.store!(-128) if y < -128
            y.store!(127) if y > 127
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
            emit_record_length(sounding_list(:record)[s], sounding_list(:start)[s])
            sounding_list(:used)[s] = 0
            emit_release_glide(s) if @voiced
          end

          # The record at +record+, which started on frame +start+, given the frames since, one at least.
          def emit_record_length(record, start)
            length = var(:length)
            length.store!(var(:frame) - start)
            length.store!(1) if length < 1
            @block.rewrite(record + 2, length)
            @block.rewrite(record + 3, length >> 8)
          end

          # ...and in a voiced walk, its newest glide given the frames since it started, and the
          # part's newest note gone where this was it.
          def emit_release_glide(s)
            glide = sounding_list(:glide_record)[s]
            if glide >= 0
              emit_record_length(glide, sounding_list(:glide_start)[s])
              sounding_list(:glide_record)[s] = -1
            end
            var(:newest_sounding).store!(-1) if var(:newest_sounding) == s
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
        # Track writes them, each with its console voice's duty, slide and fade (Walk#emit_voice_settings),
        # or a recording's side and pitch, and a gliding record for each bend while it sounds (M4A, A
        # recording's note, voiced).
        module VoicedTrack
          extend Format
          unpacks :m4a_voiced_track, track: 0, kind: ANY_KIND, kit_from: KIT_AND_SPLIT_NUMBERS_FROM,
                                     split_from: KIT_AND_SPLIT_NUMBERS_FROM
          called "MusicPlayer2000 track with its voices' settings"

          def self.routine(block) = M4A.emit_track(block, voiced: true)
        end

        # The song's length and loop frame (a song comes round) into the routine's variables
        # m4a_end_frame and m4a_loop_frame, walked with +lists+.
        def self.emit_song_timing(block, lists)
          Walk.new(block, lists, pass: :first_jumps).emit
          if block.variable(:m4a_looped_count) == 0
            block.variable(:m4a_end_frame).store!(block.variable(:m4a_frame))
            block.variable(:m4a_loop_frame).store!(NO_LOOP)
          else
            Walk.new(block, lists, pass: :repeats).emit
            laps = Walk.new(block, lists, pass: :laps)
            laps.emit_repeat_from
            laps.emit
            laps.emit_laps_timing
          end
        end

        # The walk of a track writing its records, +voiced+ or not, to the song's length, then the
        # record that ends the part.
        def self.emit_track(block, voiced:)
          record_bytes = voiced ? PackNote::VOICED_BYTES : PackNote::BYTES
          lists = {}
          emit_song_timing(block, lists)
          stop_frame = block.variable(:m4a_stop_frame)
          stop_frame.store!(-1)
          stop_frame.store!(block.variable(:m4a_end_frame)) if block.variable(:m4a_loop_frame) != NO_LOOP
          Walk.new(block, lists, pass: :notes, track: block.setting(:track), kind: block.setting(:kind),
                                 kit_from: block.setting(:kit_from), split_from: block.setting(:split_from), voiced: voiced).emit
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
            M4A.emit_song_timing(block, {})
            length = block.variable(:m4a_end_frame)
            loop_frame = block.variable(:m4a_loop_frame)
            block.write(length)
            block.write(length >> 8)
            block.write(loop_frame)
            block.write(loop_frame >> 8)
          end
        end

        # Where a voice's recording is (its WaveData): the voice's place at at:, a recording's voice,
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

          # The wave voice's pattern (a voice of KIND_WAVE): the sixteen bytes its second word
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
