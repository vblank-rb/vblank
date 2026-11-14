# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Native
        # ONE PROGRAM, WRITTEN OUT AS C. Make one per program and ask for #source.
        #
        # Computer::Lowering builds the tree of statements; this prints it as C with Printer.
        class Lowering < Computer::Lowering
          # The program as one C file's text. Its big tables of bytes are embedded from files beside
          # it (#source_files), so text that is to be compiled comes from there.
          def source = source_files.fetch(GAME_FILE)

          # The program's C files, by name: game.c, and the file each big table of bytes is embedded
          # from (Printer#embedded), all to be written in one folder.
          def source_files
            refuse_unlowered_kinds!
            printer = Printer.new
            { GAME_FILE => printer.print_file(top_level), **printer.embedded }
          end

          # The name of the file the program's text is compiled from.
          GAME_FILE = "game.c"

          private

          def build_name = "the desktop build"

          # The C name for each width of item, as runtime/rg_list.h suffixes its typed functions.
          ITEM_TYPE_SUFFIXES = { 1 => "int8", 2 => "int16", 4 => "int32" }.freeze

          # The function for the list's own width (rg_list_get_int32 for a list of whole numbers),
          # so the C knows the width where it is written and a game's reads and writes test none
          # on the way: a list of whole numbers is read as fast as one was before narrow lists
          # were kept narrow.
          def item_access_function(function, name)
            "#{function}_#{ITEM_TYPE_SUFFIXES.fetch(SLOT_BYTES.fetch(@lists.fetch(name).width))}"
          end
        end
      end
    end
  end
end
