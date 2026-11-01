# frozen_string_literal: true

# WHERE A PLAYER'S SETTINGS FOLDERS ARE, as a table both copies of the rule are held to: the Ruby
# one (Live::SettingsFile.root) and the C one (runtime/rg_settings_root.h). Each row is what the
# rule is told and the folder it answers, nil for leaving it to the operating system's own place.
module SettingsRootCases
  CASES = Ractor.make_shareable(
    [[{ config_dir: "/asked", xdg: "/xdg", home: "/home/p", linux: true }, "/asked"],
     [{ config_dir: "/asked", xdg: nil, home: nil, linux: false }, "/asked"],
     [{ config_dir: nil, xdg: "/xdg", home: "/home/p", linux: true }, "/xdg/vblank"],
     [{ config_dir: nil, xdg: "/xdg", home: "/home/p", linux: false }, "/xdg/vblank"],
     [{ config_dir: nil, xdg: "not/from/the/root", home: "/home/p", linux: true }, "/home/p/.config/vblank"],
     [{ config_dir: nil, xdg: "", home: "/home/p", linux: true }, "/home/p/.config/vblank"],
     [{ config_dir: nil, xdg: nil, home: "/home/p", linux: true }, "/home/p/.config/vblank"],
     [{ config_dir: nil, xdg: nil, home: "/home/p", linux: false }, nil],
     [{ config_dir: nil, xdg: nil, home: nil, linux: true }, nil]]
  )
end
