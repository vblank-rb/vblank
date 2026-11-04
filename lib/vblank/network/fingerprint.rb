# frozen_string_literal: true

require "digest"

module VBlank
  module Network
    # WHICH GAME, BUILT FOR WHICH CONSOLE, as a value two machines can compare. Machines that play one
    # match each run the whole game, so they must run the same program: one extra line in one build
    # and the machines would walk away from each other without a word. The digest is taken over the
    # program as the build made it (IR::Dump writes it out the same way every time), and the console
    # is named beside it because the same game for another console is another program and the words a
    # person is told about it are not the same.
    #
    # +title+ is only for a person: a refusal says "WANDERERS" and not a string of letters. It is
    # not part of what is compared.
    Fingerprint = Data.define(:title, :console, :digest) do
      # The fingerprint of +program+, a program checked and built for a computer.
      def self.of(program, title:)
        digest = Digest::SHA256.hexdigest("#{program.console}\n#{IR::Dump.source(program)}")
        new(title: title, console: program.console.to_s, digest: digest)
      end

      # Whether +other+ is the same program for the same console.
      def same_as?(other) = digest == other.digest && console == other.console

      # The first eight digits of the digest, for a report: enough to tell two builds apart.
      def short = digest[0, 8]

      # The same eight digits as a number, which a tape of the match writes as the game's checksum.
      def checksum = digest[0, 8].to_i(16)
    end
  end
end
