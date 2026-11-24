# frozen_string_literal: true

require "json"
require "rbconfig"

module VBlank
  module Live
    # The process vblank run becomes to play a game a helper builds (runtime/rg_window_main.rb). The
    # command replaces itself with a fresh Ruby (exec), so its own heap, the library and the game
    # file it loaded, is gone, and the helper it started stays this process's child. The fresh Ruby
    # loads only what a game written out as one Ruby file carries, from the library's own files, and
    # the window's wait for the build (BuildWatch).
    module WindowProcess
      # Whether this Ruby can become the window's process: it hands the helper a descriptor it
      # spawns it with (Process.spawn's descriptor mapping) and replaces itself keeping that
      # descriptor open (Kernel.exec), neither of which Windows or JRuby does.
      def self.available? = RUBY_ENGINE == "ruby" && !Gem.win_platform?

      # What the window loads besides what a script carries for a match over a network (Live::MatchPlay):
      # the network module, the tape of a match it writes when two machines stop agreeing, the device
      # a match with no window plays on, and the library's logger, which the network writes to. A
      # written-out script carries none of it, and a window that plays no match loads none of it.
      MATCH_PARTS = %w[vblank/logger.rb vblank/playthroughs/tape.rb vblank/network.rb vblank/live/headless.rb
                       vblank/live/match_play.rb].freeze

      # MATCH_PARTS as the paths of the library's files, for a window that loads them only once its menu
      # starts a match (rg_window_main.rb's match_from_menu).
      def self.match_part_paths = MATCH_PARTS.map { |part| VBlank.root.join("lib", part).to_s }

      # Becomes the window's process: +launch+ is what rg_window_main.rb reads (its comment lists
      # it), and +helper_pipe+ the end of the pipe the helper says what it is doing on, kept open
      # across, or nil when no helper builds (the game is written already). +zjit+ starts the new
      # Ruby with ZJIT, as the command's was. +match+ loads MATCH_PARTS too, and +shell+ what a
      # shell's script carries besides (Ruby::SHELL_PARTS). Never returns.
      def self.become(launch, helper_pipe:, zjit: false, match: false, shell: false)
        runtime = IR::Backends::Ruby::RUNTIME_DIR
        parts = IR::Backends::Ruby::SCRIPT_PARTS + (match ? MATCH_PARTS : []) + (shell ? IR::Backends::Ruby::SHELL_PARTS : [])
        loaded = parts.map { |part| VBlank.root.join("lib", part).to_s } +
                 [File.join(runtime, "rg_script_main.rb"), File.join(__dir__, "build_watch.rb")]
        kept_open = helper_pipe ? { helper_pipe => helper_pipe } : {}
        # Must come just before exec, which runs no at_exit hook and finishes no object.
        Diagnostics::Verifier.remove_save_dir
        Kernel.exec(IR::Backends::Ruby::PROGRAM_ENVIRONMENT, IR::Backends::Ruby::RUBY_PROGRAM, *("--zjit" if zjit),
                    *loaded.flat_map { |path| ["-r", path] }, File.join(runtime, "rg_window_main.rb"),
                    JSON.generate(launch.merge(build_fd: helper_pipe&.fileno)), **kept_open)
      end
    end
  end
end
