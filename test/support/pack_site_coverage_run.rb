# frozen_string_literal: true

# WHICH REGISTERED PACK GAME REACHES WHICH LINE OF THE BUILDER, measured (PackSiteCoverage,
# test/pack_site_coverage.rb, starts this and reads its last line). Ruby counts only the files it
# loads after the counting starts, so this is a Ruby of its own that starts counting first, then
# loads the library, builds every registered game all-in-one and with its pack left out, and
# prints as JSON how many times the games reached each site, by the site's key.
#
#   ruby -Itest -Ilib test/support/pack_site_coverage_run.rb           the JSON alone
#   ruby -Itest -Ilib test/support/pack_site_coverage_run.rb --report  each game's sites, and each
#                                                                      site's games, for a person

require "coverage"
Coverage.start(lines: true, branches: true)

require "test_helper"
require "pack_games"
require "pack_site_coverage"

sites = PackSiteCoverage.sites
counts = lambda do
  measured = Coverage.peek_result
  sites.to_h do |site|
    file = measured[PackSiteCoverage::ROOT.join(site.file).to_s]
    [site.key, file ? PackSiteCoverage.count_of_yes(site, file) : 0]
  end
end

# Reading the counts takes longer than building a game, so only the report reads them after each
# game, to say which game reached what; the test wants only what all of them reached.
report = ARGV.include?("--report")
reached = Hash.new { |games, key| games[key] = [] }
PackGames::ALL.each do |game|
  before = counts.call if report
  [PackGames::ALL_IN_ONE, PackGames::LEFT_OUT].each do |options|
    Dir.mktmpdir do |folder|
      game.kit.new.build(game, folder, options)
    rescue ArgumentError, VBlank::BuildError
      # A game registered as refused: the line that refuses it was reached all the same.
    end
  end
  counts.call.each { |key, count| reached[key] << game.name if count > before.fetch(key) } if report
end

if report
  PackGames::ALL.each do |game|
    methods = sites.select { |site| reached[site.key].include?(game.name) }.map(&:method_name).uniq
    puts "#{game.name}#{game.refused ? ' (refused)' : ''}: #{methods.join(', ')}"
  end
  puts
  sites.each { |site| puts "#{site.in_words}\n    #{reached[site.key].join(', ')}" }
else
  puts JSON.generate(counts.call)
end
$stdout.flush
# Without minitest's own run as the process ends: this loaded test files to get their games.
exit!(0)
