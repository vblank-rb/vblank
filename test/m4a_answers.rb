# frozen_string_literal: true

# THE ANSWER KEY FOR THE ADVANCE'S COMMON SOUND DRIVER (Original::Packing::M4A): a made-up song of
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

  # A note or wait of +ticks+, which must be one of CLOCKS.
  def self.note_code(ticks) = 0xCF + CLOCKS.index(ticks)
  def self.wait_code(ticks) = 0x80 + CLOCKS.index(ticks)

  # --- the made-up copy ------------------------------------------------------------------------
  COPY_SIZE = 0x1000
  SONG_AT = 0x020
  ENDING_SONG_AT = 0x040
  GROUP_AT = 0x060              # eight voices
  SPLIT_GROUP_AT = 0x0C0        # two voices a key split picks from
  SPLIT_TABLE_AT = 0x0E0        # 128 bytes
  KIT_AT = 0x160                # a drum kit's voices, 12 bytes a key, keys 36 and 38 written
  WAVE_AT = 0x600               # a recording that loops
  ONE_SHOT_AT = 0x660           # one that does not
  TRACKS_AT = 0x700

  # The voices: a recording, the two squares, the wave, the noise, a key split (low keys the
  # recording, from key 60 the second square), a drum kit, and a recording at a fixed rate.
  VOICES = [[0x00, 60, 0, 0, ROM + WAVE_AT, [255, 0, 255, 165]], [0x01, 60, 0, 0x08, 2, [0, 0, 15, 0]],
            [0x02, 60, 0, 0, 1, [0, 1, 12, 2]], [0x03, 60, 0, 0, ROM + 0x5F0, [0, 0, 15, 0]], [0x04, 60, 0, 0, 0, [0, 2, 0, 0]],
            [0x40, 0, 0, 0, ROM + SPLIT_GROUP_AT, ROM + SPLIT_TABLE_AT], [0x80, 0, 0, 0, ROM + KIT_AT, [0, 0, 0, 0]],
            [0x08, 60, 0, 0, ROM + ONE_SHOT_AT, [255, 40, 200, 10]]].freeze
  SPLIT_VOICES = [[0x00, 60, 0, 0, ROM + WAVE_AT, [200, 10, 180, 100]], [0x02, 60, 0, 0, 3, [0, 0, 10, 0]]].freeze
  # The kit's key 36 is the recording, panned to the left side's half (rhythm pan), at key 64; key
  # 38 is the noise voice at key 50.
  KIT_VOICES = { 36 => [0x00, 64, 0, 0xA0, ROM + WAVE_AT, [255, 0, 255, 0]], 38 => [0x04, 50, 0, 0, 0, [0, 1, 0, 0]] }.freeze
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
     [:voice, 5], [:note, 6, 48, 100], [:wait, 6], [:note, 6, 64, 100], [:wait, 6], [:wait, 36], [:goto, :again]],
    # Track 2: the drum kit's recording and noise, and the recording at a fixed rate.
    [[:voice, 6], [:vol, 90], [:note, 4, 36, 120], [:wait, 6], [:note, 4, 38, 100], [:wait, 6], [:voice, 4], [:note, 3, 10, 127],
     [:wait, 3], [:note, 3, 90, 127], [:wait, 3], [:voice, 7], [:note, 8, 50, 64], [:wait, 8], [:label, :drums], [:voice, 6],
     [:note, 2, 38, 127], [:wait, 2], [:wait, 72], [:rept, 0, :drums]]
  ].freeze
  # A song that ends: its tracks run to their end, the second later than the first; the first holds
  # a tie as it ends with an XCMD the driver's table sends to FINE, the second jumps forward past a
  # note, and the third names no voice, so it plays the first square.
  ENDING_TRACKS = [[[:voice, 1], [:vol, 127], [:note, 8, 70, 100], [:wait, 8], [:tie, 74, 100], [:wait, 4], [:xcmd, 0]],
                   [[:voice, 2], [:vol, 64], [:wait, 6], [:goto, :ahead], [:note, 12, 50, 90], [:label, :ahead],
                    [:note, 24, 60, 90], [:wait, 24], [:fine]],
                   [[:vol, 100], [:note, 6, 66, 100], [:wait, 6], [:fine]]].freeze

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

  COPY = copy_with({ SONG_AT => TRACKS, ENDING_SONG_AT => ENDING_TRACKS }).freeze

  # --- the player --------------------------------------------------------------------------------

  Track = Struct.new(:place, :wait, :status, :active, :stack, :repeats, :key, :velocity, :shift, :voice, :voice_number,
                     :volume, :pan, :bend, :bend_range, :tune)
  # A note the walked track has sounding: its record, the frame it started, its gate's ticks left
  # (0 for a tie) and the key that lets go of it.
  Sounding = Struct.new(:record, :start, :gate, :key)

  # MPlayMain over the song at +song_at+ in +copy+: each tick of every track, the records of
  # +walked+'s notes on voices of +kind+ (255 any), until the song ends. +watch+ is [track, place]
  # to stop at, the frame of which is #found.
  class Player
    attr_reader :records, :end_frame, :found, :jump

    def initialize(copy, song_at, walked: nil, kind: 255, watch: nil)
      @copy = copy.bytes
      @walked = walked
      @kind = kind
      @watch = watch
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

    def play
      tempo = 150
      count = 0
      @frame = 0
      @ended = false
      until @ended || @frame >= 0xFFFE
        count += tempo
        while count >= 150 && !@ended
          tempo = tick(tempo)
          count -= 150
        end
        @frame += 1 unless @ended
      end
      @end_frame = @frame
      @sounding.dup.each { |note| let_go(note) }
      self
    end

    # One tick of every track; hands back the tempo after it.
    def tick(tempo)
      @tempo = tempo
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
      # last track's FINE.
      @ended = true unless playing
      @tempo
    end

    def read(track, n)
      if @watch == [n, track.place]
        @found = @frame
        @ended = true
        return
      end
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
      when 0xBB then @tempo = arg(track) * 2
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
        if n == @walked
          held = @sounding.reverse.find { |note| note.key == track.key }
          let_go(held) if held
        end
      else stop(track, n)
      end
    end

    # GOTO, or REPT with no count, from +track+ to +place+: back, the song's end, kept as [the
    # track's number, the place]; forward, a jump.
    def jump_back(track, n, place)
      return track.place = place if place >= track.place

      @jump ||= [n, place]
      @ended = true
    end

    def stop(track, n)
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
      strike(track, gate) if n == @walked
    end

    def strike(track, gate)
      voice = track.voice
      kind = voice ? @copy[voice] : 1
      key = track.key
      instrument = track.voice_number
      rhythm_pan = 0
      if kind.anybits?(0xC0)
        instrument = kind.anybits?(0x40) ? @copy[(word(voice + 8) & 0x1FF_FFFF) + track.key] : track.key
        drum = kind.anybits?(0x80)
        voice = (word(voice + 4) & 0x1FF_FFFF) + (12 * instrument)
        kind = @copy[voice]
        return if kind.anybits?(0xC0)

        if drum
          rhythm_pan = (@copy[voice + 3] - 0xC0) * 2 if @copy[voice + 3] >= 0x80
          key = @copy[voice + 1]
        end
      end
      channel = kind & 7
      return unless @kind == 255 || @kind == channel

      key = [key + ((((track.tune + (track.bend * track.bend_range)) * 4) + (track.shift * 256)) >> 8), 0].max
      x = (track.volume * 64) >> 5
      y = (track.pan * 2).clamp(-128, 127)
      right = [((128 + rhythm_pan) * track.velocity * (((y + 128) * x) >> 8)) >> 14, 255].min
      left = [((127 - rhythm_pan) * track.velocity * (((127 - y) * x) >> 8)) >> 14, 255].min
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
      @records << record
      @sounding << Sounding.new(record, @frame, gate, track.key) if @sounding.length < 16
    end

    def let_go(note)
      note.record[1] = [@frame - note.start, 1].max
      @sounding.delete(note)
    end
  end

  # Track +walked+'s notes of +kind+ in the song at +song_at+, as PackNote tuples.
  def self.records(song_at, walked, kind: 255) = Player.new(COPY, song_at, walked: walked, kind: kind).play.records

  # The bytes a slot of +count+ notes holds for them.
  def self.track_bytes(song_at, walked, count:, kind: 255)
    VBlank::Original::PackNote.bytes_of(records(song_at, walked, kind: kind), count: count)
  end

  # [length, loop frame] of the song at +song_at+, 65535 for none.
  def self.length(song_at)
    first = Player.new(COPY, song_at).play
    return [first.end_frame, 0xFFFF] unless first.jump

    [first.end_frame, Player.new(COPY, song_at, watch: first.jump).play.found]
  end

  # A recording's samples and its voice's settings, as the routine writes them: the samples, and
  # [rate, hold, length] then the envelope's four bytes.
  def self.recording_bytes(samples) = samples.pack("c*")

  def self.voice_settings_bytes(rate, hold, length, shape) = [rate, hold, length].pack("V3") + shape.pack("C4")

  constants.each { |name| Ractor.make_shareable(const_get(name)) }
end
