# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # Where a game's songs go in the cartridge, over as many of its banks as they need.
        #
        # Two things make up a Super Nintendo game's sound, and they are kept in different places:
        #
        # - The sound chip's own memory, 64K that the console's processor cannot see. What goes there
        #   is the sound chip's program, the table of its recordings and the recordings themselves
        #   (Runtime::Sound#image). It is sent once at power-on, a byte at a time through the
        #   mailboxes, and a scene's own recordings are sent as the scene starts. In the cartridge it
        #   is already cut into pieces of 16K, each a section the linker puts in any bank
        #   (Sound::START_PIECE_BYTES, Sound::PIECE_BYTES), so it was never held to one bank. Its
        #   limit is the chip's memory, which Sound#image refuses in plain words, and the cartridge
        #   reports how much of it the game uses (Cartridge::SNESROM#sound_memory).
        # - The songs and sound effects, the table the music player reads (SNES::Music, a SongTable).
        #   The player runs on the console's own processor (Runtime::Music gives why), so this table
        #   is never sent to the sound chip: the player reads it from the cartridge, a note at a
        #   time, and each note is register writes sent through the mailboxes as it starts.
        #
        # So the one-bank limit a long song met was the song table's. The player reads the table
        # with a 24-bit address and a 16-bit index from one label, "music_data", and a cartridge laid
        # out the LoROM way shows each 32K of itself as the top half of a bank of its own: no stretch
        # of more than 32K is in view at one run of addresses, whatever the index is. A section
        # therefore holds at most a bank (Linker), and so did the table.
        #
        # The decision. Nearly all of a long table is notes: sixteen bytes each, and everything else a
        # song is (its groups of chip writes, its records, its parts' entries) is shared between
        # notes and small. So a table that fits a bank is laid out exactly as it always was, one
        # section, and a game that fits builds the bytes it always did. A table that does not fit is
        # built again with the song parts' notes apart (SongTable#words' +notes_apart+): the rest
        # stays the one section "music_data", read as before, and the notes go in pieces of
        # NOTES_A_PIECE, a bank each, which the linker puts in any banks. A part's entry then names
        # its first note by number, and the player (Runtime::Music, "A song's notes apart") finds a
        # note's piece from the high bits of its number and its place in the piece from the low,
        # through the list of where each piece went ("music_note_pieces", at the end of
        # "music_data"), and copies the note that is due into work RAM, where every routine that
        # reads a note reads it. A sound effect's notes stay in the table, where the player reads
        # them as before. So what still has to fit one bank is the table without the song parts'
        # notes: the groups, the records, the parts' entries and the sound effects whole. A song's
        # groups are few, since each is kept once however many notes share it; a game whose rest
        # of the table is still more than a bank is refused by the linker, naming the songs and
        # sound effects.
        #
        # Why a note is sixteen bytes, and a long song so big. Each event of a part is a note of
        # eight words (SongTable's "a note"), and a converted song is mostly a note and the rest
        # after it, two events for each note heard. A song that comes round keeps its parts' events
        # twice, for the first time round and the times after (IR::Tunes.loop_passes). A cut that
        # would be general: a game no note of whose songs wobbles, slides or steps its shapes needs
        # no NOTE_WOBBLE or NOTE_SHAPES word, so its notes could be twelve bytes, the player's step
        # from note to note being NOTE_BYTES of the game's own. That changes every song game's
        # cartridge and the Genesis's player, which reads the same table, so it is its own piece of
        # work, not this one's.
        #
        # This module is where that is decided: given the table both ways, it hands back the sections
        # and whether the notes went apart, which is what the player is written for (Laid). The layout
        # of the sound chip's memory stays Runtime::Sound's, since what is in its pieces and how big
        # they are is decided by how they are sent.
        #
        # A note's number is 16 bits, so the songs can have 65,536 notes, sixteen bytes each, which
        # is a megabyte of the cartridge; more is refused in plain words (#refuse_too_many_notes!).
        class SongBanks
          NOTES_A_PIECE = Linker::BANK_SIZE / Music::NOTE_BYTES
          NOTE_WORDS = Music::NOTE_BYTES / 2
          MOST_NOTES = 0x10000
          PIECES_LABEL = "music_note_pieces" # Where each piece of notes went: three bytes, then a nought
          PIECE_ENTRY_BYTES = 4

          # The sections the songs are kept in, and whether the song parts' notes are apart from the
          # rest of the table (and so the player reads them from its copy).
          Laid = Data.define(:sections, :notes_apart) do
            def notes_apart? = notes_apart
          end

          # The sections of +music+'s table (an SNES::Music). The block gives the table's words, with
          # the song parts' notes apart when it is handed true and in the table when false
          # (SongTable#words).
          def self.lay_out(music)
            table = yield(false)
            return Laid.new(sections: [music.section(table)], notes_apart: false) if table.size * 2 <= Linker::BANK_SIZE

            table = yield(true)
            notes = music.apart_note_words
            refuse_too_many_notes!(notes.size / NOTE_WORDS)
            pieces = notes.each_slice(NOTES_A_PIECE * NOTE_WORDS).each_with_index.map do |words, number|
              asm = W65816.new(piece_label(number), holds: Music::SONGS)
              asm.label(piece_label(number))
              asm.data_words(words)
              asm.section
            end
            Laid.new(sections: [table_section(table, pieces.size), *pieces], notes_apart: true)
          end

          def self.piece_label(number) = "music notes #{number}"

          # "music_data": the table, and after it where each piece went.
          def self.table_section(table, pieces)
            asm = W65816.new("music", holds: Music::SONGS)
            asm.label("music_data")
            asm.data_words(table)
            asm.label(PIECES_LABEL)
            pieces.times do |number|
              asm.data_longs(piece_label(number))
              asm.data_bytes(0)
            end
            asm.section
          end

          def self.refuse_too_many_notes!(count)
            return if count <= MOST_NOTES

            raise LoweringError, "This game's songs have #{count} notes and rests. A song that repeats keeps its " \
                                 "notes two times, one time for the first play and one time for the plays after it. " \
                                 "The Super Nintendo build gives each note and rest a number of 16 bits, so it can " \
                                 "keep #{MOST_NOTES} of them. To fix this, make the songs shorter, or use fewer of them."
          end
        end
      end
    end
  end
end
