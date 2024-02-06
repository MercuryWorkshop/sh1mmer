#!/bin/busybox sh
# mostly copied from https://chromium.googlesource.com/chromiumos/platform/initramfs/+/0ffae881990b6895f25d11492ffacbc2e1afd627/factory_shim/bootstrap.sh#279

NEWROOT_MNT="$1"
REAL_USB_DEV="$2" # can be substituted with STATEFUL_DEV

copy_lsb() {
	echo "Copying lsb"
	local lsb_file="dev_image/etc/lsb-factory"
	local src_path="/mnt/stateful_partition/${lsb_file}"
	local dest_path="${NEWROOT_MNT}/mnt/stateful_partition/${lsb_file}"
	if [ -f "${dest_path}" ]; then
		echo "Already exists"
		return
	fi
	mkdir -p "$(dirname ${dest_path})"
	rm -rf "${dest_path}"
	if [ -f "${src_path}" ]; then
		echo "Found ${src_path}"
		cp -a "${src_path}" "${dest_path}"
	else
		echo "Failed to find ${src_path}!! Creating empty file."
		touch "${dest_path}"
	fi
}

copy_factory_script() {
	echo "Copying factory scripts"
	local factory_script="dev_image/factory/sh"
	local src_path="/mnt/stateful_partition/${factory_script}"
	local dest_path="${NEWROOT_MNT}/mnt/stateful_partition/${factory_script}"
	if [ -d "${dest_path}" ]; then
		echo "Already exists"
		return
	fi
	mkdir -p "$(dirname ${dest_path})"
	rm -rf "${dest_path}"
	if [ -d "${src_path}" ]; then
		echo "Found ${src_path}"
		cp -a "${src_path}" "${dest_path}"
	else
		echo "Failed to find ${src_path}!! Creating empty directory."
		mkdir "${dest_path}"
	fi
}

can_patch_file() {
	local file="$1"
	if [ -e "${file}" ]; then
		echo -n " +${file#${NEWROOT_MNT}}"
		true
	else
		echo -n " -${file#${NEWROOT_MNT}}"
		false
	fi
}

patch_new_root_misc() {
	echo "Patching new root in ${NEWROOT_MNT}..."
	local file job
	# TODO(hungte) The patch_new_root is so complicated now and hard to change
	# when debugging factory install shim VT (Frecon) or Upstart problems.
	# We should move this to src/platform/factory_installer scripts and execute
	# from ${NEWROOT_MNT}, to allow patching from rootfs.
	# Copy essential binaries that are in the initramfs, but not in the root FS.
	cp /bin/busybox ${NEWROOT_MNT}/bin || :
	${NEWROOT_MNT}/bin/busybox --install ${NEWROOT_MNT}/bin || :
	# Never execute the firmware updater from shim.
	touch "${NEWROOT_MNT}"/root/.leave_firmware_alone || :
	# Modify some files that does not work (and not required) in tmpfs chroot.
	# This may be removed when we can build factory installer in "embedded" mode.
	file="${NEWROOT_MNT}/usr/sbin/mount-encrypted"
	if can_patch_file "${file}"; then
		echo '#!/bin/sh' >"${file}"
		echo 'echo "Sorry, $0 is disabled on factory installer image."' >>"${file}"
	fi
	# Set network to start up another way
	file="${NEWROOT_MNT}/etc/init/boot-complete.conf"
	if can_patch_file "${file}"; then
		sed -i 's/login-prompt-visible/started boot-services/' "${file}"
	fi
	# Disable upstart jobs that will block execution for factory shim environment.
	# syslog is disabled because it expects rsyslogd exists,
	# but we don't have rsyslogd in factory shim.
	local disabled_jobs
	disabled_jobs="arc-oemcrypto powerd swap syslog tpm-probe ui update-engine"
	for job in ${disabled_jobs}; do
		file="${NEWROOT_MNT}/etc/init/${job}.conf"
		if can_patch_file "${file}"; then
			# Upstart honors the last 'start on' clause it finds.
			echo "start on never" >>"${file}"
		fi
	done
	# Dummy jobs are empty single shot tasks because there may be services waiting
	# them to finish.
	# - pre-startup.conf: will mount new /tmp and /run, which we want to preserve.
	# - boot-splash.conf: will try to invoke another frecon instance.
	local dummy_jobs="pre-startup boot-splash"
	for job in ${dummy_jobs}; do
		file="${NEWROOT_MNT}/etc/init/${job}.conf"
		if can_patch_file "${file}"; then
			sed -i '/^start /!d' "${file}"
			echo "exec true" >>"${file}"
		fi
	done
	# We don't want any consoles to be executed.
	rm -f "${NEWROOT_MNT}"/etc/init/console-*.conf
	# The laptop_mode may be triggered from udev
	rm -f "${NEWROOT_MNT}/etc/udev/rules.d/99-laptop-mode.rules"
	# Replicate running data (/run).
	tar -cf - /run | tar -xf - -C "${NEWROOT_MNT}"
	# frecon[-lite] creates TTY files in /dev/pts and have symlinks in
	# /run/frecon. However, /dev/pts will be re-created by chromeos_startup after
	# switch_root. As a result, we want to keep a copy of /dev/pts in /dev/frecon
	# and change symlinks to use them
	if [ -d /run/frecon ]; then
		local new_pts="/dev/frecon-lite"
		mkdir -p "${new_pts}"
		mount --bind /dev/pts "${new_pts}"
		for vt in "${NEWROOT_MNT}"/run/frecon/vt*; do
			# It is assumed all vt* should refer to /dev/pts/*.
			file="$(basename $(readlink -f "${vt}"))"
			rm -f "${vt}"
			ln -s "${new_pts}/${file}" "${vt}"
		done
	fi
}

factory_bootstrap_exists() {
	local bootstrap="${NEWROOT_MNT}/usr/sbin/factory_bootstrap.sh"
	[ -x "${bootstrap}" ]
}

run_factory_bootstrap() {
	local bootstrap="${NEWROOT_MNT}/usr/sbin/factory_bootstrap.sh"
	echo "Running ${bootstrap}..."
	"${bootstrap}" "${NEWROOT_MNT}" "${REAL_USB_DEV}"
}

if factory_bootstrap_exists; then
	run_factory_bootstrap || :
else
	copy_factory_script || :
	patch_new_root_misc || :
fi
copy_lsb || :
