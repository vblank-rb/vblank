# frozen_string_literal: true

require "test_helper"

# THE MESSAGES AS TEXT: each turns into one JSON object and back, and text that is not a message, or
# is one of another version, is refused in plain words.
class TestWire < Minitest::Test
  Network = VBlank::Network
  Wire = Network::Wire

  PRINT = Network::Fingerprint.new(title: "WANDERERS", console: "gba", digest: "ab12cd34")

  MESSAGES = [
    Network::Join.new(fingerprint: PRINT),
    Network::Welcome.new(to: 2, seed: -5, input_delay: 2, checkpoint_every: 8, players: 3),
    Network::Refuse.new(to: 3, reason: :different_game, fingerprint: PRINT),
    Network::Joined.new(player: 2),
    Network::Start.new(players: [1, 2, 4]),
    Network::Buttons.new(pass: 12, mask: 16),
    Network::Checkpoint.new(pass: 8, crc: 3_054_198_966),
    Network::Left.new
  ].freeze

  RELAY_MESSAGES = [
    Network::RelayMakeRoom.new,
    Network::RelayMakeRoom.new(public: true, digest: "ab12cd34", name: "Friday game", seats: 4),
    Network::RelayListRooms.new(digest: "ab12cd34"),
    Network::RelayRooms.new(rooms: [Network::PublicRoom.new(code: "K7QF", name: "Friday game", members: 1, seats: 4)]),
    Network::RelayRoomMade.new(code: "K7QF", you: 1),
    Network::RelayJoinRoom.new(code: "K7QF"),
    Network::RelayRoomJoined.new(code: "K7QF", you: 2, members: [1]),
    Network::RelayError.new(reason: :no_such_room, words: "No room.", supported: nil)
  ].freeze

  def test_every_message_of_a_match_is_the_same_after_the_text_and_back
    MESSAGES.each do |message|
      envelope = Wire.decode(Wire.encode(message, from: 2))

      assert_equal message, envelope.message, message.class.name
      assert_equal 2, envelope.from
    end
  end

  def test_a_message_the_room_has_not_stamped_has_no_sender
    assert_nil Wire.decode(Wire.encode(Network::Buttons.new(pass: 1, mask: 0))).from
  end

  def test_a_message_between_a_machine_and_the_relay_is_not_in_an_envelope
    RELAY_MESSAGES.each { |message| assert_equal message, Wire.decode(Wire.encode(message)), message.class.name }
  end

  def test_a_message_is_one_json_object_with_its_version_and_its_name
    assert_equal({ "v" => 1, "type" => "buttons", "pass" => 12, "mask" => 16 }, JSON.parse(Wire.encode(Network::Buttons.new(pass: 12, mask: 16))))
  end

  def test_text_that_is_not_a_message_is_refused
    ["no", "[1]", "{}", '{"v":1}', '{"v":1,"type":"dance"}', '{"v":1,"type":"buttons","pass":1}'].each do |text|
      assert_raises(Network::BadMessage, text) { Wire.decode(text) }
    end
  end

  def test_a_newer_version_is_refused_with_the_version_this_one_knows
    error = assert_raises(Network::VersionMismatch) { Wire.decode('{"v":2,"type":"left"}') }

    assert_match(/newer version/, error.message)
    assert_match(/update this program/, error.message)
    assert_equal [1], error.supported
  end

  def test_an_older_version_says_the_other_program_is_the_one_to_update
    error = assert_raises(Network::VersionMismatch) { Wire.decode('{"v":0,"type":"left"}') }

    assert_match(/older version/, error.message)
    assert_match(/program that sent it/, error.message)
  end

  def test_fields_a_reader_does_not_know_are_ignored
    envelope = Wire.decode('{"v":1,"type":"buttons","pass":3,"mask":1,"mood":"happy","from":2}')

    assert_equal Network::Buttons.new(pass: 3, mask: 1), envelope.message
  end
end
