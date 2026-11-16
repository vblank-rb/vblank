# frozen_string_literal: true

# LateScreenFlash reopened before @bonus has its first number: in time to mark it. For
# test/all/vblank/builder/test_saves_keep_everything_reopened_class.rb.
class LateScreenFlash
  game_variables :bonus, saved: false
end
