#!/usr/bin/env bash
# The release notes for a tag, in Markdown on stdout:
#
#   tools/release-notes.sh <tag>
#
# The kernel and Armbian versions, how to install, then the changes since the previous
# release, from the conventional commits (git-cliff with cliff.toml).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here"
tag=${1:?usage: release-notes.sh <tag>}
kernel=$(sed -n 's/^declare -g KERNELBRANCH=tag:v//p' userpatches/config-opi5.conf)
armbian=$(sed -n 's/^ARMBIAN_TAG=//p' build.sh)
prev=$(git describe --tags --abbrev=0 --match 'v[0-9]*-[0-9]*' --exclude "$tag" HEAD 2> /dev/null || true)

cat << EOF
Linux $kernel with Armbian $armbian, for the Orange Pi 5 Pro. On an Armbian \`current\` install:

\`\`\`sh
sha256sum --check --ignore-missing SHA256SUMS
apt install ./linux-image-*.deb ./linux-dtb-*.deb ./linux-headers-*.deb
apt-mark hold linux-image-current-rockchip64 linux-dtb-current-rockchip64 linux-headers-current-rockchip64
reboot
\`\`\`

\`linux-u-boot-orangepi5pro-current\` is Armbian's U-Boot with the fix for the Ethernet missing on about half of the boots. It doesn't depend on the kernel, and installing it doesn't write it to the boot device. See the README's U-Boot section.

To build it yourself, extract \`opi5-userpatches-$tag.tar.gz\` into armbian/build at $armbian and run \`./compile.sh opi5 kernel\` and \`./compile.sh opi5 uboot\`.

EOF
range=()
if [[ -n $prev ]]; then
	echo "## Changes since $prev"
	range=("$prev..HEAD")
else
	echo "## Changes"
fi
# Without git-cliff's leading blank lines.
changes=$(git cliff --config cliff.toml --strip all "${range[@]}" | sed '/./,$!d')
echo
echo "${changes:-No changes listed: a rebuild.}"
