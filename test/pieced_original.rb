# frozen_string_literal: true

require "made_up_original"

# A MADE-UP ORIGINAL WHOSE MUSIC IS UNPACKED IN PIECES, shared by the tests of pieces on the build,
# on the Ruby shell's workers and on the web page's: the made-up original's copy, read by a routine
# of three parts. Its tiles are unpacked first and its heights last, each a part of one piece, and
# between them its "songs" are rendered, a song a piece, into rooms of uneven size, as a port
# renders an original's music: each sample worked out from the copy's bytes, the song's length
# kept in a slot of its own. One song is not in the copy, so its room is counted as written and
# left zeros, as a port leaves a song a copy lacks.
module PiecedOriginal
  include MadeUpOriginal

  # Each song's room, in samples: uneven, the longest neither first nor last.
  ROOMS = [300, 37, 1200, 5, 90].freeze
  # Where each song's room starts in the slot of samples.
  SONG_AT = ROOMS.each_with_object([0]) { |room, starts| starts << (starts.last + room) }.first(ROOMS.length).freeze
  # The song the copy lacks.
  ABSENT = 3
  # How far into the copy each song's samples start reading.
  SONG_FROM = [0x13, 0x40, 0x07, 0x00, 0x1A0].freeze
  # A sample costs more to make than a byte copied, as a port's rendered music does.
  SAMPLE_COST = 4

  VBlank::Testing::InRactors.share_constants(self)

  # SONG +song+'s samples written into +samples+ (a slot, or one piece of it) from its item +at+
  # on, and its length into item +length_at+ of +lengths+, on the routine's builder +b+.
  def self.render(b, copy, song, samples:, at:, lengths:, length_at:)
    room = ROOMS.fetch(song)
    if song == ABSENT
      lengths[length_at] = 0
    else
      b.repeat(room) { |i| samples[at + i] = copy.byte(((i * 7) + SONG_FROM.fetch(song)) & 0x1FF) + song }
      lengths[length_at] = room
    end
    copy.count_written room, into: samples
  end

  # The pack's slots, and its routine, the music given +pieces+: :none (one part that renders
  # every song in turn, as a port did before pieces), 1 (a part of one piece), or :songs (a piece
  # a song).
  def self.declare(slots, pieces:)
    rooms = { none: nil, 1 => 1, songs: ROOMS }.fetch(pieces)
    count = { none: nil, 1 => 1, songs: ROOMS.length }.fetch(pieces)
    slots.colors :palette, at: PALETTE_AT, count: 16
    slots.tiles :walls, count: 2
    slots.samples :music, count: ROOMS.sum, cost: SAMPLE_COST, pieces: rooms
    slots.numbers :music_length, count: ROOMS.length, width: :half, signed: false, pieces: count
    slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
    slots.fill_from_copy(:walls) { |copy, pack| copy.unpack_lz77 at: LZ77_AT, into: pack[:walls] }
    if pieces == :songs
      slots.fill_from_copy(:music, pieces: ROOMS.length) do |copy, pack, _release, song|
        PiecedOriginal.render(self, copy, song, samples: pack[:music].piece(song), at: 0,
                                                lengths: pack[:music_length].piece(song), length_at: 0)
      end
    else
      slots.fill_from_copy(:music, pieces: count) do |copy, pack|
        samples = pieces == 1 ? pack[:music].piece(0) : pack[:music]
        lengths = pieces == 1 ? pack[:music_length].piece(0) : pack[:music_length]
        ROOMS.each_index do |song|
          PiecedOriginal.render(self, copy, song, samples: samples, at: SONG_AT.fetch(song), lengths: lengths, length_at: song)
        end
      end
    end
    slots.fill_from_copy(:heights) { |copy, pack| copy.unpack_rle at: RLE_AT, into: pack[:heights] }
  end

  # The samples of each song as the copy makes them, the absent one zeros: the answer key.
  def self.music_answer
    ROOMS.each_with_index.flat_map do |room, song|
      next Array.new(room, 0) if song == ABSENT

      Array.new(room) { |i| (COPY.getbyte(((i * 7) + SONG_FROM.fetch(song)) & 0x1FF) + song) & 0xFF }
    end.pack("C*")
  end

  # The made-up original with its release, for a build in +folder+.
  private def pieced_original(folder) = original(folder)

  # The made-up original on a machine where no copy of it is set: what a shell is built from.
  private def pieced_original_nowhere(folder)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: {}, settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => SHA1, "size" => COPY_SIZE } })
  end

  # A port of it whose music is in a piece a song: a wall drawn from the pack, and a marker placed
  # by the length of the longest song, for a shell to be built from.
  private def pieced_port(from)
    VBlank.game("PIECED", consoles: %i[gba]) do
      screen :bitmap
      clear_screen :black
      pack = data_pack(from: from, version: "1") { |slots| PiecedOriginal.declare(slots, pieces: :songs) }
      image :wall, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0)
      lengths = table :lengths, pack[:music_length]
      game_loop do
        blit :wall, 8, 8
        draw_rect_at lengths[2] / 10, 40, 4, 4, :white
      end
    end
  end
end
