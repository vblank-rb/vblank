# frozen_string_literal: true

# A part of a game in a file of its own, written in normal Ruby: what `VBlank.require_game_file`
# brings in for test/all/vblank/dsl/test_plain_ruby.rb.
class PlainRubyHelperPart
  LIMIT = 3
  NAME = "part"
  WRITTEN_ON = __LINE__

  attr_reader :count

  def initialize(build)
    @count = build.var(:part_count, 0)
    @flips = build.var(:part_flips, 0)
  end

  def step
    if @count < LIMIT
      @count += 1
    else
      @flips = 9
    end
  end
end

# A method of the game's defined in a file of its own, so a game block calling it cannot see what
# it does: it changes nothing.
def plain_ruby_helper_pass_over(value) = value

# An object of the game's whose method moves a place it is handed on by one, defined in a file of
# its own so a game block calling it through the object cannot see the method.
class PlainRubyPlaceMover
  def move_place_on(place) = place.increase!(1)
end

# A song reader in the shape a port writes the original's: each channel's state in lists reached
# through a Hash by field name, read and written only through private methods of the object.
# #next_byte hands back the byte at a channel's place before it moves the place on, and
# #read_pitch_offset joins two such bytes, high byte first.
class PlainRubySongReader
  FIELDS = %i[at pitch_offset drum envelope noise].freeze

  def initialize(builder, bytes)
    @bytes = bytes
    @state = FIELDS.to_h { |field| [field, builder.list(:"song_#{field}", capacity: 2, full_of: 0)] }
  end

  def read_pitch_offset(channel)
    high = next_byte(channel)
    set(:pitch_offset, channel, (high << 8) | next_byte(channel))
  end

  # A drum step of three bytes at the channel's drum place: the envelope and the noise are read
  # at places worked out from `at`, then the place moves on before either is written.
  def read_drum_step(channel)
    at = get(:drum, channel)
    envelope = @bytes[at + 1]
    noise = @bytes[at + 2]
    set(:drum, channel, at + 3)
    set(:envelope, channel, envelope)
    set(:noise, channel, noise)
  end

  private

  def get(field, channel) = @state.fetch(field)[channel]

  def set(field, channel, value)
    @state.fetch(field)[channel] = value
  end

  def next_byte(channel)
    at = get(:at, channel)
    set(:at, channel, at + 1)
    @bytes[at]
  end
end
