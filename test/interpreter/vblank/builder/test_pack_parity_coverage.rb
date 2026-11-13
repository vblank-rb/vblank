# frozen_string_literal: true

require "test_helper"
require "pack_site_coverage"

# EVERY LINE OF THE BUILDER THAT TAKES A PACK HANDLE IS REACHED BY A REGISTERED GAME
# (PackSiteCoverage in test/pack_site_coverage.rb says how the lines are found and what reaching
# one means). The registry's games are held to their all-in-one builds by PackParityTests, so a
# verb with no game here is a verb nothing holds to that.
#
# It reads the builder's source and builds games without playing one, so one run of it is
# enough, and it is with the interpreter's own tests, beside the registry's on that run.
class TestPackParityCoverage < Minitest::Test
  # It starts a Ruby of its own, which a test in a Ractor cannot do.
  runs_on_the_main_ractor!

  def test_every_line_that_takes_a_pack_handle_is_reached_by_a_registered_game
    sites = PackSiteCoverage.sites
    reached = PackSiteCoverage.times_reached_by_site
    missed = sites.select { |site| reached.fetch(site.key).zero? && site.unreachable_reason.nil? }

    refute_empty sites, "the builder's source has lines that take a pack handle"
    assert_empty missed.map(&:in_words),
                 "No game registered in test/pack_games.rb reaches these lines of the builder with a pack handle. A verb " \
                 "that takes a pack handle needs a game there, so that its build with the pack left out is held to its " \
                 "all-in-one build, or to its refusal"
  end

  # A line marked as one no game can reach (PackSiteCoverage::UNREACHABLE) is still a site, and no
  # registered game reaches it: a mark left behind by a change, or one a game now reaches, comes off.
  def test_every_line_marked_unreachable_is_a_site_no_registered_game_reaches
    sites = PackSiteCoverage.sites
    reached = PackSiteCoverage.times_reached_by_site

    PackSiteCoverage::UNREACHABLE.each_key do |file, method_name|
      marked = sites.select { |site| site.file == file && site.method_name == method_name }
      refute_empty marked, "#{file} #{method_name} is marked unreachable in test/pack_site_coverage.rb and has no site. " \
                           "Take the mark off."
      marked.each do |site|
        assert_equal 0, reached.fetch(site.key), "#{site.in_words} is marked unreachable, and a registered game reaches it. " \
                                                 "Take the mark off."
      end
    end
  end

  # The lines are found by what they say, so a line that says it in a way the search does not
  # know would never be asked for. Each file that names the question or a handle has a site.
  def test_every_builder_file_that_names_a_pack_handle_has_a_site
    with_sites = PackSiteCoverage.sites.map(&:file).uniq
    naming = PackSiteCoverage::SOURCES.select do |file|
      code = File.readlines(VBlank.root.join(file)).reject { |line| line.strip.start_with?("#") }.join
      code.match?(/pack_left_out\?|PackSlot|PackNotes|PackNumber|PackEnvelope|PackSNESEnvelope|PackFrame/)
    end

    assert_equal naming.sort, (with_sites | ["lib/vblank/builder/data_packs.rb"]).sort
  end
end
