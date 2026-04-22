#!/usr/bin/env python3
import argparse
from contextlib import suppress
from io import BytesIO
from pathlib import Path

from pycdlib import PyCdlib
from pycdlib.pycdlibexception import PyCdlibException


RUN_OEM_INSTALL_SH = """\
#!/bin/bash
# OEM Installation Wrapper Script
# Runs user-provided /opt/oem/install.sh on first boot

set -e

OEM_DIR="/opt/oem"
LOG_FILE="$OEM_DIR/install.log"
USER_SCRIPT="$OEM_DIR/install.sh"
COMPLETED_MARKER="$OEM_DIR/.completed"

# Skip if already completed
if [ -f "$COMPLETED_MARKER" ]; then
    exit 0
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "Starting OEM installation..."

if [ -f "$USER_SCRIPT" ]; then
    log "Running user install script: $USER_SCRIPT"
    bash "$USER_SCRIPT" >> "$LOG_FILE" 2>&1
    EXIT_CODE=$?
    log "User install script finished with exit code: $EXIT_CODE"
else
    log "No user install script found at $USER_SCRIPT, skipping..."
    EXIT_CODE=0
fi

# Mark as completed
touch "$COMPLETED_MARKER"
log "OEM installation completed!"

exit $EXIT_CODE
"""

SETUP_OEM_INSTALL_SH = """\
#!/bin/bash
# OEM Setup Script - called from user-data late-commands via curtin in-target
# Copies OEM folder and creates rc.local for first boot execution

set -e

if [ -d /cdrom/oem ]; then
    mkdir -p /opt
    cp -r /cdrom/oem /opt/oem
    chmod +x /opt/oem/*.sh 2>/dev/null || true
fi

# Create rc.local to run OEM install on first boot
cat > /etc/rc.local << 'EOF'
#!/bin/bash
if [ -f /opt/oem/run-oem-install.sh ] && [ ! -f /opt/oem/.completed ]; then
    /opt/oem/run-oem-install.sh &
fi
exit 0
EOF
chmod +x /etc/rc.local

echo "OEM installation setup completed!"
"""


def add_directory(iso: PyCdlib, path_in_iso: str, name: str) -> None:
    with suppress(PyCdlibException):
        iso.add_directory(iso_path=path_in_iso, rr_name=name)


def replace_data(
    iso: PyCdlib,
    path_in_iso: str, 
    new_data: bytes, 
    name: str
) -> None:
    """Replace a file in the ISO with new data."""
    kwargs = dict(iso_path=path_in_iso, rr_name=name)

    with suppress(PyCdlibException):
        iso.rm_file(**kwargs)

    iso.add_fp(BytesIO(new_data), len(new_data), **kwargs)


def add_directory_contents(iso: PyCdlib, dir: Path, base_path_in_iso: str, base_name: str) -> None:
    """Add directory contents to the ISO recursively."""
    if not dir.is_dir():
        return

    print(f"Adding folder to ISO: {dir}")
    add_directory(iso, path_in_iso=base_path_in_iso, name=base_name)

    for item in dir.iterdir():
        if item.is_file():
            file_data = item.read_bytes()
            # ISO9660 requires uppercase names with version suffix
            iso_name = item.name.upper().replace(".", "_").replace("-", "_")[:8]
            iso_path = f"{base_path_in_iso}/{iso_name};1"

            print(f"  Adding file: {item.name} -> {iso_path}")
            replace_data(iso, path_in_iso=iso_path, new_data=file_data, name=item.name)

        elif item.is_dir():
            # Recursively add subdirectory
            subdir_iso_name = item.name.upper().replace("-", "_")[:8]
            subdir_iso_path = f"{base_path_in_iso}/{subdir_iso_name}"

            print(f"  Adding directory: {item.name} -> {subdir_iso_path}")
            add_directory_contents(iso, item, base_path_in_iso=subdir_iso_path, base_name=item.name)


def remaster_iso(src_iso: Path, dst_iso: Path, config_dir: Path, oem_dir: Path | None = None):
    user_data_file = config_dir / "user-data"
    meta_data_file = config_dir / "meta-data"
    grub_cfg_file = config_dir / "grub.cfg"

    if not src_iso.is_file():
        raise FileNotFoundError(f"Source ISO not found: {src_iso}")
    
    if not dst_iso.parent.is_dir():
        try:
            dst_iso.parent.mkdir(parents=True)
        except Exception:
            raise NotADirectoryError(f"Destination ISO directory not found: {dst_iso.parent}")

    if not user_data_file.is_file():
        raise FileNotFoundError(f"user-data not found in {config_dir}")

    if not meta_data_file.is_file():
        raise FileNotFoundError(f"meta-data not found in {config_dir}")
    
    if not grub_cfg_file.is_file():
        raise FileNotFoundError(f"grub.cfg not found in {config_dir}")

    print(f"Opening source ISO: {src_iso}")
    iso = PyCdlib()
    iso.open(str(src_iso))

    grub_data = grub_cfg_file.read_bytes()
    replace_data(
        iso,
        path_in_iso="/BOOT/GRUB/GRUB.CFG;1",
        new_data=grub_data,
        name="grub.cfg"
    )

    # Add NoCloud seed at /cdrom/nocloud/{user-data,meta-data}
    print("Adding cloud-init configuration...")
    add_directory(iso, path_in_iso="/NOCLOUD", name="nocloud")

    # Add user-data
    user_data = user_data_file.read_bytes()
    replace_data(
        iso,
        path_in_iso="/NOCLOUD/USER_DATA;1",
        new_data=user_data,
        name="user-data"
    )

    # Add meta-data
    meta_data = meta_data_file.read_bytes()
    replace_data(
        iso,
        path_in_iso="/NOCLOUD/META_DATA;1",
        new_data=meta_data,
        name="meta-data"
    )

    # Add OEM folder if provided
    if oem_dir:
        print("Adding OEM folder and setup scripts...")
        # Add user's OEM directory contents
        add_directory_contents(iso, oem_dir, base_path_in_iso="/OEM", base_name="oem")

        # Add generated scripts
        replace_data(iso, "/OEM/RUN_OEM_;1", RUN_OEM_INSTALL_SH.encode(), "run-oem-install.sh")
        replace_data(iso, "/OEM/SETUP_OE;1", SETUP_OEM_INSTALL_SH.encode(), "setup-oem-install.sh")


    print(f"Writing remastered ISO to: {dst_iso}")
    iso.write(str(dst_iso))
    iso.close()

    print("ISO remastering completed successfully!")


def main():
    parser = argparse.ArgumentParser(
        description="Remaster Ubuntu ISO with autoinstall configuration using pycdlib"
    )
    parser.add_argument(
        "--src",
        required=True,
        help="Source Ubuntu ISO file path"
    )
    parser.add_argument(
        "--dst",
        required=True,
        help="Destination path for remastered ISO"
    )
    parser.add_argument(
        "--config-dir",
        required=True,
        help="Directory containing user-data, meta-data and grub.cfg files"
    )
    parser.add_argument(
        "--oem-dir",
        required=False,
        help="Optional OEM directory to include in the ISO"
    )

    args = parser.parse_args()
    remaster_iso(
        Path(args.src), 
        Path(args.dst), 
        Path(args.config_dir), 
        Path(args.oem_dir) if args.oem_dir else None,
    )


if __name__ == "__main__":
    main()
