# frozen_string_literal: true

require "json"
require "rbconfig"

module VBlank
  module Live
    # THE PROCESS vblank run BECOMES TO PLAY A GAME A HELPER BUILDS (runtime/rg_window_main.rb). The
    # command replaces itself with a fresh Ruby (exec), so its own heap, the library and the game
    # file it loaded, is gone, and the helper it started stays this process's child. The fresh Ruby
    # loads only what a game written out as one Ruby file carries, from the library's own files, and
    # the window's wait for the build (BuildWatch).
    module WindowProcess
      # Whether this Ruby can become the window's process: it hands the helper a descriptor it
      # spawns it with (Process.spawn's descriptor mapping) and replaces itself keeping that
      # descriptor open (Kernel.exec), neither of which Windows or JRuby does.
      def self.available? = RUBY_ENGINE == "ruby" && !Gem.win_platform?

      # Becomes the window's process: +launch+ is what rg_window_main.rb reads (its comment lists
      # it), and +helper_pipe+ the end of the pipe the helper says what it is doing on, kept open
      # across, or nil when no helper builds (the game is written already). +zjit+ starts the new
      # Ruby with ZJIT, as the command's was. Never returns.
      def self.become(launch, helper_pipe:, zjit: false)
        runtime = IR::Backends::Ruby::RUNTIME_DIR
        loaded = IR::Backends::Ruby::SCRIPT_PARTS.map { |part| VBlank.root.join("lib", part).to_s } +
                 [File.join(runtime, "rg_script_main.rb"), File.join(__dir__, "build_watch.rb")]
        kept_open = helper_pipe ? { helper_pipe => helper_pipe } : {}
        # Must come just before exec, which runs no at_exit hook and finishes no object.
        Diagnostics::Verifier.remove_save_dir
        Kernel.exec(IR::Backends::Ruby::PROGRAM_ENVIRONMENT, RbConfig.ruby, *("--zjit" if zjit),
                    *loaded.flat_map { |path| ["-r", path] }, File.join(runtime, "rg_window_main.rb"),
                    JSON.generate(launch.merge(build_fd: helper_pipe&.fileno)), **kept_open)
      end
    end
  end
end
