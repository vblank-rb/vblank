# syntax=docker/dockerfile:1

# Two clean machines, built by tools/gem_install_check.rb, which says why. A step that fails fails
# the build.
#
# THE ORDER IS WHAT MAKES A SECOND RUN QUICK. Docker keeps every finished step and reuses it until
# something the step reads changes, and then it redoes that step and the ones after. So what rarely
# changes comes first, the gem comes next, and the game comes last: changing the game replays the
# game without installing again, and changing the gem reuses the system packages. A gem with the
# same bytes as the last run reuses everything, since it passed. What can't be kept is the install
# itself, which builds both emulators and is the thing being proved.

ARG RUBY_VERSION=4.0.9

# Nothing but Ruby. The packages are downloaded here and not installed, so this machine still has
# no compiler, and a later step can install them without fetching them again.
FROM ruby:${RUBY_VERSION}-slim AS bare
ENV DEBIAN_FRONTEND=noninteractive
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
 && apt-get update -qq \
 && apt-get install -y -qq --download-only --no-install-recommends \
      build-essential ca-certificates libmgba-dev pkg-config
WORKDIR /game

# Nothing but Ruby, and the gem must still install and build every console's cartridge, while each
# emulator says what is missing.
FROM bare AS bare-install
COPY vblank.gem /check/
RUN gem install --no-document /check/vblank.gem

FROM bare-install AS bare-refused
RUN ls /usr/local/bundle/gems/vblank-*/LICENSE.md /usr/local/bundle/gems/vblank-*/ruby-snes-emulator/core/LICENSE.md
COPY walk.rb expect_refusal.rb ./
RUN vblank build walk.rb && ls walk.gba walk.gbc walk.sfc
RUN ruby expect_refusal.rb

# From the install and not from the game above, so that changing the game builds no emulator. The
# tools arrive, and the fix those messages give must make both emulators work.
FROM bare-install AS bare-repaired
RUN apt-get install -y -qq --no-install-recommends \
      build-essential ca-certificates libmgba-dev pkg-config
RUN gem pristine vblank

# The tools were there first, so a plain `gem install` must leave both emulators working.
FROM bare AS tools
RUN apt-get install -y -qq --no-install-recommends \
      build-essential ca-certificates libmgba-dev pkg-config

FROM tools AS equipped-install
COPY vblank.gem /check/
RUN gem install --no-document /check/vblank.gem

# The same game's own tests on either machine: each cartridge played in its emulator and checked
# against the interpreter, then once more inside a game's bundle.
FROM bare-repaired AS bare-played
COPY walk.rb test_walk.rb Gemfile play.sh ./
RUN sh play.sh

FROM equipped-install AS equipped-played
COPY walk.rb test_walk.rb Gemfile play.sh ./
RUN sh play.sh

# All of them, so that one build runs the machines side by side.
FROM scratch AS passed
COPY --from=bare-refused /game/walk.sfc /refused/
COPY --from=bare-played /game/walk.sfc /bare/
COPY --from=equipped-played /game/walk.sfc /equipped/
