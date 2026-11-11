# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Native
        # WHAT A SHELL KNOWS, AS C (runtime/rg_shell.c reads it): Original::ShellFacts, the one record
        # every runtime is made from, as the nodes of the C tree for the struct runtime/rg_shell.h
        # declares, every sentence a file is refused in among them. Printer writes them. A build that
        # is no shell (and each part of a shell) gets a file whose facts are NULL.
        module ShellData
          Statements = Computer::Statements

          # The file the build writes it to, beside the runtime's own.
          FILE = "rg_shell_data.c"

          # Where the parts of a shell are, under the folder the program is in.
          PARTS_FOLDER = "parts"

          FACTS = Statements::Name.new("rg_shell_facts")
          DESCRIPTION = Statements::Name.new("description")

          module_function

          # The name of the file of an Original::Shell::Part under PARTS_FOLDER (the game's is the
          # folder's own name, beside it).
          def part_name(part) = { menu: "menu", unpacking: "unpack-#{part.number}" }.fetch(part.role)

          # The top level of the file for +shell+ (an Original::Shell), or for none.
          def items(shell = nil)
            include = Statements::Include.new(header: "rg_shell.h")
            return [include, facts_pointer(Statements::Name.new("NULL"))] unless shell

            facts = shell.facts
            parts = shell.parts.reject { |part| part.role == :game }.to_h { |part| [[part.role, part.number], part_name(part)] }
            [include, *release_files(facts), releases(facts, parts), bytes("pack_before_sha1", facts.pack_before_sha1),
             bytes("pack_after_sha1", facts.pack_after_sha1),
             Statements::ConstArray.new(name: Statements::Name.new("pack_rules"), type: "int32_t", values: facts.pack_rules.numbers),
             Statements::ConstGlobal.new(name: DESCRIPTION, type: "rg_shell_description",
                                value: Statements::Struct.new(fields: fields(facts, parts.fetch([:menu, nil])))),
             facts_pointer(Statements::AddressOf.new(name: DESCRIPTION))]
          end

          def facts_pointer(value)
            Statements::ConstGlobal.new(name: FACTS, type: "rg_shell_description *const", value: value, exported: true)
          end

          def bytes(name, data) = Statements::ConstArray.new(name: Statements::Name.new(name), type: "uint8_t", values: data.bytes)

          def text(value) = Statements::Text.new(value: value.to_s)

          # Each release's entry: the file of the part that unpacks it ("" for a release the game does
          # not read), the sentence for a copy of it where the game does not read it, and for a release
          # that is several files, its files (#release_files).
          def releases(facts, parts)
            entries = facts.releases.each_with_index.map do |release, number|
              files = release.files || []
              Statements::Struct.new(fields: { name: text(release.name), sha1: text(release.sha1), size: Statements::Int.new(value: release.size || -1),
                                      read: Statements::Int.new(value: release.read ? 1 : 0),
                                      part: text(release.unpacking && parts.fetch([:unpacking, release.unpacking])),
                                      unread_words: text(facts.release_words.unread[release.name]),
                                      files: files.empty? ? Statements::Name.new("NULL") : Statements::Name.new(release_files_name(number)),
                                      file_count: Statements::Int.new(value: files.size) })
            end
            Statements::ConstArray.new(name: Statements::Name.new("releases"), type: "rg_shell_release", values: entries)
          end

          # The files of each release that is several files, in the release's order: each one's name,
          # SHA-1 and size.
          def release_files(facts)
            facts.releases.each_with_index.filter_map do |release, number|
              next unless release.files

              entries = release.files.map do |file|
                Statements::Struct.new(fields: { name: text(file.fetch("name")), sha1: text(file.fetch("sha1")),
                                        size: Statements::Int.new(value: file.fetch("size")) })
              end
              Statements::ConstArray.new(name: Statements::Name.new(release_files_name(number)), type: "rg_shell_file", values: entries)
            end
          end

          def release_files_name(number) = "release_#{number}_files"

          def fields(facts, menu_part)
            rules = facts.pack_rules.words
            words = facts.release_words
            { title: text(facts.title), folder: text(facts.folder), pack_file: text(facts.pack_file),
              releases: Statements::Name.new("releases"), release_count: Statements::Int.new(value: facts.releases.size),
              wrong_size_words: text(words.wrong_size), unknown_words: text(words.unknown),
              one_file_words: text(words.one_file), folder_words: text(words.folder), lacking_words: text(words.lacking),
              release_lacks_words: text(words.release_lacks), wrong_file_words: text(words.wrong_file),
              lacking_join: text(words.lacking_join), missing_join: text(words.missing_join),
              pack_before_sha1: Statements::Name.new("pack_before_sha1"), pack_before_sha1_size: Statements::Int.new(value: facts.pack_before_sha1.bytesize),
              pack_after_sha1: Statements::Name.new("pack_after_sha1"), pack_after_sha1_size: Statements::Int.new(value: facts.pack_after_sha1.bytesize),
              pack_rules: Statements::Name.new("pack_rules"),
              pack_words: Statements::Struct.new(fields: { missing: text(rules.missing), wrong_size: text(rules.wrong_size),
                                                  wrong_check: text(rules.wrong_check) }),
              menu_part: text(menu_part), choice_variable: text(facts.menu.choice_variable),
              load_rom: Statements::Int.new(value: facts.menu.load_rom), settings: Statements::Int.new(value: facts.menu.settings),
              line_variable: text(facts.menu.line_variable),
              bytes_list: text(facts.unpacking.bytes), finished_variable: text(facts.unpacking.finished),
              fault_kind_variable: text(facts.unpacking.fault_kind),
              kept_pack_refused_words: text(facts.words.kept_pack_refused),
              unpacking_stopped_words: text(facts.words.unpacking_stopped), unreadable_words: text(facts.words.unreadable) }
          end
        end
      end
    end
  end
end
