# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/live"
require "console_bios_cases"

# Which Game Boy Advance BIOS the desktop build plays the console's start-up from, found as the
# desktop build finds it. Every file here is made up: the rule is told to accept the made-up one.
class TestConsoleBIOS < Minitest::Test
  include ConsoleBIOSCases

  ConsoleBIOS = VBlank::Live::ConsoleBIOS

  def test_each_place_answers_as_the_table_says
    CASES.each do |told, answer|
      Dir.mktmpdir("vblank-bios") do |dir|
        places = console_bios_places(dir, told)
        found = ConsoleBIOS.find(environment: places[:environment], setting: places[:setting],
                                 shared_folder: places[:shared_folder], known_sha1: [KNOWN_SHA1])

        assert_answer(answer, found, places[:paths], told)
      end
    end
  end

  def test_a_refused_file_names_itself_and_the_checksum_wanted
    Dir.mktmpdir("vblank-bios") do |dir|
      places = console_bios_places(dir, { shared: :unknown })
      refused = ConsoleBIOS.find(environment: nil, setting: nil, shared_folder: places[:shared_folder],
                                 known_sha1: [KNOWN_SHA1])

      assert_includes refused.message, places[:paths][:shared]
      assert_includes refused.message, KNOWN_SHA1
      assert_includes refused.message, Digest::SHA1.hexdigest(UNKNOWN_BYTES)
      assert_includes refused.message, "starts without"
    end
  end

  def test_the_retail_bios_is_the_one_known_by_default
    assert_equal ["300c20df6731a33952ded8c436f7f186d25d3492"], ConsoleBIOS::KNOWN_SHA1
  end

  private def assert_answer(answer, found, paths, told)
    if answer == :none
      assert_nil found, "#{told} wants no BIOS and nothing said"
      return
    end

    outcome, place, phrase = answer
    if outcome == :found
      assert_equal ConsoleBIOS::Found.new(path: paths.fetch(place)), found, told.to_s
    else
      assert_kind_of ConsoleBIOS::Refused, found, told.to_s
      assert_equal paths.fetch(place), found.path, told.to_s
      assert_includes found.message, phrase, told.to_s
    end
  end
end
