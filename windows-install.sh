#!/usr/bin/env bash

set -Eeuo pipefail

target_disk="${TARGET_DISK:-/dev/sda}"
installer_size_mib="${INSTALLER_SIZE_MIB:-16384}"
efi_size_mib=512
msr_size_mib=16
minimum_windows_size_mib=32768
mount_root=""
esp_mount=""
windows_mount=""
installer_mount=""
iso_mount=""
virtio_mount=""

error() {
    echo "Error: $*" >&2
    exit 1
}

cleanup() {
    for mount_path in "$virtio_mount" "$iso_mount" "$installer_mount" \
        "$windows_mount" "$esp_mount"; do
        if [[ -n "$mount_path" ]] && mountpoint -q "$mount_path" 2>/dev/null; then
            umount "$mount_path" || true
        fi
    done
    if [[ -n "$mount_root" && -d "$mount_root" ]]; then
        rmdir "$mount_root"/* "$mount_root" 2>/dev/null || true
    fi
}

trap 'echo "Error on line $LINENO; installation media was not completed." >&2' ERR

if (( EUID != 0 )); then
    error "Run this script as root."
fi

if [[ ! -d /sys/firmware/efi ]]; then
    error "This system is not currently booted in UEFI mode. GPT Windows boot setup requires UEFI."
fi

[[ -b "$target_disk" ]] || error "$target_disk is not a block device."

if lsblk -nrpo MOUNTPOINT "$target_disk" | grep -q '[^[:space:]]'; then
    error "$target_disk or one of its partitions is mounted. Boot into a rescue system first."
fi

mount_root="$(mktemp -d /tmp/windows-setup.XXXXXX)"
esp_mount="${mount_root}/esp"
windows_mount="${mount_root}/windows"
installer_mount="${mount_root}/installer"
iso_mount="${mount_root}/iso"
virtio_mount="${mount_root}/virtio"
trap cleanup EXIT

partition_path() {
    local partition_number="$1"
    if [[ "$target_disk" =~ [0-9]$ ]]; then
        printf '%sp%s' "$target_disk" "$partition_number"
    else
        printf '%s%s' "$target_disk" "$partition_number"
    fi
}

esp_partition="$(partition_path 1)"
msr_partition="$(partition_path 2)"
windows_partition="$(partition_path 3)"
installer_partition="$(partition_path 4)"

echo "*** Install required tools ***"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    dosfstools grub-efi-amd64-bin mokutil ntfs-3g parted rsync wget wimtools

for required_command in awk blockdev df grub-install lsblk mkfs.fat mktemp \
    mkfs.ntfs mount mountpoint parted partprobe rsync stat umount \
    wimlib-imagex; do
    command -v "$required_command" >/dev/null ||
        error "Required command not found: $required_command"
done

if mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
    error "Secure Boot is enabled. Disable it before using the temporary GRUB launcher."
fi

echo "*** Calculate GPT partition sizes ***"
disk_size_bytes="$(blockdev --getsize64 "$target_disk")"
disk_size_mib=$((disk_size_bytes / 1048576))

[[ "$disk_size_mib" =~ ^[0-9]+$ ]] ||
    error "Could not determine the size of $target_disk."
[[ "$installer_size_mib" =~ ^[0-9]+$ ]] ||
    error "INSTALLER_SIZE_MIB must be a positive integer."
(( installer_size_mib > 0 )) ||
    error "INSTALLER_SIZE_MIB must be greater than zero."

efi_end_mib=$((1 + efi_size_mib))
msr_end_mib=$((efi_end_mib + msr_size_mib))
installer_start_mib=$((disk_size_mib - installer_size_mib))
minimum_disk_size_mib=$((msr_end_mib + minimum_windows_size_mib + installer_size_mib))

if (( disk_size_mib < minimum_disk_size_mib )); then
    error "$target_disk is too small. At least ${minimum_disk_size_mib} MiB is required."
fi

echo
echo "Planned UEFI/GPT layout for $target_disk:"
echo "  1. EFI System:       ${efi_size_mib} MiB (permanent)"
echo "  2. Microsoft MSR:    ${msr_size_mib} MiB (permanent)"
echo "  3. Windows:          $((installer_start_mib - msr_end_mib)) MiB"
echo "  4. Windows installer:${installer_size_mib} MiB (temporary)"
echo
echo "*** WARNING: all data on $target_disk will be erased ***"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$target_disk"
read -r -p "Type ERASE $target_disk to continue: " erase_confirmation
[[ "$erase_confirmation" == "ERASE $target_disk" ]] ||
    error "Cancelled; $target_disk was not modified."

echo "*** Create the GPT partition table ***"
parted "$target_disk" --script -- mklabel gpt
parted "$target_disk" --script -- \
    mkpart "EFI System" fat32 1MiB "${efi_end_mib}MiB"
parted "$target_disk" --script -- set 1 esp on
parted "$target_disk" --script -- \
    mkpart "Microsoft reserved" "${efi_end_mib}MiB" "${msr_end_mib}MiB"
parted "$target_disk" --script -- set 2 msftres on
parted "$target_disk" --script -- \
    mkpart "Windows" ntfs "${msr_end_mib}MiB" "${installer_start_mib}MiB"
parted "$target_disk" --script -- set 3 msftdata on
parted "$target_disk" --script -- \
    mkpart "Windows installer" fat32 "${installer_start_mib}MiB" 100%
parted "$target_disk" --script -- set 4 msftdata on
partprobe "$target_disk"

for _ in {1..30}; do
    if [[ -b "$esp_partition" && -b "$msr_partition" &&
          -b "$windows_partition" && -b "$installer_partition" ]]; then
        break
    fi
    sleep 1
done

[[ -b "$esp_partition" && -b "$msr_partition" &&
   -b "$windows_partition" && -b "$installer_partition" ]] ||
    error "The kernel did not expose all four new partitions."

echo "*** Format the partitions ***"
mkfs.fat -F 32 -n SYSTEM "$esp_partition"
mkfs.ntfs -f -L WINDOWS "$windows_partition"
mkfs.fat -F 32 -n INSTALLER "$installer_partition"

mkdir -p "$esp_mount" "$windows_mount" "$installer_mount" \
    "$iso_mount" "$virtio_mount"
mount "$esp_partition" "$esp_mount"
mount "$windows_partition" "$windows_mount"
mount "$installer_partition" "$installer_mount"

download_or_upload_iso() {
    local display_name="$1"
    local output_path="$2"
    local answer
    local download_url

    read -r -p "Download ${display_name} from a URL now? (Y/N): " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        read -r -p "Enter the official HTTPS URL for ${display_name}: " download_url
        [[ "$download_url" == https://* ]] ||
            error "Only an explicit HTTPS URL is accepted."
        wget --https-only --output-document="$output_path" "$download_url"
    else
        echo "Upload ${display_name} to $output_path"
        read -r -p "Press Enter after the upload is complete..." _
    fi

    [[ -s "$output_path" ]] || error "$display_name was not provided."
}

windows_iso="${windows_mount}/Windows.iso"
download_or_upload_iso "Windows.iso" "$windows_iso"

echo "*** Copy Windows Setup to the temporary FAT32 partition ***"
mount -o loop,ro "$windows_iso" "$iso_mount"
[[ -f "${iso_mount}/efi/boot/bootx64.efi" ]] ||
    error "The Windows ISO does not contain a 64-bit UEFI bootloader."
[[ -f "${iso_mount}/sources/boot.wim" ]] ||
    error "The Windows ISO does not contain sources/boot.wim."

rsync -rlt --delete --no-perms --no-owner --no-group \
    --exclude='/sources/install.wim' \
    --exclude='/sources/install.esd' \
    "${iso_mount}/" "${installer_mount}/"

if [[ -f "${iso_mount}/sources/install.wim" ]]; then
    install_image="${iso_mount}/sources/install.wim"
elif [[ -f "${iso_mount}/sources/install.esd" ]]; then
    install_image="${iso_mount}/sources/install.esd"
elif compgen -G "${iso_mount}/sources/install*.swm" >/dev/null; then
    install_image=""
    rsync -rlt --no-perms --no-owner --no-group \
        "${iso_mount}"/sources/install*.swm "${installer_mount}/sources/"
else
    error "No install.wim, install.esd, or split install*.swm files were found."
fi

if [[ -n "$install_image" ]]; then
    install_image_size="$(stat -c %s "$install_image")"
    if (( install_image_size >= 4000000000 )); then
        echo "Splitting the Windows image for FAT32 compatibility..."
        wimlib-imagex split "$install_image" \
            "${installer_mount}/sources/install.swm" 3800
    else
        rsync -rt --no-perms --no-owner --no-group \
            "$install_image" "${installer_mount}/sources/"
    fi
fi

umount "$iso_mount"

read -r -p "Add VirtIO drivers to the installer? (Y/N): " add_virtio
if [[ "$add_virtio" =~ ^[Yy]$ ]]; then
    virtio_iso="${windows_mount}/Virtio.iso"
    download_or_upload_iso "Virtio.iso" "$virtio_iso"
    mount -o loop,ro "$virtio_iso" "$virtio_mount"
    driver_directory="${installer_mount}/\$WinPEDriver\$"
    mkdir -p "$driver_directory"
    rsync -rlt --no-perms --no-owner --no-group \
        "${virtio_mount}/" "${driver_directory}/"
    umount "$virtio_mount"
fi

available_installer_bytes="$(
    df -B1 --output=avail "$installer_mount" | awk 'NR == 2 {print $1}'
)"
(( available_installer_bytes > 268435456 )) ||
    error "The installer partition has less than 256 MiB free."

echo "*** Install temporary UEFI GRUB launcher ***"
grub-install \
    --target=x86_64-efi \
    --efi-directory="$esp_mount" \
    --boot-directory="${installer_mount}/boot" \
    --removable \
    --no-nvram \
    --recheck

mkdir -p "${installer_mount}/boot/grub"
cat > "${installer_mount}/boot/grub/grub.cfg" <<'EOF'
insmod part_gpt
insmod fat

search --no-floppy --label --set=installer INSTALLER

menuentry "Windows installer (UEFI/GPT)" {
    chainloader ($installer)/efi/boot/bootx64.efi
    boot
}
EOF

[[ -f "${esp_mount}/EFI/BOOT/BOOTX64.EFI" ]] ||
    error "The fallback UEFI GRUB loader was not created."
[[ -f "${installer_mount}/efi/boot/bootx64.efi" ]] ||
    error "The Windows UEFI installer loader is missing."

sync
echo
echo "UEFI/GPT Windows installation media is ready."
echo "In Windows Setup, install to the partition labelled WINDOWS."
echo "Do not delete or format SYSTEM, Microsoft reserved, or INSTALLER."
echo "After Windows boots directly, delete INSTALLER and extend WINDOWS."
echo "If a Recovery partition appears between them, it must be moved first."

read -r -p "Reboot now? (Y/N): " reboot_choice
if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
    cleanup
    trap - EXIT
    reboot
fi
