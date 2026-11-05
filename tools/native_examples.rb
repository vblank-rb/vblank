#!/usr/bin/env ruby
# frozen_string_literal: true

# WHICH EXAMPLES THE NATIVE LOWERING CAN WRITE AS C TODAY, and what each of the others is refused
# for. The native backend trails the other two (see atop IR::Backends), so this list is how far
# it has got, said by trying each example rather than by anybody keeping a note.
#
#   ruby tools/native_examples.rb
#
# prints one line an example: its file's name, a tab, and `builds` or the reason it is refused.
# Nothing is compiled: an example builds when the lowering writes its C without a refusal, which
# takes a moment where a compile takes seconds.
#
# It is its own program rather than something a test calls in-process, because finding the game
# an example declares means watching VBlank.game while the example loads, and that is a change
# to the whole process no test may make (test/lowering/native/vblank/ir/backends/native/test_native_examples.rb
# runs this and reads what it prints).
require_relative "../lib/vblank"

module NativeExamples
  EXAMPLES = VBlank.root.join("examples").to_s

  # Each game an example declares, noted as VBlank.game hands it back, and each bot (a script that
  # plays a game in a match, VBlank.bot) as VBlank.bot does.
  module NoteDeclarations
    def game(*, **, &)
      super.tap { |made| NativeExamples.games << made }
    end

    def bot(*, **, &)
      super.tap { |made| NativeExamples.bots << made }
    end
  end

  def self.games = @games ||= []
  def self.bots = @bots ||= []

  # [the example's name, nil when it builds or the reason it does not], for every example.
  def self.verdicts
    VBlank.singleton_class.prepend(NoteDeclarations)
    Dir.glob(File.join(EXAMPLES, "*.rb")).sort.map do |path|
      [File.basename(path, ".rb"), refusal_after_loading(path)]
    end
  end

  def self.refusal_after_loading(path)
    games_before = games.length
    bots_before = bots.length
    require path
    declared = games[games_before..]
    if declared.empty? && bots.length > bots_before
      return "is a bot, which plays another example's game in a match and has no desktop build of its own"
    end
    return "declares no game through VBlank.game" if declared.empty?
    if declared.none? { |game| game.consoles.include?(:gba) }
      return "is for the Game Boy Color alone, and the desktop build plays games for the Advance"
    end

    native = VBlank::IR::Backends::Native.new
    declared.each { |game| native.lower(native.checked_program(game, err: nil)) }
    nil
  rescue StandardError, ScriptError => e
    e.message.lines.first.strip
  end
end

if $PROGRAM_NAME == __FILE__
  NativeExamples.verdicts.each { |name, refusal| puts "#{name}\t#{refusal || 'builds'}" }
end
