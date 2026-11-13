# frozen_string_literal: true

# A PART'S GAME VARIABLE ONLY SOME BUILDS HAVE, written in normal Ruby in a file of a game's own:
# brought in by `VBlank.require_game_file` for test/all/vblank/dsl/test_plain_ruby_parts.rb.
#
# A lift keeps whether the secret lever called it, and only a build with a secret floor has one.
# Whether there is one is plain Ruby, decided while building, so a build without it skips each line
# that names `@secret` and has no variable for it. SecretLiftWithoutSecretPart is the same lift
# never naming `@secret`, which such a build is held to.

# The test after the line (`@secret = called if @secret_floor`).
class SecretLiftPart
  game_variables secret: :lift_secret_called

  def initialize(build, secret_floor:)
    @build = build
    @secret_floor = secret_floor
    @secret = 0 if @secret_floor
  end

  def start(called)
    @secret = called if @secret_floor
    @build.call :lift_go
  end
end

# The test as a block `if` that reads `@secret` too, after the plain test.
class SecretLiftByBlockPart
  game_variables secret: :lift_secret_called

  def initialize(build, secret_floor:)
    @build = build
    @secret_floor = secret_floor
    @secret = 0 if @secret_floor
  end

  def start(called)
    if @secret_floor && @secret == 0
      @secret = called
    end
    @build.call :lift_go
  end
end

# The test after the line, inside a test the game makes.
class SecretLiftUnderGameTestPart
  game_variables secret: :lift_secret_called

  def initialize(build, secret_floor:)
    @build = build
    @secret_floor = secret_floor
    @secret = 0 if @secret_floor
  end

  def start(called)
    if called == 1
      @secret = called if @secret_floor
    end
    @build.call :lift_go
  end
end

# The same lift with no secret floor at all, which SecretLiftUnderGameTestPart's build without one
# is held to.
class SecretLiftUnderGameTestWithoutSecretPart
  def initialize(build, secret_floor:)
    @build = build
    @secret_floor = secret_floor
  end

  def start(called)
    if called == 1
    end
    @build.call :lift_go
  end
end

# A lift that never starts `@secret`, and gives it a number only under a test the game makes: on
# a pass where the test fails it would hold nil, which no game variable can.
class SecretLiftNeverStartedPart
  game_variables secret: :lift_secret_called

  def initialize(build, secret_floor:)
    @build = build
    @secret_floor = secret_floor
  end

  def start(called)
    @secret = called if called == 1
    @build.call :lift_go
  end
end

# The lift with no secret floor at all.
class SecretLiftWithoutSecretPart
  def initialize(build, secret_floor:)
    @build = build
    @secret_floor = secret_floor
  end

  def start(_called) = @build.call(:lift_go)
end

# The game: +part+ made with or without a secret floor, its lever called on every pass.
def secret_lift_game(build, part, secret_floor:)
  lift = part.new(build, secret_floor: secret_floor)
  called = build.var(:_called, 1)
  build.func(:lift_go) {}
  build.game_loop { lift.start(called) }
end
