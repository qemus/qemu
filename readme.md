<h1 align="center">Local Ubuntu on Docker<br />
<div align="center">

</div></h1>

Local Ubuntu Desktop inside a Docker container.

## Usage 🐳

### Via Docker Compose:

> See [compose.yml](compose.yml) for the complete configuration.

To prepare a golden image from a custom ISO:
```bash
STORAGE_DIR=/path/to/storage ISO_FILE=/path/to/ubuntu.iso \
  docker compose -f compose.prepare.yml up
```

Start the container (using the golden image):
```bash
STORAGE_DIR=/path/to/storage docker compose up
```

### Via Docker CLI:

```bash
docker run -it --rm \
  -p 8006:8006 \
  --device=/dev/kvm \
  --cap-add NET_ADMIN \
  --mount type=bind,source=./ubuntu.iso,target=/custom.iso \
  --stop-timeout 120 \
  qemu-local:latest
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

  **Download Ubuntu LTS Server ISO:**

  1. Visit [Ubuntu Server Downloads](https://ubuntu.com/download/server)
  2. Download Server ISO file [~3GB]

  **Then follow these steps:**

  - Start the container and connect to [port 8006](http://localhost:8006) using your web browser.

  - Sit back and relax while the magic happens, the whole installation will be performed fully automatic with cloud-init autoinstall.

  - Once you see the desktop, your Ubuntu installation is ready for use.

  Enjoy your brand new machine, and don't forget to star this repo!

### How do I change the storage location?

  To change the storage location, modify the `STORAGE_DIR` environment variable:

  ```bash
  STORAGE_DIR=./ubuntu docker compose up
  ```

### How do I change the size of the disk?

  To expand the default size of 64 GB, add the `DISK_SIZE` setting to your compose file and set it to your preferred capacity:

  ```yaml
  environment:
    DISK_SIZE: "256G"
  ```

> [!TIP]
> This can also be used to resize the existing disk to a larger capacity without any data loss.

### How do I share files with the host?

  To share files with the host, add the following volume to your compose file:

  ```yaml
  volumes:
    -  /home/user/example:/shared
  ```

  Then start the container and execute the following command in Ubuntu:

  ```shell
  sudo mount -t 9p -o trans=virtio shared /mnt/example
  ```

  Now the `/home/user/example` directory on the host will be available as `/mnt/example` in Ubuntu.

> [!TIP]
> You can add this mount command to `/etc/fstab` for automatic mounting on boot.

### How do I change the amount of CPU or RAM?

  By default, the container will be allowed to use a maximum of 2 CPU cores and 4 GB of RAM.

  If you want to adjust this, you can specify the desired amount using the following environment variables:

  ```yaml
  environment:
    RAM_SIZE: "8G"
    CPU_CORES: "4"
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

  If you didn't receive any error from `kvm-ok` at all, but the container still complains that `/dev/kvm` is missing, it might help to add `privileged: true` to your compose file (or `--privileged` to your `run` command), to rule out any permission issue.
