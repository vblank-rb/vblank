# frozen_string_literal: true

# Parts keeping working room in instance variables, for
# test/all/vblank/builder/test_saves_keep_everything.rb. A save never needs a flash's counts
# back after a load, so the first part marks them `saved: false`; the second names the same
# counts without the mark, and the last marks them and has a save keep one anyway.

# Counts 1, 2, 3 on each pass; the bonus starts counting by 2 from the second pass.
module FlashCounting
  def tick
    @damage += 1
    @bonus += 2 if @damage > 1
  end
end

class ScreenFlash
  include FlashCounting
  game_variables :damage, bonus: :flash_bonus, saved: false

  def initialize(builder)
    @damage = 0
    @bonus = 0
    builder.func(:screen_flash_tick) { tick }
  end
end

class UnmarkedScreenFlash
  include FlashCounting
  game_variables :damage, :bonus

  def initialize(builder)
    @damage = 0
    @bonus = 0
    builder.func(:unmarked_screen_flash_tick) { tick }
  end
end

# Marked late, by test_saves_keep_everything_reopened_class.rb reopening the class once an object
# of it has started: @damage has its first number then, and @bonus gets its own only when game
# code calls #start_bonus.
class LateScreenFlash
  game_variables :damage, :bonus

  def initialize
    @damage = 0
  end

  def start_bonus
    @bonus = 5
  end
end

class KeptScreenFlash
  include FlashCounting
  game_variables :damage, :bonus, saved: false

  def initialize(builder)
    @damage = 0
    @bonus = 0
    builder.save_data(:flash).keep(@damage)
    builder.func(:kept_screen_flash_tick) { tick }
  end
end
