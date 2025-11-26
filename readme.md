<h1 align="center">Local Ubuntu on Docker<br />
<div align="center">

</div></h1>

Local Ubuntu Desktop inside a Docker container with automated cloud-init installation.

## Usage 🐳

### Building the Image

```bash
docker build -t qemu-local:latest .
```

### Preparing Golden Image (First Time)

Mount your Ubuntu ISO and let it install automatically:

```bash
docker run -it --rm \
  --name prepare-ubuntu \
  --device=/dev/kvm \
  --cap-add NET_ADMIN \
  --mount type=bind,source=/path/to/ubuntu.iso,target=/custom.iso \
  -v /path/to/storage:/storage \
  -p 8006:8006 \
  -e RAM_SIZE=6G \
  -e CPU_CORES=4 \
  -e DISK_SIZE=64G \
  qemu-local:latest
```

The container will automatically:
- Remaster the ISO with cloud-init autoinstall configuration
- Install Ubuntu with desktop environment
- Create a golden image in `/storage`
- Exit when preparation is complete

### Running from Golden Image

After preparation, start Ubuntu from the saved golden image:

```bash
docker run -it --rm \
  --name ubuntu \
  --device=/dev/kvm \
  --cap-add NET_ADMIN \
  -v /path/to/storage:/storage \
  -p 8006:8006 \
  -p 5000:5000 \
  -e RAM_SIZE=8G \
  -e CPU_CORES=4 \
  qemu-local:latest
```

Access the desktop via browser at http://localhost:8006

### Custom Installation with OEM Scripts

You can provide custom installation scripts that run on first boot:

```bash
docker run -it --rm \
  --name prepare-ubuntu \
  --device=/dev/kvm \
  --cap-add NET_ADMIN \
  --mount type=bind,source=/path/to/ubuntu.iso,target=/custom.iso \
  --mount type=bind,source=/path/to/oem,target=/oem \
  -v /path/to/storage:/storage \
  -p 8006:8006 \
  qemu-local:latest
```

Create an `/oem/install.sh` script that will execute on first boot:

```bash
#!/bin/bash
# Example OEM installation script

# Install additional packages
apt-get update
apt-get install -y vim htop

# Configure system
echo "Custom setup complete!"
```

## Compatibility ⚙️

| **Product**  | **Platform**   | |
|---|---|---|
| Docker Engine | Linux| ✅ |
| Docker Desktop | Linux | ❌ |
| Docker Desktop | macOS | ❌ |
| Docker Desktop | Windows 11 | ✅ |
| Docker Desktop | Windows 10 | ❌ |

## FAQ 💬

### How do I use it?

  **Download Ubuntu 22.04 LTS Server ISO:**

  1. Visit & download the [server ISO](https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso)

  **Then follow these steps:**

  - Start the container with preparation command (see above)

  - Connect to [port 8006](http://localhost:8006) using your web browser

  - Watch the automated installation with cloud-init autoinstall

  - Once you see the desktop, your Ubuntu installation is ready

  Enjoy your brand new machine, and don't forget to star this repo!

### How do I change the storage location?

  To change the storage location, modify the volume mount:

  ```bash
  -v /custom/storage/path:/storage
  ```

### How do I change the size of the disk?

  To expand the default size of 64 GB, set the `DISK_SIZE` environment variable:

  ```bash
  -e DISK_SIZE="256G"
  ```

> [!TIP]
> This can also be used to resize the existing disk to a larger capacity without any data loss.

### How do I share files with the host?

  To share files with the host, add a volume mount:

  ```bash
  --mount type=bind,source=/home/user/example,target=/shared
  ```

  Then execute the following command in Ubuntu:

  ```bash
  sudo mount -t 9p -o trans=virtio shared /mnt/example
  ```

  Now the `/home/user/example` directory on the host will be available as `/mnt/example` in Ubuntu.

> [!TIP]
> You can add this mount command to `/etc/fstab` for automatic mounting on boot.

### How do I change the amount of CPU or RAM?

  By default, the container will be allowed to use a maximum of 8 CPU cores and 8 GB of RAM.

  If you want to adjust this, specify the desired amount:

  ```bash
  -e RAM_SIZE="16G" \
  -e CPU_CORES="8"
  ```

### How do I verify if my system supports KVM?

  Only Linux and Windows 11 support KVM virtualization, macOS and Windows 10 do not unfortunately.

  You can run the following commands in Linux to check your system:

  ```bash
  sudo apt install cpu-checker
  sudo kvm-ok
  ```

  If you receive an error from `kvm-ok` indicating that KVM cannot be used, please check whether:

  - the virtualization extensions (`Intel VT-x` or `AMD SVM`) are enabled in your BIOS.

  - you enabled "nested virtualization" if you are running the container inside a virtual machine.

  - you are not using a cloud provider, as most of them do not allow nested virtualization for their VPS's.

  If you didn't receive any error from `kvm-ok` at all, but the container still complains that `/dev/kvm` is missing, try adding `--privileged` to your `run` command to rule out any permission issue.
