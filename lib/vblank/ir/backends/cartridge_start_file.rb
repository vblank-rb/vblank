# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # A CARTRIDGE IS NEVER HANDED A FILE AS IT STARTS. A game built with its data pack left out
      # reads its pack from one (IR::StartFile), and a cartridge holds its own data. The build
      # refuses such a game at `data_pack` in plain words (Builder::DataPacks); this is the backstop
      # every cartridge lowering calls first, for a program that reached it some other way.
      #
      # +program+ is the program to lower, +console+ the Console::Description of the cartridge's
      # console, and +error+ the lowering's own error class.
      def self.refuse_start_file_on_cartridge!(program, console, error)
        file = program.start_file
        return unless file

        raise error, "This program reads its #{file.called} from a file it is handed as it starts. A #{console.title} " \
                     "cartridge holds its own data, and nothing hands it a file. Build the cartridge all-in-one."
      end
    end
  end
end
