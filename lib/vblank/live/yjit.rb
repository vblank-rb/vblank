# frozen_string_literal: true

module VBlank
  module Live
    # YJIT compiles the Ruby that runs most often to machine code as the game plays, which plays a
    # game built as Ruby several times faster. `vblank run` turns it on as it starts; a check or a
    # film that plays the game in this process (ShellCheck, Diagnostics::FilmShell) turns it on as
    # well, since the process that runs it (a port's rake task or film script) was most likely
    # started without it.
    #
    # It is left as it is where Ruby has no YJIT, where ZJIT, Ruby's other compiler, is on, where
    # RUBY_YJIT_ENABLE is "0" (the person asking for none, to measure the play without it), and in
    # a Ractor other than the main one: a suite playing its tests in Ractors keeps YJIT off on
    # purpose, as several Ractors at once make it many times slower (Testing::TestTask#yjit?).
    def self.turn_on_yjit
      return unless defined?(RubyVM::YJIT) && !RubyVM::YJIT.enabled?
      return if defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled?
      return if !Ractor.main? || ENV["RUBY_YJIT_ENABLE"] == "0"

      RubyVM::YJIT.enable
    end
  end
end
