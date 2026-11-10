# frozen_string_literal: true

require_relative "computer/error"
require_relative "computer/program_run"
require_relative "computer/checked_program"
require_relative "computer/statements"
require_relative "computer/names"
require_relative "computer/start_file_numbers"
require_relative "computer/console_numbers"
require_relative "computer/resumable"
require_relative "computer/drawn_sprites"
require_relative "computer/picture"
require_relative "computer/sound_log"
require_relative "computer/sound"
require_relative "computer/saving"
require_relative "computer/start_file_fills"
require_relative "computer/lowering"
require_relative "computer/headless_run"
require_relative "computer/differences"
require_relative "computer/check"

module VBlank
  module IR
    module Backends
      # What the builds for a computer share, whether the game is written as C (Native), as
      # JavaScript (JS) or as Ruby (Ruby): the statement tree the lowering builds
      # (Statements, Lowering), the runtimes' numbers (ConsoleNumbers), the way a program that
      # waits for a frame is cut into steps (Resumable), the windowless run that reads a built
      # program's printed lines back and the check of it against the interpreter (HeadlessRun,
      # Differences, Check), and the running of a built program (ProgramRun). A build adds only how its
      # own language writes the tree and how its own program is started.
      module Computer
      end
    end
  end
end
