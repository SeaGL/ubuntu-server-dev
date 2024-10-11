#!/usr/bin/env bash

set -euo pipefail

trap 'echo failed' ERR

# TODO validate args and print help text

version=$1
imgname=ubuntu-server-dev
codename=$(curl https://api.launchpad.net/devel/ubuntu/series | jq -r '.entries[] | select(.version == "'$version'") | .name')

echo "Building Ubuntu Server dev image for $version $codename..."

# TODO verify this file
# TODO deal with checking for updates to this file, somehow
filename=ubuntu-$version-server-cloudimg-amd64-root.tar.xz
wget --no-clobber https://cloud-images.ubuntu.com/releases/$version/release/$filename

if ! [ $(id -u) = 0 ]; then
	# Need to be actual root to `mknod` things in /dev.
	# Being root obviates the need for `buildah unshare`, which throws errors because root is not in /etc/subuid.
	# https://github.com/containers/buildah/issues/1657#issuecomment-504737328
	echo 'Reexecuting under root...'
	sudo "$0" "$@"
	echo 'Transferring to unprivileged user...'
	sudo podman save $imgname:{$codename,$version} | podman load
	echo 'Cleaning up root user image...'
	sudo podman rmi $imgname:{latest,$codename,$version}
	exit 0
fi

newcontainer=$(buildah from scratch)

mnt=$(buildah mount $newcontainer)

# We extract from tar into a mount instead of using `buildah copy` to ensure as direct a path as possible into the final image, so that all these extra attributes are correctly created
tar_options=(
	--extract --file="$filename" --directory="$mnt"
	--acls --numeric-owner --preserve-permissions --same-owner --selinux --xattrs
)
[ -t 1 ] || tar_options+=(--verbose)
tar "${tar_options[@]}"

# Disable TPM-related units, which fail at runtime in the container environment
systemctl --root=$mnt disable tpm-udev.path

# Slice rootfs config out of fstab, since LABEL=cloudimg-rootfs doesn't exist in the container environment and systemd-remount-fs.service complains about not being able to find it
chroot $mnt /bin/sed -i '/LABEL=cloudimg-rootfs/d' /etc/fstab

# Networking setup is expected to not actually cross a network boundary (i.e. only talk to the container host), so decrease the timeout because all operations here should be fast
mkdir $mnt/etc/systemd/system/systemd-networkd-wait-online.service.d/
cat > $mnt/etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf <<EOF
[Service]
TimeoutSec=10s
EOF

# Generate SSH keys on first boot
cat > $mnt/etc/systemd/system/ssh-hostkey-generate.service <<EOF
[Unit]
Description=Properly configure OpenSSH keys on first container boot
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_rsa_key

[Service]
Type=oneshot
Environment=DEBIAN_FRONTEND=noninteractive
ExecStart=apt-get install --reinstall -qq -y openssh-server

[Install]
WantedBy=ssh.service
EOF
systemctl --root=$mnt enable ssh-hostkey-generate.service

buildah config --author='AJ Jordan' --arch=amd64 --cmd=/bin/systemd --created-by='https://github.com/SeaGL/ubuntu-server-dev' $newcontainer
buildah config --label org.opencontainers.image.source=https://github.com/SeaGL/ubuntu-server-dev --label org.opencontainers.image.description='Ubuntu Server cloud rootfs in a container, for development environments ONLY' --label org.opencontainers.image.version=$version --label org.opencontainers.image.created="$(date --rfc-3339 seconds)" $newcontainer

buildah commit --rm $newcontainer $imgname
buildah tag $imgname $imgname:$version $imgname:$codename
