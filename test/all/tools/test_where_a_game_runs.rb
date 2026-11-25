# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("tools/where_a_game_runs").to_s

# tools/where_a_game_runs.rb draws the README's chart from Console::HardwareFeatures. The pictures
# committed and the README's words for them are what it would draw now: a list changed without
# running the tool fails here.
class TestWhereAGameRuns < Minitest::Test
  REGENERATE = "run ruby tools/where_a_game_runs.rb and commit what it writes"

  def test_each_committed_picture_is_what_the_tool_draws
    WhereAGameRuns::THEMES.each_key do |theme|
      path = WhereAGameRuns.path(theme)
      assert File.read(path) == WhereAGameRuns.svg(theme),
             "#{path.relative_path_from(VBlank.root)} differs from the hardware lists; #{REGENERATE}"
    end
  end

  def test_the_readme_alt_text_gives_the_same_counts
    assert_includes File.read(WhereAGameRuns.readme_path), WhereAGameRuns.alt_attribute,
                    "README.md's alt text for the chart differs from the hardware lists; #{REGENERATE}"
  end

  def test_a_bar_is_as_long_as_the_share_of_features_driven
    half = VBlank::Console::HardwareFeatures::Target.new(
      "Half", nil, [VBlank::Console::HardwareFeatures.driven("On"), VBlank::Console::HardwareFeatures.not_yet("Off")]
    )
    picture = WhereAGameRuns.svg("light", [half])

    assert_includes picture, %(width="191.0" height="12" rx="6" fill="#2f81f7")
    assert_includes picture, ">1 / 2</text>"
  end
end
