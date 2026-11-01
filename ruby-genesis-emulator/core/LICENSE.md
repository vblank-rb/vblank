# The licence of this folder

`gpgx-vblank-probe.patch` is a change to Genesis Plus GX, so it is under Genesis Plus GX's licence and
not VBlank's MIT licence. That licence is non-commercial: the code and anything made from it may not
be sold or used in a commercial product or activity. Its full text is `LICENSE.txt` in the source, at
<https://github.com/libretro/Genesis-Plus-GX>.

The patch is the only Genesis Plus GX code in this repository. Genesis Plus GX itself is downloaded
from where it is published, and built on the machine that wants it. VBlank's gem does not carry either:
`ruby-genesis-emulator` is not in VBlank's gemspec.

The licence does not reach the games built with VBlank. A cartridge holds none of Genesis Plus GX: the
emulator only plays it, to check it.
