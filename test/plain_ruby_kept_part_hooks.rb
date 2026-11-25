# frozen_string_literal: true

# Parts that wire themselves to another part as they are made, brought in by
# `VBlank.require_game_file` for test/all/vblank/dsl/test_plain_ruby_parts.rb. Each is kept with
# `@part ||= Part.new(...)` in a scene, so Ruby runs its `initialize` once: the block it hands
# HookList#after, and the names it hands Costume#wear, go into the other part's plain Ruby Array
# once, while the game is built.

# Blocks to run after each frame, kept in a plain Ruby Array.
class HookList
  def initialize
    @asked = []
  end

  def after(&asked)
    @asked << asked
  end

  def run = @asked.each(&:call)
end

# Hands a HookList a block that counts, as it is made.
class HookCounted
  game_variables :count

  def initialize(hooks)
    @count = 0
    hooks.after { @count += 1 }
  end
end

# The names of the pictures a costume wears, kept in a plain Ruby Array.
class Costume
  def initialize
    @worn = []
  end

  def wear(names)
    @worn.concat(names)
  end

  def worn_count = @worn.length
end

# Adds the pictures it needs to a Costume, as it is made, and starts counting from how many the
# costume wears then.
class CostumeJump
  game_variables :jumps

  def initialize(costume)
    costume.wear(%i[crouch leap])
    @jumps = costume.worn_count
  end

  def jump = @jumps += 1
end

# A scene keeping a HookCounted and a CostumeJump, and running the hooks on every pass.
class HookPlay
  def initialize(builder)
    @builder = builder
    @hooks = HookList.new
    @costume = Costume.new
    declare
  end

  def declare
    hooks = @hooks
    costume = @costume
    @builder.scene :hook_play do
      @counted ||= HookCounted.new(hooks)
      @jump ||= CostumeJump.new(costume)
      @jump.jump
      hooks.run
    end
  end
end

# The same push made from the scene itself, which runs on every pass: refused.
class HookPlayEachPass
  def initialize(builder)
    @builder = builder
    @hooks = HookList.new
    declare
  end

  def declare
    hooks = @hooks
    @builder.scene :hook_play_each_pass do
      @counted ||= HookCounted.new(hooks)
      hooks.after { nil }
      hooks.run
    end
  end
end

def hook_play_game(build)
  HookPlay.new(build)
  mode = :hook_play
  build.game_loop do
    mode = :hook_play
    build.call mode
  end
end

def hook_play_each_pass_game(build)
  HookPlayEachPass.new(build)
  mode = :hook_play_each_pass
  build.game_loop do
    mode = :hook_play_each_pass
    build.call mode
  end
end
