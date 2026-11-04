# The licence of this folder

`beetle-vblank-probe.patch` is a change to Beetle PSX, so it is under Beetle PSX's licence, the GNU
General Public License version 2, and not VBlank's MIT licence. Its full text is `COPYING` in the
source, at <https://github.com/libretro/beetle-psx-libretro>.

The patch is the only Beetle PSX code in this repository. Beetle PSX itself is downloaded from where it
is published, and built on the machine that wants it. VBlank's gem does not carry either:
`ruby-ps1-emulator` is not in VBlank's gemspec.

The licence does not reach the games built with VBlank. A PlayStation program holds none of Beetle
PSX: the emulator only plays it, to check it. Nor does it hold any BIOS: the core runs OpenBIOS (MIT),
which is built into Beetle PSX.
