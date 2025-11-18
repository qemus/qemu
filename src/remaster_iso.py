#!/usr/bin/env python3
import argparse
import io
from pathlib import Path

import pycdlib
from pycdlib.pycdlibexception import PyCdlibException


def remaster_iso(src_iso: Path, dst_iso: Path, config_dir: Path):
    user_data_file = config_dir / "user-data"
    meta_data_file = config_dir / "meta-data"

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

    print(f"Opening source ISO: {src_iso}")
    iso = pycdlib.PyCdlib()
    iso.open(str(src_iso))

    # Read existing GRUB config (ISO9660 path, uppercase + ;1)
    buf = io.BytesIO()
    iso.get_file_from_iso_fp(buf, iso_path="/BOOT/GRUB/GRUB.CFG;1")
    data = buf.getvalue()

    # Patch kernel cmdline
    needle = b" quiet ---"
    replacement = b" quiet autoinstall ds=nocloud\\;s=/cdrom/nocloud/ ---"

    if needle not in data:
        needle = b" ---"
    new = data.replace(needle, replacement)

    # Replace GRUB.CFG in ISO
    iso.rm_file(iso_path="/BOOT/GRUB/GRUB.CFG;1", rr_name="grub.cfg")
    iso.add_fp(io.BytesIO(new), len(new), iso_path="/BOOT/GRUB/GRUB.CFG;1", rr_name="grub.cfg")

    # Add NoCloud seed at /cdrom/nocloud/{user-data,meta-data}
    print("Adding cloud-init configuration...")
    try:
        iso.add_directory(iso_path="/NOCLOUD", rr_name="nocloud")
    except PyCdlibException:
        # Directory may already exist; ignore
        pass

    user_data = user_data_file.read_bytes()
    meta_data = meta_data_file.read_bytes()

    # Add user-data
    try:
        iso.rm_file(iso_path="/NOCLOUD/USER_DATA;1", rr_name="user-data")
    except PyCdlibException:
        pass
    iso.add_fp(
        io.BytesIO(user_data),
        len(user_data),
        iso_path="/NOCLOUD/USER_DATA;1",
        rr_name="user-data"
    )

    # Add meta-data
    try:
        iso.rm_file(iso_path="/NOCLOUD/META_DATA;1", rr_name="meta-data")
    except PyCdlibException:
        pass
    iso.add_fp(
        io.BytesIO(meta_data),
        len(meta_data),
        iso_path="/NOCLOUD/META_DATA;1",
        rr_name="meta-data"
    )

    # Write remastered ISO
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
        help="Directory containing user-data and meta-data"
    )

    args = parser.parse_args()
    remaster_iso(Path(args.src), Path(args.dst), Path(args.config_dir))


if __name__ == "__main__":
    main()
