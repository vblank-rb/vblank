# frozen_string_literal: true

require "digest"
require "fileutils"

# WHERE A PLAYER'S GAME BOY ADVANCE BIOS IS FOUND, and whether it is used, as a table both copies of
# the rule are held to: the Ruby one (Live::ConsoleBIOS.find) and the C one
# (runtime/rg_console_bios.h). No test has a real BIOS: it is Nintendo's, and never goes in the
# repository. So the files here are made up, and the rule is told which SHA-1 to accept (the
# made-up :known file's) in place of the retail BIOS's.
#
# Each row is what each of the three places holds and the answer. A place holds nothing (nil), a
# file the rule accepts (:known), a file of the right size it does not know (:unknown), a file of
# the wrong size (:short), a path with no file at it (:missing), or, for the environment variable,
# an empty string (:empty). The shared folder can also be one that could not be made (:no_folder).
# An answer is :none, [:found, place] or [:refused, place, a phrase its message says].
module ConsoleBIOSCases
  CASES = Ractor.make_shareable(
    [[{ environment: nil, setting: nil, shared: nil }, :none],
     [{ environment: nil, setting: nil, shared: :no_folder }, :none],
     [{ environment: nil, setting: nil, shared: :known }, [:found, :shared]],
     [{ environment: nil, setting: nil, shared: :unknown }, [:refused, :shared, "SHA-1 checksum"]],
     [{ environment: nil, setting: nil, shared: :short }, [:refused, :shared, "16384 bytes"]],
     [{ environment: :known, setting: nil, shared: :known }, [:found, :environment]],
     [{ environment: :missing, setting: nil, shared: :known }, [:refused, :environment, "VBLANK_GBA_BIOS"]],
     [{ environment: :empty, setting: nil, shared: :known }, [:found, :shared]],
     [{ environment: nil, setting: :known, shared: :unknown }, [:found, :setting]],
     [{ environment: :unknown, setting: :known, shared: nil }, [:refused, :environment, "SHA-1 checksum"]],
     [{ environment: nil, setting: :missing, shared: nil }, [:refused, :setting, "settings file"]]]
  )

  KNOWN_BYTES = ("\x5A".b * 16_384).freeze
  UNKNOWN_BYTES = ("\xA5".b * 16_384).freeze
  SHORT_BYTES = ("\x5A".b * 100).freeze
  # The one SHA-1 the rule is told to accept here: the made-up :known file's.
  KNOWN_SHA1 = Digest::SHA1.hexdigest(KNOWN_BYTES).freeze

  private

  # Makes the files +told+ says inside +dir+, and gives the three things the rule is told: the
  # environment variable's value, the settings file's, and the shared folder (or nil), with the
  # path each place stands for.
  def console_bios_places(dir, told)
    shared_folder = File.join(dir, "(all games)")
    FileUtils.mkdir_p(shared_folder)
    paths = { environment: File.join(dir, "from environment.bin"), setting: File.join(dir, "from setting.bin"),
              shared: File.join(shared_folder, "gba_bios.bin") }
    told.each { |place, kind| write_console_bios(paths.fetch(place), kind) }
    { environment: told[:environment] == :empty ? "" : (paths[:environment] if told[:environment]),
      setting: (paths[:setting] if told[:setting]),
      shared_folder: (shared_folder unless told[:shared] == :no_folder),
      paths: paths }
  end

  def write_console_bios(path, kind)
    bytes = { known: KNOWN_BYTES, unknown: UNKNOWN_BYTES, short: SHORT_BYTES }[kind]
    File.binwrite(path, bytes) if bytes
  end
end
