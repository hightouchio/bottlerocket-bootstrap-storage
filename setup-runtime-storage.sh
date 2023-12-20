#!/bin/bash

# Adapted from https://github.com/bottlerocket-os/bottlerocket/discussions/1991#discussioncomment-3265188

set -ex
shopt -s nullglob

# we are in a special container with access to host rootfs + host dev && mnt
BR_ROOT=/.bottlerocket/rootfs

# build mount variables
# the path of kubelet we want to mount on ephemeral disk
KUBELET_PATH=var/lib/kubelet
# path for the mounted disk
MOUNT_NAME=mnt/kubelet
# the path we want to mount the partition to
MOUNT_POINT=${BR_ROOT}/${MOUNT_NAME}
# the path on host we will symlink to the mount
ROOT_PATH=${BR_ROOT}/${KUBELET_PATH}

# declare a lovely bash array... :)
declare -a EPHEMERAL_DISKS
# Symlinks to ephemeral disks are created here by udev
EPHEMERAL_DISKS=(${BR_ROOT}/dev/disk/ephemeral/*)

# skip software raid when there is only a single instance disk
if [ ${#EPHEMERAL_DISKS[@]} -eq 1 ]; then
  echo "single disk -- skipping raid setup"
  DISK=$(readlink -f ${EPHEMERAL_DISKS[0]})
  MOUNTABLE_PARTITION=${DISK}p1
  # setup raid0 if there are more than 1 instance disks
elif [ ${#EPHEMERAL_DISKS[@]} -gt 1 ]; then
  echo "more than one disk, initializing raid0"
  MD_NAME="ephstore"
  MOUNTABLE_PARTITION="/dev/md/${MD_NAME}"
  MD_CFG=/.bottlerocket/bootstrap-containers/current/mdadm.conf

  if [ -s ${MD_CFG} ]; then
    mdadm --assemble --config=${MD_CFG} ${MD_DEV}
  else
    # create striped (raid0) array of # of devices
    mdadm --create ${MOUNTABLE_PARTITION} --name=${MD_NAME} --level=stripe --raid-devices=${#EPHEMERAL_DISKS[@]} ${EPHEMERAL_DISKS[@]}
    mdadm --detail --scan > ${MD_CFG}

    MKFS_OPTS="-b 4096  -E stride=128,stripe-width=$((${#EPHEMERAL_DISKS[@]} * 128))"
  fi
  # Exit early if there aren't any instance disks
else
  echo "No instance storage - proceeding with boot"
  # returning 0 because if we exit 1 the node will be broken...
  # in case we try to use this container on a node without instance storage
  exit 0
fi

# If the partition doesn't exist, create it (on non-raid disks)
if [ ! -e ${MOUNTABLE_PARTITION} ]; then
  parted -s ${DISK} mklabel gpt 1>/dev/null
  parted -s ${DISK} mkpart primary ext4 0% 100% 1>/dev/null
fi

if [ "$(blkid ${MOUNTABLE_PARTITION} -s TYPE |egrep -o 'TYPE="ext."')" != 'TYPE="ext4"' ]; then
  mkfs.ext4 ${MKFS_OPTS} -F ${MOUNTABLE_PARTITION}
fi

# mount it
mkdir -p ${MOUNT_POINT}
mount -t ext4 ${MOUNTABLE_PARTITION} ${MOUNT_POINT}

# Bottlerocket >= 1.9.0 supports bind mounts for ${BR_ROOT}/var/lib resources

# Keep track of whether we can unmount the array later. This depends on the
# version of Bottlerocket.
SHOULD_UMOUNT="no"

# Bind state directories to the array, if they exist.
for state_dir in kubelet ; do
  # The correct next step depends on the version of Bottlerocket, which can be
  # inferred by inspecting the mounts available to the bootstrap container.
  if findmnt "${BR_ROOT}/var/lib/${state_dir}" ; then
    # For Bottlerocket >= 1.9.0, the state directory can be bind-mounted over
    # the host directory and the mount will propagate back to the host.
    mkdir -p "${MOUNT_POINT}/${state_dir}"
    mount --rbind "${MOUNT_POINT}/${state_dir}" "${BR_ROOT}/var/lib/${state_dir}"
    mount --make-rshared "${BR_ROOT}/var/lib/${state_dir}"
    SHOULD_UMOUNT="yes"
  elif [ ! -L "${BR_ROOT}/var/lib/${state_dir}" ] ; then
    # For Bottlerocket < 1.9.0, the host directory needs to be replaced with a
    # symlink to the state directory on the array. This works but can lead to
    # unexpected behavior or incompatibilities, for example with CSI drivers.
    if [ -d  "${BR_ROOT}/var/lib/${state_dir}" ] ; then
      # The host directory exists but is not a symlink, and might need to be
      # relocated to the storage array. This depends on whether the host has
      # been downgraded from a newer version of Bottlerocket, or whether it's
      # the first boot of an older version.
      if [ -d "${MOUNT_POINT}/${state_dir}" ] ; then
        # If downgrading from a version of Bottlerocket that supported bind
        # mounts, the directory will exist but should be empty, except for
        # subdirectories that may have been created by tmpfiles.d before an
        # upgrade to that version. Keep a copy of the directory just in case.
        rm -rf "${BR_ROOT}/var/lib/${state_dir}.bak"
        mv "${BR_ROOT}/var/lib/${state_dir}"{,.bak}
      else
        # Otherwise, treat it as the first boot of an older version, and move
        # the directory to the array.
        mv "${BR_ROOT}/var/lib/${state_dir}" "${MOUNT_POINT}/${state_dir}"
      fi
    else
      # The host directory does not exist, so the target directory likely needs
      # to be created.
      mkdir -p "${MOUNT_POINT}/${state_dir}"
    fi
    # Any host directory has been dealt with and the symlink can be created.
    ln -snfT "/mnt/${MD_NAME}/${state_dir}" "${BR_ROOT}/var/lib/${state_dir}"
  fi
done

# When using bind mounts, the parent directory where the array is mounted can
# be unmounted. This avoids a second, redundant mount entry under `/mnt` for
# every new mount in one of the state directories.
if [ "${SHOULD_UMOUNT}" == "yes" ] ; then
  umount "${MOUNT_POINT}"
fi
