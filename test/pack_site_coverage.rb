# frozen_string_literal: true

require "json"
require "open3"
require "prism"
require "rbconfig"

# WHICH LINES OF THE BUILDER TAKE A PACK HANDLE, AND WHICH REGISTERED GAME REACHES EACH. Every
# verb that reads a data pack does it on a line that asks whether the pack is left out
# (`pack_left_out?`) or whether it was given a handle (`is_a?(DSL::PackSlot)` and its kin), so
# those lines are read out of the builder's source, never kept as a list. A verb made tomorrow
# has such a line, and with no game in the registry (PackGames, test/pack_games.rb) that reaches
# it, test/interpreter/vblank/builder/test_pack_parity_coverage.rb fails naming the line.
#
# "Reaches" is measured, not read: a Ruby of its own (test/support/pack_site_coverage_run.rb)
# builds every registered game both ways with Ruby's Coverage counting branches, and a line counts
# for a game only when its question was answered yes while that game was built: the `if` taken,
# the `unless` passed. So a game that calls the verb with data of its own does not count.
#
# WHAT THIS CANNOT SEE: a verb that takes a pack picture, list or table by its NAME has no such
# line (`sprite_tiles.copy_from :picture`). A game for each of those is registered by hand.
module PackSiteCoverage
  ROOT = VBlank.root
  SOURCES = Ractor.make_shareable(["lib/vblank/builder.rb", *Dir.glob("lib/vblank/builder/**/*.rb", base: ROOT.to_s)].sort)
  RUNNER = "test/support/pack_site_coverage_run.rb"

  # A line is a site when its code names one of these.
  ASKS_WHETHER_LEFT_OUT = /(?<!def )\bpack_left_out\?/
  HANDLE = /\bDSL::Pack(?:Slot|Notes|Number|Envelope|SNESEnvelope|Frame)\b/

  # One such line: its file, its number, the method it is in and its text.
  Site = Data.define(:file, :line, :method_name, :text) do
    def key = "#{file}:#{line}"
    def in_words = "#{key} in #{method_name}: #{text}"
  end

  module_function

  # Every site in the builder's source.
  def sites
    SOURCES.flat_map do |file|
      source = File.read(ROOT.join(file))
      methods = methods_by_lines(source)
      source.lines.each_with_index.filter_map do |text, at|
        code = text.strip
        next if code.start_with?("#") || !(code.match?(ASKS_WHETHER_LEFT_OUT) || code.match?(HANDLE))

        Site.new(file: file, line: at + 1, method_name: methods.fetch(at + 1, "the file's top"), text: code)
      end
    end
  end

  # The name of the innermost method each line of +source+ is in, by line number.
  def methods_by_lines(source)
    named = {}
    walk = lambda do |node|
      (node.location.start_line..node.location.end_line).each { |line| named[line] = node.name.to_s } if node.is_a?(Prism::DefNode)
      node.compact_child_nodes.each(&walk)
    end
    walk.call(Prism.parse(source).value)
    named
  end

  # HOW MANY TIMES THE QUESTION ON +site+'s LINE WAS ANSWERED YES, in +measured+, Ruby's count of
  # one file ({ lines:, branches: }): the count of the branch taken when the test on that line
  # holds (the body of an `if`, the way past an `unless`), the count of the line after for a
  # `when`, and for a line that tests nothing the count of the line itself.
  def count_of_yes(site, measured)
    return measured.fetch(:lines)[site.line].to_i if site.text.start_with?("when ")

    test = test_on_line(site.line, measured.fetch(:branches))
    return measured.fetch(:lines)[site.line - 1].to_i unless test

    (kind, *), targets = test
    wanted = kind == :unless ? :else : :then
    targets.sum { |(branch, *), count| branch == wanted ? count : 0 }
  end

  # The innermost `if` or `unless` whose test is on +line+: one that starts there, or one that
  # started above and whose body has not begun.
  def test_on_line(line, branches)
    branches.select do |(kind, _, first, *), targets|
      next false unless %i[if unless].include?(kind)

      first == line || (first < line && line < targets.keys.map { |target| target[2] }.min)
    end.max_by { |(_, _, first, *), _| first }
  end

  # How many times the registered games reach each site, by Site#key, measured in a Ruby of its
  # own, since Ruby counts only the files loaded after the counting starts. The runner's
  # `--report` says which game reaches which.
  def times_reached_by_site
    settings = { "COVERAGE" => nil, "TEST" => nil, "TESTOPTS" => nil }
    out, err, status = Open3.capture3(settings, RbConfig.ruby, "-Itest", "-Ilib", RUNNER, chdir: ROOT.to_s)
    raise "#{RUNNER} failed:\n#{err}\n#{out}" unless status.success?

    JSON.parse(out.lines.last)
  end
end
