# The licence of this folder

`dosbox-vblank-probe.patch` is a change to DOSBox (libretro's dosbox-svn core), so it is under
DOSBox's licence, the GNU General Public License version 2 or later. Its full text is `COPYING` in
the source.

The patch is the only DOSBox code in this repository. DOSBox itself is downloaded from where
it is published, and built on the machine that wants it. VBlank's gem does not carry either:
`ruby-dos-emulator` is not in VBlank's gemspec.

The licence does not reach the games built with VBlank. A DOS program holds none of DOSBox: the
emulator only plays it, to check it.
