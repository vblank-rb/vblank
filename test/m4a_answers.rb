# frozen_string_literal: true

# The answer key for the Advance's common sound driver (Original::Packing::M4A): a made-up song of
# VBlank's own in MusicPlayer2000's form, written by a small assembler, and a player that plays it
# as the driver does, written in plain Ruby from the driver's source (tmc's asm/lib/m4a_asm.s:
# MPlayMain, ply_note, ChnVolSetAsm, ply_goto, ply_patt, ply_pend, ply_rept, ply_endtie and the rest;
# src/gba/m4a.c: MPlayStart, TrkVolPitSet, MidiKeyToCgbFreq, CgbPan, CgbModVol, ply_memacc,
# ply_xcmd, gClockTable and gNoiseTable). It says what each track's records, the song's length and
# loop, and each recording are, for the unpacking's routine to be held to.
module M4AAnswers
  ROM = 0x0800_0000
  CLOCKS = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 28, 30, 32, 36, 40,
            42, 44, 48, 52, 54, 56, 60, 64, 66, 68, 72, 76, 78, 80, 84, 88, 90, 92, 96].freeze
  NOISE_TABLE = [0xD7, 0xD6, 0xD5, 0xD4, 0xC7, 0xC6, 0xC5, 0xC4, 0xB7, 0xB6, 0xB5, 0xB4, 0xA7, 0xA6, 0xA5,
                 0xA4, 0x97, 0x96, 0x95, 0x94, 0x87, 0x86, 0x85, 0x84, 0x77, 0x76, 0x75, 0x74, 0x67, 0x66,
                 0x65, 0x64, 0x57, 0x56, 0x55, 0x54, 0x47, 0x46, 0x45, 0x44, 0x37, 0x36, 0x35, 0x34, 0x27,
                 0x26, 0x25, 0x24, 0x17, 0x16, 0x15, 0x14, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x00].freeze
  OWN = 255

  # The command bytes, as m4a's own song files name them.
  CODES = { fine: 0xB1, goto: 0xB2, patt: 0xB3, pend: 0xB4, rept: 0xB5, memacc: 0xB9, prio: 0xBA, tempo: 0xBB, keysh: 0xBC,
            voice: 0xBD, vol: 0xBE, pan: 0xBF, bend: 0xC0, bendr: 0xC1, lfos: 0xC2, lfodl: 0xC3, mod: 0xC4, modt: 0xC5,
            tune: 0xC8, port: 0xCC, xcmd: 0xCD, eot: 0xCE, tie: 0xCF }.freeze

  # A note or wait of +ticks+, which must be one of clocks.
  def self.note_code(ticks) = 0xCF + CLOCKS.index(ticks)
  def self.wait_code(ticks) = 0x80 + CLOCKS.index(ticks)

  # --- the made-up copy ------------------------------------------------------------------------
  COPY_SIZE = 0x1000
  SONG_AT = 0x020
  ENDING_SONG_AT = 0x040
  GROUP_AT = 0x060              # eight voices
  SPLIT_GROUP_AT = 0x0C0        # two voices a key split picks from
  SPLIT_TABLE_AT = 0x0E0        # 128 bytes
  KIT_AT = 0x160                # a drum kit's voices, 12 bytes a key, keys 0, 1, 36 and 38 written
  TIES_SONG_AT = 0x580          # ties let go by EOT at a tempo that is not a tick a frame
  DRIFT_SONG_AT = 0x590        # a late part at a tempo whose count never comes back in a few times round
  APART_SONG_AT = 0x5A0         # a song whose tracks' loops do not divide each other
  LATE_SONG_AT = 0x5B0          # a song with a track that first sounds after a short track's many rounds
  MIXED_SONG_AT = 0x5C0        # a song whose tracks switch between plain voices, the kit and the split
  ROUNDS_SONG_AT = 0x5D0        # a song whose tracks come round at different points
  WAVE_AT = 0x600               # a recording that loops
  ONE_SHOT_AT = 0x660           # one that does not
  TRACKS_AT = 0x700

  # The voices: a recording, the two squares, the wave, the noise, a key split (low keys the
  # recording, from key 60 the second square), a drum kit, and a recording at a fixed rate. The
  # first square slides down (its sweep byte), and the noise swells in (its attack).
  WAVE_PATTERN_AT = 0x5F0
  WAVE_PATTERN = [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10].freeze
  VOICES = [[0x00, 60, 0, 0, ROM + WAVE_AT, [255, 0, 255, 165]], [0x01, 60, 0, 0x2B, 2, [0, 0, 15, 0]],
            [0x02, 60, 0, 0, 1, [0, 1, 12, 2]], [0x03, 60, 0, 0, ROM + WAVE_PATTERN_AT, [0, 0, 15, 0]],
            [0x04, 60, 0, 0, 0, [3, 2, 0, 0]],
            [0x40, 0, 0, 0, ROM + SPLIT_GROUP_AT, ROM + SPLIT_TABLE_AT], [0x80, 0, 0, 0, ROM + KIT_AT, [0, 0, 0, 0]],
            [0x08, 60, 0, 0, ROM + ONE_SHOT_AT, [255, 40, 200, 10]]].freeze
  SPLIT_VOICES = [[0x00, 60, 0, 0, ROM + WAVE_AT, [200, 10, 180, 100]], [0x02, 60, 0, 0, 3, [0, 0, 10, 0]]].freeze
  # The kit's key 36 is the recording, panned to the left side's half (rhythm pan), at key 64; key
  # 38 is the noise voice at key 50. Keys 0 and 1 share their numbers with voices of the group: key
  # 0 is the recording that does not loop, at a fixed rate and shaped its own way, and key 1 the
  # one that loops, panned right a little, at key 72.
  KIT_VOICES = { 0 => [0x08, 60, 0, 0, ROM + ONE_SHOT_AT, [255, 0, 128, 0]], 1 => [0x00, 72, 0, 0xD0, ROM + WAVE_AT, [255, 0, 200, 50]],
                 36 => [0x00, 64, 0, 0xA0, ROM + WAVE_AT, [255, 0, 255, 0]], 38 => [0x04, 50, 0, 0, 0, [0, 1, 0, 0]] }.freeze
  WAVE_SAMPLES = (0...32).map { |at| ((at * 23) % 200) - 100 }.freeze
  ONE_SHOT_SAMPLES = (0...24).map { |at| ((at * 41) % 180) - 90 }.freeze
  WAVE_RATE = 13_379
  ONE_SHOT_RATE = 8000
  WAVE_LOOP = 8

  # Each track as commands, assembled with labels. A command is [name, bytes...]; [:note, ticks,
  # key, velocity, extra] leaves out what is nil; [:wait, ticks]; [:bytes, ...] for running status;
  # [:label, name]; an address is a label's name.
  TRACKS = [
    # Track 0: the tempo, a recording, notes with running status, a pattern, a repeat, a tie, the
    # commands kept and the ones dropped, the driver's memory and a jump on it, then back.
    [[:tempo, 100], [:prio, 3], [:voice, 0], [:vol, 100], [:pan, 0x40], [:keysh, 2], [:bendr, 4], [:lfos, 30], [:lfodl, 2],
     [:mod, 0], [:modt, 0], [:note, 12, 60, 110], [:wait, 12], [:bytes, 62, 90], [:wait, 6], [:bytes, 64], [:wait, 6],
     [:label, :loop], [:patt, :pattern], [:label, :figure], [:note, 2, 69], [:wait, 2], [:rept, 2, :figure],
     [:tie, 67, 100], [:wait, 8], [:eot], [:tie, 66, 100], [:bend, 0x60], [:note, 4, 71, 80, 2], [:wait, 8], [:eot, 66],
     [:bend, 0x40], [:tune, 0x30], [:note, 6, 72], [:wait, 6], [:memacc, 0, 5, 3], [:memacc, 1, 6, 2], [:memacc_jump, 7, 5, 3, :after],
     [:memacc_jump, 6, 5, 3, :after], [:note, 3, 40, 127], [:wait, 3],
     [:label, :after], [:vol, 90], [:bytes, 95], [:xcmd, 4, 200], [:xcmd, 1, 0, 0, 0, 0], [:port, 0x10, 0x20], [:tune, 0x40],
     [:keysh, 0xFE], [:note, 6, 60], [:wait, 6], [:goto, :loop],
     [:label, :pattern], [:vol, 80], [:note, 3, 65, 70], [:wait, 3], [:bytes, 67], [:wait, 3], [:pend]],
    # Track 1: the squares and the wave, panned to each side and back, a chord, a key split, then back.
    [[:voice, 1], [:vol, 127], [:pan, 0x10], [:note, 6, 72, 127], [:wait, 6], [:pan, 0x70], [:voice, 2], [:note, 6, 30, 90],
     [:wait, 6], [:pan, 0x40], [:voice, 3], [:note, 12, 55, 60], [:note, 12, 59, 60], [:wait, 12], [:label, :again],
     [:voice, 5], [:note, 6, 48, 100], [:wait, 6], [:note, 6, 64, 100], [:wait, 6], [:wait, 64], [:goto, :again]],
    # Track 2: the drum kit's recording and noise, and the recording at a fixed rate. Its loop and
    # track 1's are 76 ticks, twice track 0's, so the three come round together.
    [[:voice, 6], [:vol, 90], [:note, 4, 36, 120], [:wait, 6], [:note, 4, 38, 100], [:wait, 6], [:voice, 4], [:note, 3, 10, 127],
     [:wait, 3], [:note, 3, 90, 127], [:wait, 3], [:voice, 7], [:note, 8, 50, 64], [:wait, 8], [:label, :drums], [:voice, 6],
     [:note, 2, 38, 127], [:wait, 2], [:wait, 36], [:wait, 36], [:wait, 2], [:rept, 0, :drums]]
  ].freeze
  # A song that ends: its tracks run to their end, the second later than the first; the first holds
  # a tie as it ends with an XCMD the driver's table sends to fine, the second jumps forward past a
  # note, and the third names no voice, so it plays the first square.
  ENDING_TRACKS = [[[:voice, 1], [:vol, 127], [:note, 8, 70, 100], [:wait, 8], [:tie, 74, 100], [:wait, 4], [:xcmd, 0]],
                   [[:voice, 2], [:vol, 64], [:wait, 6], [:goto, :ahead], [:note, 12, 50, 90], [:label, :ahead],
                    [:note, 24, 60, 90], [:wait, 24], [:fine]],
                   [[:vol, 100], [:note, 6, 66, 100], [:wait, 6], [:fine]]].freeze
  # A song whose tracks switch voices, so a voice of the group, a key of the kit and a voice of the
  # split each have the number 0 in their own table: the first track plays the group's recording,
  # the kit's keys 0 and 1, the group's voice 7 and the recording again; the second the recording,
  # the kit's key 0, the split's recording (key 48) and its square (key 64), and the recording again.
  MIXED_TRACKS = [[[:voice, 0], [:vol, 100], [:note, 6, 60, 100], [:wait, 6], [:voice, 6], [:note, 6, 0, 110], [:wait, 6],
                   [:note, 6, 1], [:wait, 6], [:voice, 7], [:note, 6, 50], [:wait, 6], [:voice, 0], [:note, 6, 62], [:wait, 6], [:fine]],
                  [[:voice, 0], [:vol, 100], [:note, 6, 60, 100], [:wait, 6], [:voice, 6], [:note, 6, 0], [:wait, 6], [:voice, 5],
                   [:note, 6, 48], [:wait, 6], [:note, 6, 64], [:wait, 6], [:voice, 0], [:note, 6, 62], [:wait, 6], [:fine]]].freeze
  # A song whose tracks come round at different points, at a tempo that lands a tick on three
  # quarters of a frame. The first square's track goes round every 6 ticks from its start, counting
  # its rounds in the driver's memory and playing every second one a fifth higher; the second
  # square's plays a note once, then goes round every 18 ticks, so each of its rounds lasts
  # thirteen and a half frames and the second starts a frame later in the count than the first.
  # The two come round together every 36 ticks, 27 frames, from the end of the second's first round.
  ROUNDS_TRACKS = [[[:tempo, 100], [:voice, 1], [:vol, 127], [:label, :round], [:memacc, 1, 0, 1],
                    [:memacc_jump, 6, 0, 2, :second], [:note, 3, 60, 100], [:wait, 6], [:goto, :round],
                    [:label, :second], [:memacc, 0, 0, 0], [:note, 3, 67, 100], [:wait, 6], [:goto, :round]],
                   [[:voice, 2], [:vol, 100], [:note, 4, 50, 90], [:wait, 6], [:label, :round], [:note, 8, 72, 110],
                    [:wait, 9], [:note, 4, 76], [:wait, 9], [:goto, :round]]].freeze
  # A song with a part that comes in late, a tick a frame. The first square's track goes round every
  # 6 ticks from its start; the second square's waits 96 ticks, then goes round every 12, so the first
  # has gone round sixteen times before the second sounds at all.
  LATE_TRACKS = [[[:voice, 1], [:vol, 127], [:label, :round], [:note, 6, 60, 100], [:wait, 6], [:goto, :round]],
                 [[:voice, 2], [:vol, 100], [:wait, 96], [:label, :round], [:note, 12, 72, 110], [:wait, 12],
                  [:goto, :round]]].freeze
  # The same shape at a tempo of 41 (82 added to the count a frame, so a tick lands on fewer than
  # two frames in three): the first track goes round every 6 ticks, the second is silent for 192,
  # then goes round every 48 with two notes. Each 48 ticks leave the count 16 further on, out of 82,
  # so it does not come back for 41 times round.
  DRIFT_TRACKS = [[[:tempo, 41], [:voice, 1], [:vol, 127], [:label, :round], [:note, 6, 60, 100], [:wait, 6], [:goto, :round]],
                  [[:voice, 2], [:vol, 100], [:wait, 96], [:wait, 96], [:label, :round], [:note, 24, 72, 110], [:wait, 24],
                   [:note, 24, 76], [:wait, 24], [:goto, :round]]].freeze
  # Ties let go by EOT at a tempo that is not a tick a frame. The first track opens at a tempo of 250
  # for 96 ticks, several a frame, then sets 76 (152 added to the count a frame, a tick on a little
  # under a frame) and goes round every 24 ticks. The second ties key 47 on tick 108 and lets it go
  # with an EOT naming no key on tick 214; then ties key 50 and lets it go with an EOT naming it.
  TIES_TRACKS = [[[:tempo, 250], [:voice, 1], [:vol, 100], [:wait, 96], [:tempo, 76], [:label, :round], [:note, 12, 60, 100],
                  [:wait, 24], [:goto, :round]],
                 [[:voice, 0], [:vol, 100], [:wait, 96], [:wait, 12], [:tie, 47, 127], [:wait, 84], [:wait, 22],
                  [:eot], [:wait, 2], [:tie, 50, 100], [:wait, 48], [:eot, 50], [:note, 24, 52, 90], [:wait, 24],
                  [:label, :round], [:note, 12, 55], [:wait, 12], [:goto, :round]]].freeze
  # Two loops apart, a tick a frame: the first track goes round every 6 ticks from its start, the
  # second every 9 from tick 12, so they come round together every 18.
  APART_TRACKS = [[[:voice, 1], [:vol, 127], [:label, :round], [:note, 3, 60, 100], [:wait, 6], [:goto, :round]],
                  [[:voice, 2], [:vol, 100], [:wait, 12], [:label, :round], [:note, 4, 67, 90], [:wait, 9],
                   [:goto, :round]]].freeze
  # A song whose recorded notes sit off the middle and are changed while they sound, a tick a frame.
  # The first track, left of the middle: a long note whose bend moves it whole keys (BENDR 12 is
  # three keys a step of 16), then two BENDs on one tick, a tune between keys, a KEYSH; then a note
  # bent on the tick it is struck; a recording at a fixed rate, which no bend moves; a note on the
  # right after a PAN, made quieter (VOL) and moved to the left (PAN) as it sounds; and a square
  # note, bent too, which a glide cannot move. The second track is the drum kit, whose voices sit
  # where their own pan puts them.
  BENDING_SONG_AT = 0x5E0
  BENDING_TRACKS = [[[:voice, 0], [:vol, 100], [:pan, 0x20], [:bendr, 12], [:note, 24, 60, 100], [:wait, 4], [:bend, 0x50],
                     [:wait, 4], [:bend, 0x60], [:bend, 0x58], [:wait, 4], [:tune, 0x44], [:wait, 4], [:keysh, 1], [:wait, 8],
                     [:bend, 0x40], [:tune, 0x40], [:keysh, 0], [:note, 6, 62, 100], [:bend, 0x41], [:wait, 6], [:bend, 0x40],
                     [:voice, 7], [:note, 6, 50], [:wait, 2], [:bend, 0x50], [:wait, 4], [:bend, 0x40], [:pan, 0x70], [:voice, 0],
                     [:note, 6, 64], [:wait, 2], [:vol, 70], [:wait, 2], [:pan, 0x10], [:wait, 2], [:voice, 1], [:note, 6, 72],
                     [:wait, 2], [:bend, 0x48], [:wait, 4], [:fine]],
                    [[:voice, 6], [:vol, 90], [:note, 4, 36, 120], [:wait, 6], [:note, 4, 1, 100], [:wait, 6], [:fine]]].freeze

  # The number a kit's or a split's first voice is given, past the 128 a voice names (Packing::M4A).
  KIT_AND_SPLIT_NUMBERS_FROM = 128
  # The recorded voices the mixed song plays, each where its twelve bytes are, as a port names them.
  MIXED_VOICES = { looped: GROUP_AT, one_shot: GROUP_AT + (12 * 7), kit_one_shot: KIT_AT, kit_wave: KIT_AT + 12,
                   split_wave: SPLIT_GROUP_AT }.freeze
  # The numbers a kit's and a split's first voice are given: the reader's kit_from: and
  # split_from:, which `to_h` hands it.
  Numbering = Data.define(:kit_from, :split_from) do
    def initialize(kit_from: KIT_AND_SPLIT_NUMBERS_FROM, split_from: KIT_AND_SPLIT_NUMBERS_FROM) = super
  end
  # The mixed song's tracks as a port reads them, each a recorded part: the track, the reader's
  # numbering, and the instruments: list the part names, by those numbers.
  MixedPart = Data.define(:track, :numbering, :instruments)
  MIXED_PARTS = [MixedPart.new(track: 0, numbering: Numbering.new(kit_from: 1),
                               instruments: %i[looped kit_one_shot kit_wave looped looped looped looped one_shot]),
                 MixedPart.new(track: 1, numbering: Numbering.new(kit_from: 1, split_from: 2),
                               instruments: %i[looped kit_one_shot split_wave])].freeze

  def self.address_bytes(place) = [ROM + place].pack("V").bytes

  def self.voice_bytes((kind, key, length, pan, wave, shape))
    [kind, key, length, pan, wave].pack("C4V") + (shape.is_a?(Array) ? shape.pack("C4") : [shape].pack("V"))
  end

  def self.wave_bytes(samples, rate, loop_from)
    [0, loop_from ? 0x4000 : 0, rate * 1024, loop_from || 0, samples.length].pack("v2V3") + samples.pack("c*")
  end

  # The made-up copy, and where each track of +tracks+ went.
  def self.copy_with(tracks_of)
    copy = "\0".b * COPY_SIZE
    at = TRACKS_AT
    tracks_of.each do |song_at, tracks|
      places = tracks.map do |track|
        bytes, = labels_then_bytes(track, at)
        copy[at, bytes.length] = bytes.pack("C*")
        place = at
        at += bytes.length + 1
        place
      end
      copy[song_at, 8 + (4 * places.length)] = [places.length, 0, 4, 0, ROM + GROUP_AT, *places.map { |place| ROM + place }].pack("C4V*")
    end
    VOICES.each_with_index { |voice, n| copy[GROUP_AT + (12 * n), 12] = voice_bytes(voice) }
    SPLIT_VOICES.each_with_index { |voice, n| copy[SPLIT_GROUP_AT + (12 * n), 12] = voice_bytes(voice) }
    copy[SPLIT_TABLE_AT, 128] = (0...128).map { |key| key < 60 ? 0 : 1 }.pack("C*")
    KIT_VOICES.each { |key, voice| copy[KIT_AT + (12 * key), 12] = voice_bytes(voice) }
    copy[WAVE_AT, 16 + WAVE_SAMPLES.length] = wave_bytes(WAVE_SAMPLES, WAVE_RATE, WAVE_LOOP)
    copy[ONE_SHOT_AT, 16 + ONE_SHOT_SAMPLES.length] = wave_bytes(ONE_SHOT_SAMPLES, ONE_SHOT_RATE, nil)
    copy[WAVE_PATTERN_AT, 16] = WAVE_PATTERN.pack("C*")
    copy
  end

  # Labels need the bytes before them, so a track is laid out twice: once to find them.
  def self.labels_then_bytes(track, at)
    labels = {}
    bytes = nil
    2.times do
      bytes = []
      track.each do |name, *args|
        labels[args[0]] = at + bytes.length if name == :label
        bytes.concat(command_bytes(name, args, labels))
      end
    end
    [bytes, labels]
  end

  def self.command_bytes(name, args, labels)
    address = ->(label) { address_bytes(labels.fetch(label, 0)) }
    case name
    when :label then []
    when :note then [note_code(args[0]), *args.drop(1).compact]
    when :tie then [CODES.fetch(:tie), *args]
    when :wait then [wait_code(args[0])]
    when :bytes then args
    when :goto, :patt then [CODES.fetch(name), *address.(args[0])]
    when :rept then [CODES.fetch(:rept), args[0], *address.(args[1])]
    when :memacc_jump then [CODES.fetch(:memacc), *args.first(3), *address.(args[3])]
    else [CODES.fetch(name), *args]
    end
  end

  COPY = copy_with({ SONG_AT => TRACKS, ENDING_SONG_AT => ENDING_TRACKS, MIXED_SONG_AT => MIXED_TRACKS,
                     ROUNDS_SONG_AT => ROUNDS_TRACKS, BENDING_SONG_AT => BENDING_TRACKS, LATE_SONG_AT => LATE_TRACKS,
                     DRIFT_SONG_AT => DRIFT_TRACKS, APART_SONG_AT => APART_TRACKS, TIES_SONG_AT => TIES_TRACKS }).freeze

  # --- the player --------------------------------------------------------------------------------

  Track = Struct.new(:place, :wait, :status, :active, :stack, :repeats, :key, :velocity, :shift, :voice, :voice_number,
                     :volume, :pan, :bend, :bend_range, :tune)
  # A note the walked track has sounding: its record, the frame it started, its gate's ticks left
  # (0 for a tie) and the key that lets go of it; and for a voiced walk, the key its voice was struck
  # at before the track moved it, whether it is a recording and one at a fixed rate, the velocity and
  # the drum's own pan its sides are worked out from, and its newest gliding record.
  Sounding = Struct.new(:record, :start, :gate, :key, :pitch_key, :recorded, :fixed, :velocity, :rhythm_pan, :glide)

  # How many times round the song's loop the tempo's count is followed for, past the first, to find
  # where it comes back to what it was (Packing::M4A::MOST_LAPS).
  MOST_LAPS = 5
  # One track's loop: the place it jumps back to, the tick it first reaches it, and the tick it
  # first jumps back.
  TrackLoop = Struct.new(:track, :target, :arrival, :jump)

  # MPlayMain over the song at +song_at+ in +copy+: each tick of every track, the records of
  # +walked+'s notes on voices of +kind+ (255 any), until the song ends or comes round. A note on a
  # kit's or a split's voice is numbered from +kit_from+ or +split_from+; #voices is where the voice
  # each record played is, record by record.
  #
  # Where a song comes round, as the reader works it out (Packing::M4A, "a song comes round"), in
  # ticks: each track repeats on its own from where it first reaches the place it jumps back to, or
  # from its first jump back where its second time round does not start as its first did; the song
  # repeats from the latest of those (and of where a track that stops falls silent), every time
  # round lasting the least span every track's loop fits whole. The tempo's count can leave a time round starting a frame later than the one
  # before, and a MEMACC can count times round in the driver's memory, so the times round from
  # there are followed for MOST_LAPS more: the first that starts with the count and the memory as
  # an earlier one did comes round to it, and failing that the song comes round to its second time
  # round and ends where the third starts. +frames+ instead plays that many frames with nothing compared, as the driver plays on
  # for ever.
  class Player
    attr_reader :records, :voices, :end_frame, :loop_frame, :loops, :silent_from, :frame, :marks

    # +voiced+ gives each recording's record its settings, as a voiced record keeps them (voiced
    # recordings, below), and writes a gliding record where the part's note is bent as it sounds.
    def initialize(copy, song_at, walked: nil, kind: 255, frames: nil, kit_from: KIT_AND_SPLIT_NUMBERS_FROM,
                   split_from: KIT_AND_SPLIT_NUMBERS_FROM, voiced: false)
      @source = copy
      @song_at = song_at
      @copy = copy.bytes
      @voiced = voiced
      @walked = walked
      @kind = kind
      @frames = frames
      @kit_from = kit_from
      @split_from = split_from
      @voices = []
      count = [@copy[song_at], 16].min
      @group = word(song_at + 4) & 0x1FF_FFFF
      @tracks = (0...count).map do |n|
        Track.new(word(song_at + 8 + (4 * n)) & 0x1FF_FFFF, 0, 0, true, [], 0, 0, 0, 0, nil, 0, 0, 0, 0, 2, 0)
      end
      @memory = [0] * 256
      @records = []
      @sounding = []
    end

    def word(at) = @copy[at, 4].pack("C4").unpack1("V")
    def signed(byte) = byte >= 128 ? byte - 256 : byte

    # The song played as the reader plays it: its length and loop worked out (#time_song), then for
    # a walked track, played again to its end writing the track's notes.
    def play
      return play_frames(@frames) if @frames

      @end_frame, @loop_frame = Player.new(@source, @song_at).time_song
      return self unless @walked

      loop_frame = @loop_frame
      play_frames(@end_frame)
      @loop_frame = loop_frame
      self
    end

    # +frames+ frames with nothing compared, the notes sounding at the end let go there.
    def play_frames(frames)
      play_until { @frame >= frames }
      @end_frame = @frame
      @sounding.dup.each { |note| let_go(note) }
      self
    end

    MOST_FRAMES = 0xFFFE

    # [length, loop frame or nil] in frames: three plays of the song, each from its start.
    def time_song
      firsts = Player.new(@source, @song_at).find_first_jumps
      return [firsts.frame, nil] if firsts.loops.empty?

      repeats = Player.new(@source, @song_at).find_repeats(firsts.loops)
      loops = repeats.loops
      from = [*loops.map { |track_loop| repeats.alike?(track_loop) ? track_loop.arrival : track_loop.jump }, *firsts.silent_from].max
      lap = loops.map { |track_loop| track_loop.jump - track_loop.arrival }.select(&:positive?).reduce(1, :lcm)
      marks = Player.new(@source, @song_at).mark_ticks((0..MOST_LAPS).map { |n| from + (n * lap) }).marks
      first, again = repeat_of(marks)
      return [MOST_FRAMES, marks.first&.first] unless again

      [marks[again].first, marks[first].first]
    end

    # The two times round the song repeats between, as places in +marks+ ([frame, [count, memory]]
    # at the start of each): the first that starts with the count and the driver's memory as an
    # earlier one did, and that one; failing that, the second and the third.
    def repeat_of(marks)
      repeat = marks.each_index.to_a.combination(2).select { |was, is| marks[was].last == marks[is].last }.min_by(&:reverse)
      repeat || ([1, 2] if marks.length > 2) || ([0, 1] if marks.length > 1)
    end

    # The first pass: until every track still playing has jumped back once, where each jumps back
    # to and on which tick, and the tick each track that stops falls silent.
    def find_first_jumps
      @loops = {}
      @silent_from = []
      play_until { @loops.any? && @tracks.each_index.none? { |n| @tracks[n].active && !@loops.key?(n) } }
      @loops = @loops.values
      self
    end

    # The second pass: the tick each looping track of +loops+ first reaches the place it jumps back
    # to, and every note each strikes until its second time round is over, with the first track's
    # tempo changes.
    def find_repeats(loops)
      @watched = loops.to_h do |track_loop|
        [track_loop.track, TrackLoop.new(track: track_loop.track, target: track_loop.target, jump: track_loop.jump)]
      end
      @notes = Hash.new { |all, n| all[n] = [] }
      @tempo_changes = []
      @tied = {}
      play_until do
        @watched.values.all? { |track_loop| track_loop.arrival && @tick >= (2 * track_loop.jump) - track_loop.arrival }
      end
      @loops = @watched.values
      self
    end

    # A note struck by a watched track, as it sounds: [tick, voice, key, ticks it lasts (nil for a
    # tie never let go), velocity, volume].
    def keep_note(track, n, gate)
      note = [@tick, track.voice_number, track.key + track.shift, (gate unless gate.zero?), track.velocity, track.volume]
      @notes[n] << note
      @tied[[n, track.key]] = note if gate.zero?
    end

    # A watched track's tie on its key let go: it lasted until this tick, one at least.
    def let_go_tie(track, n)
      note = @tied.delete([n, track.key])
      note[3] = [@tick - note[0], 1].max if note
    end

    # The third pass: [frame, [count, memory]] after each of +ticks+.
    def mark_ticks(ticks)
      @wanted = ticks
      @marks = []
      play_until { @marks.length == ticks.length }
      self
    end

    # The driver a frame at a time until the song ends, the block holds after a frame, or the most
    # frames.
    def play_until
      @tempo = 150
      @count = 0
      @frame = 0
      @tick = 0
      @ended = false
      @held_until = Hash.new(0)
      until @ended || @frame >= MOST_FRAMES
        @count += @tempo
        while @count >= 150 && !@ended
          tick
          @count -= 150
          @marks << [@frame, [@count, @memory.dup]] if @wanted && @wanted[@marks.length] == @tick
          @tick += 1
        end
        @frame += 1 unless @ended
        break if yield
      end
    end

    # Whether a track's second time round sounds as its first: the same notes at the same moments
    # from where each starts, for as long, those still sounding from before it included; and on
    # the first track, the same tempo.
    def alike?(track_loop)
      span = track_loop.jump - track_loop.arrival
      alike = sounds_from(track_loop.track, track_loop.arrival, span) == sounds_from(track_loop.track, track_loop.jump, span)
      return alike unless track_loop.track.zero?

      alike && tempo_from(track_loop.arrival, span) == tempo_from(track_loop.jump, span)
    end

    # What track +n+ sounds for +span+ ticks from +at+, counted from there.
    def sounds_from(n, at, span)
      @notes[n].filter_map do |tick, voice, key, length, velocity, volume|
        held = tick < at && length && tick + length > at
        [tick - at, voice, key, length, velocity, volume] if held || (tick >= at && tick < at + span)
      end
    end

    # The tempo for +span+ ticks from +at+: the one in force there, then every change before its end.
    def tempo_from(at, span)
      [@tempo_changes.reverse.find { |tick, _| tick <= at }&.last,
       *@tempo_changes.select { |tick, _| tick > at && tick < at + span }.map { |tick, tempo| [tick - at, tempo] }]
    end

    # One tick of every track.
    def tick
      playing = false
      @tracks.each_with_index do |track, n|
        break if @ended
        next unless track.active

        playing = true
        if n == @walked
          @sounding.select { |note| note.gate.positive? }.each do |note|
            note.gate -= 1
            let_go(note) if note.gate.zero?
          end
        end
        read(track, n) while track.wait.zero? && track.active && !@ended
        track.wait -= 1 if track.active
      end
      # MPlayMain counts a track that starts the tick playing, so the song stops a tick after its
      # last track's fine.
      @ended = true unless playing
    end

    def read(track, n)
      watched = @watched && @watched[n]
      watched.arrival = @tick if watched && watched.arrival.nil? && track.place == watched.target
      byte = @copy[track.place]
      if byte < 0x80
        command = track.status
      else
        command = byte
        track.place += 1
        track.status = byte if byte >= 0xBD
      end
      if command < 0x80 then stop(track, n)
      elsif command >= 0xCF then note(track, n, CLOCKS[command - 0xCF])
      elsif command >= 0xB1 then command(track, n, command)
      else track.wait = CLOCKS[command - 0x80]
      end
    end

    def arg(track)
      value = @copy[track.place]
      track.place += 1
      value
    end

    def command(track, n, command)
      case command
      when 0xB2 then jump_back(track, n, word(track.place) & 0x1FF_FFFF)
      when 0xB3
        return stop(track, n) if track.stack.length >= 3

        track.stack.push(track.place + 4)
        track.place = word(track.place) & 0x1FF_FFFF
      when 0xB4 then track.place = track.stack.pop unless track.stack.empty?
      when 0xB5
        times = @copy[track.place]
        return jump_back(track, n, word(track.place + 1) & 0x1FF_FFFF) if times.zero?

        track.repeats += 1
        if track.repeats < times
          track.place = word(track.place + 1) & 0x1FF_FFFF
        else
          track.repeats = 0
          track.place += 5
        end
      when 0xB9 then memacc(track)
      when 0xBB
        @tempo = arg(track) * 2
        @tempo_changes << [@tick, @tempo] if @tempo_changes && n.zero?
      when 0xBC then track.shift = signed(arg(track))
      when 0xBD
        track.voice_number = arg(track)
        track.voice = @group + (12 * track.voice_number)
      when 0xBE then track.volume = arg(track)
      when 0xBF then track.pan = arg(track) - 64
      when 0xC0 then track.bend = arg(track) - 64
      when 0xC1 then track.bend_range = arg(track)
      when 0xC8 then track.tune = arg(track) - 64
      when 0xBA, 0xC2, 0xC3, 0xC4, 0xC5 then arg(track)
      when 0xCC then track.place += 2
      when 0xCD
        case arg(track)
        when 1 then track.place += 4
        when 2, 4..11 then track.place += 1
        else stop(track, n)
        end
      when 0xCE
        track.key = arg(track) if @copy[track.place] < 0x80
        let_go_tie(track, n) if @watched&.key?(n)
        if n == @walked
          held = @sounding.reverse.find { |note| note.key == track.key }
          let_go(held) if held
        end
      else stop(track, n)
      end
      change_sounding(track) if @voiced && n == @walked && [0xBC, 0xBE, 0xBF, 0xC0, 0xC1, 0xC8].include?(command)
    end

    # GOTO, or REPT with no count, from +track+ to +place+. The first jump back of each track is
    # kept in the first pass: where to, and on which tick.
    def jump_back(track, n, place)
      back = place < track.place
      track.place = place
      @loops[n] ||= TrackLoop.new(track: n, target: place, jump: @tick) if back && @loops.is_a?(Hash)
    end

    def stop(track, n)
      @silent_from << [@tick, @held_until[n]].max if @silent_from && track.active
      track.active = false
      @sounding.dup.each { |note| let_go(note) } if n == @walked
    end

    def memacc(track)
      operation = arg(track)
      spot = arg(track)
      data = arg(track)
      case operation
      when 0 then @memory[spot] = data
      when 1 then @memory[spot] = (@memory[spot] + data) & 0xFF
      when 2 then @memory[spot] = (@memory[spot] - data) & 0xFF
      when 3 then @memory[spot] = @memory[data]
      when 4 then @memory[spot] = (@memory[spot] + @memory[data]) & 0xFF
      when 5 then @memory[spot] = (@memory[spot] - @memory[data]) & 0xFF
      when 6..17
        against = operation >= 12 ? @memory[data] : data
        value = @memory[spot]
        held = [value == against, value != against, value > against, value >= against, value <= against,
                value < against][(operation - 6) % 6]
        held ? track.place = word(track.place) & 0x1FF_FFFF : track.place += 4
      end
    end

    def note(track, n, gate)
      if @copy[track.place] < 0x80
        track.key = arg(track)
        if @copy[track.place] < 0x80
          track.velocity = arg(track)
          gate += arg(track) if @copy[track.place] < 0x80
        end
      end
      @held_until[n] = [@held_until[n], @tick + gate].max
      keep_note(track, n, gate) if @watched&.key?(n)
      strike(track, gate) if n == @walked
    end

    def strike(track, gate)
      voice = track.voice
      kind = voice ? @copy[voice] : 1
      key = track.key
      instrument = track.voice_number
      rhythm_pan = 0
      if kind.anybits?(0xC0)
        split = kind.anybits?(0x40)
        picked = split ? @copy[(word(voice + 8) & 0x1FF_FFFF) + track.key] : track.key
        numbered = (split ? @split_from : @kit_from) + picked
        instrument = numbered.between?(0, OWN - 1) ? numbered : OWN
        drum = kind.anybits?(0x80)
        voice = (word(voice + 4) & 0x1FF_FFFF) + (12 * picked)
        kind = @copy[voice]
        return if kind.anybits?(0xC0)

        if drum
          rhythm_pan = (@copy[voice + 3] - 0xC0) * 2 if @copy[voice + 3] >= 0x80
          key = @copy[voice + 1]
        end
      end
      channel = kind & 7
      return unless @kind == 255 || @kind == channel

      pitch_key = key
      key = [key + ((((track.tune + (track.bend * track.bend_range)) * 4) + (track.shift * 256)) >> 8), 0].max
      right, left = sides_of(track, track.velocity, rhythm_pan)
      record = if channel.zero?
                 [@frame, 0, kind.anybits?(0x08) ? 60 : [key, 127].min, instrument, OWN, right + left, OWN, OWN]
               else
                 side = if right >= left then (right >> 1) >= left ? 2 : 0
                        else (left >> 1) >= right ? 1 : 0
                        end
                 clock = (NOISE_TABLE[(key - 21).clamp(0, 59)] if channel == 4)
                 key = key.clamp(36, 127) unless channel == 4
                 [@frame, 0, [key, 127].min, OWN, [(right + left) >> 4, 15].min, nil, side, clock || OWN]
               end
      fixed = kind.anybits?(0x08)
      record << shade_of(right, left).merge(fixed ? {} : pitch_of(track, pitch_key).except(:key)) if @voiced && channel.zero?
      @records << record
      @voices << voice
      @latest = nil
      return unless @sounding.length < 16

      @latest = Sounding.new(record, @frame, gate, track.key, pitch_key, channel.zero?, fixed, track.velocity, rhythm_pan, nil)
      @sounding << @latest
    end

    # Each side's loudness, 0 to 255, for a note of +velocity+ and a drum's own pan +rhythm_pan+ on
    # +track+ as it is now (TrkVolPitSet, ChnVolSetAsm).
    def sides_of(track, velocity, rhythm_pan)
      x = (track.volume * 64) >> 5
      y = (track.pan * 2).clamp(-128, 127)
      [[((128 + rhythm_pan) * velocity * (((y + 128) * x) >> 8)) >> 14, 255].min,
       [((127 - rhythm_pan) * velocity * (((127 - y) * x) >> 8)) >> 14, 255].min]
    end

    # --- voiced recordings ---
    #
    # Where a recording's note sits between the speakers, as Audio::Pan keeps it: the near side
    # whole and the far side lacking that share of it, in 64ths, rounded, the left below 0. None in
    # the middle.
    def shade_of(right, left)
      near = [right, left].max
      return {} if near.zero?

      shade = ((((near - [right, left].min) * 64) + (near >> 1)) / near) * (left > right ? -1 : 1)
      shade.zero? ? {} : { shade: shade }
    end

    # The pitch a note struck at +pitch_key+ plays at on +track+ now: MidiKeyToFreq's key and the
    # 256ths of the next it reads between, from TrkVolPitSet's keyM and pitM. Its hz, in 16ths, where
    # that is not a whole key a key byte names, as { hz: }; and the key, as { key: }.
    def pitch_of(track, pitch_key)
      moved = ((track.tune + (track.bend * track.bend_range)) * 4) + (track.shift * 256)
      key = pitch_key + (moved >> 8)
      fine = moved & 0xFF
      key, fine = 0, 0 if key.negative?
      key, fine = 178, 255 if key > 178
      return { key: key } if fine.zero? && key <= 127

      low = key_hz(key)
      { key: key, hz: low + (((key_hz(key + 1) - low) * fine) >> 8) }
    end

    def key_hz(key) = (440 * (2**((key - 69) / 12r)) * 16).round

    # A pitch, VOL or PAN command while the part's newest note sounds, on a recording: MPlayMain moves
    # the pitch and the sides of every sounding note of the track, and the part plays its newest, so
    # that one glides to what it plays now — its pitch (its own note at a fixed rate), the two sides
    # added and its shade — the record of a glide or a strike on this frame given it, or a gliding
    # record of its own.
    def change_sounding(track)
      note = @latest
      return unless note&.recorded

      right, left = sides_of(track, note.velocity, note.rhythm_pan)
      pitch = note.fixed ? { key: 60 } : pitch_of(track, note.pitch_key)
      key = [pitch.delete(:key), 127].min
      settings = { shade: 0 }.merge(shade_of(right, left), pitch) # a glide names its side, the middle too
      if note.glide && note.glide[0] == @frame
        note.glide[2], note.glide[5], note.glide[8] = key, right + left, settings.merge(glides: true)
      elsif note.glide.nil? && note.start == @frame
        note.record[2], note.record[5], note.record[8] = key, right + left, settings
      else
        note.glide = [@frame, 0, key, OWN, OWN, right + left, nil, OWN, settings.merge(glides: true)]
        @records << note.glide
        @voices << @voices[@records.index { |record| record.equal?(note.record) }]
      end
    end

    def let_go(note)
      note.record[1] = [@frame - note.start, 1].max
      note.glide[1] = [@frame - note.glide[0], 1].max if note.glide
      @latest = nil if @latest.equal?(note)
      @sounding.delete(note)
    end
  end

  # Track +walked+'s notes of +kind+ in the song at +song_at+, as PackNote tuples, numbered as
  # +numbering+ (a Numbering) says.
  def self.records(song_at, walked, kind: 255, numbering: Numbering.new) = played_song(song_at, walked, kind, numbering).records

  # Where the voice each of those records played is, record by record.
  def self.voices_played(song_at, walked, kind: 255, numbering: Numbering.new) = played_song(song_at, walked, kind, numbering).voices

  # The bytes a slot of +count+ notes holds for them.
  def self.track_bytes(song_at, walked, count:, kind: 255, numbering: Numbering.new)
    VBlank::Original::PackNote.bytes_of(records(song_at, walked, kind: kind, numbering: numbering), count: count)
  end

  # The same records voiced, each with its console voice's settings as the driver sets the voice up
  # for the note (ply_note: the sweep, 8 where bits 4 to 6 are clear or bit 7 set; CgbSound: NRx1's
  # duty from the voice's wave word, the envelope from its attack, decay and sustain; CgbModVol:
  # the sustain level), matched to a note's own words as Packing::M4A::Walk#emit_voice_settings says.
  def self.voiced_track_bytes(song_at, walked, count:, kind: 255, numbering: Numbering.new)
    played = played_song(song_at, walked, kind, numbering, voiced: true)
    tuples = played.records.zip(played.voices).map do |record, voice|
      channel = COPY.getbyte(voice) & 7
      next [*record.first(8), record[8] || {}] if channel.zero?

      volume, settings = cgb_voice_settings(voice, channel, record[4])
      [*record.first(4), volume, *record.drop(5), settings]
    end
    VBlank::Original::PackNote.bytes_of(tuples, count: count, voiced: true)
  end

  # [the note's volume, its settings by Original::PackNote::NAMES' names] for a note on +channel+
  # (1 or 2 a square, 3 the wave, 4 the noise) of the voice at +voice+, struck at +volume+. The
  # driver's envelope, swell to the volume, fall to the sustain level and hold, is matched to the
  # voice's own counting as Packing::M4A::Walk#emit_voice_settings says.
  def self.cgb_voice_settings(voice, channel, volume)
    byte = ->(at) { COPY.getbyte(voice + at) }
    settings = {}
    settings[:duty] = (byte.(4) & 3) * 0x55 if channel <= 2
    sweep = byte.(3)
    settings[:slide] = sweep & 0x7F if channel == 1 && sweep.nobits?(0x80) && sweep.anybits?(0x70) && sweep.anybits?(7)
    attack = byte.(8) & 7
    decay = byte.(9) & 7
    sustain = byte.(10) & 15
    held = ((volume * sustain) + 15) >> 4
    return [held, settings] if channel == 3
    return [0, settings.merge(fade: 8 | attack)] if attack.positive? && volume == 15
    return [volume, settings.merge(fade: decay)] if decay.positive? && sustain.zero?

    [held, settings.merge(fade: 0)]
  end

  # The Player that has played the song at +song_at+, walking track +walked+.
  def self.played_song(song_at, walked, kind, numbering, voiced: false)
    Player.new(COPY, song_at, walked: walked, kind: kind, voiced: voiced, **numbering.to_h).play
  end
  private_class_method :played_song, :cgb_voice_settings

  # [length, loop frame] of the song at +song_at+, 65535 for none.
  def self.length(song_at)
    played = Player.new(COPY, song_at).play
    [played.end_frame, played.loop_frame || 0xFFFF]
  end

  # The bytes a slot of +count+ notes holds for track +walked+'s notes of +kind+ as the driver plays
  # the song at +song_at+ for +frames+, on past every loop.
  def self.played_track_bytes(song_at, walked, frames:, count:, kind: 255)
    records = Player.new(COPY, song_at, walked: walked, kind: kind, frames: frames).play.records
    VBlank::Original::PackNote.bytes_of(records, count: count)
  end

  # A recording's samples and its voice's settings, as the routine writes them: the samples, and
  # [rate, hold, length] then the envelope's four bytes. The hold of a voice that does not loop
  # has every bit set, which a hold read from the pack takes as none.
  NO_HOLD = 0xFFFF_FFFF

  def self.recording_bytes(samples) = samples.pack("c*")

  def self.voice_settings_bytes(rate, hold, length, shape) = [rate, hold, length].pack("V3") + shape.pack("C4")

  # Must be InRactors.share_constants, not Ractor.make_shareable alone: tests in several Ractors
  # write copy to a file at once (InRactors.shareable says what that does to a plain frozen String).
  VBlank::Testing::InRactors.share_constants(self)
end
