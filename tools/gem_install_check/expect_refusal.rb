# frozen_string_literal: true

require "vblank"

# With no tools on the machine, each emulator must refuse with the reason and the fix.
{ "walk.gba" => -> { VBlank::Diagnostics::Emulator.open("walk.gba") },
  "walk.sfc" => -> { VBlank::Diagnostics::Emulator.open_snes("walk.sfc") } }.each do |cartridge, open|
  begin
    open.call
    abort "#{cartridge} played on a machine with no emulator"
  rescue LoadError => e
    abort "#{cartridge} said no fix:\n#{e.message}" unless e.message.include?("gem pristine vblank")
    puts "#{cartridge} refused, saying:\n#{e.message}"
  end
end
