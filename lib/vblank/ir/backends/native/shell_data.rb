# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Native
        # WHAT A SHELL KNOWS, AS C (runtime/rg_shell.c reads it): Original::Shell#facts, the one list of
        # what a runtime is told about a shell, as the nodes of the C tree for the struct runtime/rg_shell.h
        # declares. Printer writes them. A build that is no shell (and each part of a shell) gets a file
        # that says it has none.
        module ShellData
          # The file the build writes it to, beside the runtime's own.
          FILE = "rg_shell_data.c"

          # Where the parts of a shell are, under the folder the program is in.
          PARTS_FOLDER = "parts"
          MENU_PART = "menu"

          # Facts that are one number or one piece of text, written as the field of the same name.
          SCALARS = %i[title folder releases_title called choice_variable load_rom_choice settings_choice bytes_list
                       finished_variable fault_variable].freeze

          FACTS = C::Name.new("rg_shell_facts")
          DESCRIPTION = C::Name.new("description")

          module_function

          def unpacking_part(number) = "unpack-#{number}"

          # The top level of the file for +shell+ (an Original::Shell), or for none.
          def items(shell = nil)
            include = C::Include.new(header: "rg_shell.h")
            return [include, facts_pointer(C::Name.new("NULL"))] unless shell

            facts = shell.facts
            [include, releases(facts[:releases]), bytes("before", facts[:before]), bytes("after", facts[:after]),
             C::ConstArray.new(name: C::Name.new("pack_rules"), type: "int32_t", values: pack_rules(facts)),
             C::ConstGlobal.new(name: DESCRIPTION, type: "rg_shell_description", value: C::Struct.new(fields: fields(facts))),
             facts_pointer(C::AddressOf.new(name: DESCRIPTION))]
          end

          def facts_pointer(value)
            C::ConstGlobal.new(name: FACTS, type: "rg_shell_description *const", value: value, exported: true)
          end

          def bytes(name, data) = C::ConstArray.new(name: C::Name.new(name), type: "uint8_t", values: data.bytes)

          # Each release's entry, and the file of the part that unpacks it.
          def releases(releases)
            entries = releases.map do |release|
              part = release[:unpacking] ? unpacking_part(release[:unpacking]) : ""
              C::Struct.new(fields: { name: C::Text.new(value: release[:name]), sha1: C::Text.new(value: release[:sha1].to_s),
                                      size: C::Int.new(value: release[:size] || -1), readable: C::Int.new(value: release[:readable] ? 1 : 0),
                                      part: C::Text.new(value: part) })
            end
            C::ConstArray.new(name: C::Name.new("releases"), type: "rg_shell_release", values: entries)
          end

          # The numbers rg_start_file_open takes: the pack's size, how many checks, and each check as
          # where it is, how long, and its bytes.
          def pack_rules(facts)
            checks = facts[:checks]
            [facts[:pack_size], checks.size, *checks.flat_map { |check| [check[:at], check[:bytes].bytesize, *check[:bytes].bytes] }]
          end

          def fields(facts)
            scalars = SCALARS.to_h do |name|
              value = facts.fetch(name)
              [name, value.is_a?(Integer) ? C::Int.new(value: value) : C::Text.new(value: value)]
            end
            scalars.merge(releases: C::Name.new("releases"), release_count: C::Int.new(value: facts[:releases].size),
                          before: C::Name.new("before"), before_size: C::Int.new(value: facts[:before].bytesize),
                          after: C::Name.new("after"), after_size: C::Int.new(value: facts[:after].bytesize),
                          pack_rules: C::Name.new("pack_rules"), menu_part: C::Text.new(value: MENU_PART))
          end
        end
      end
    end
  end
end
