<h1 align="center">QEMU<br />
<div align="center"><a href="https://github.com/qemus/qemu"><img src="https://github.com/qemus/qemu/raw/master/.github/logo.png" title="Logo" style="max-width:100%;" width="128" /></a>
</div>
<div align="center">

[![Build]][build_url]
[![Version]][tag_url]
[![Size]][tag_url]
[![Package]][pkg_url]
[![Pulls]][hub_url]

</div></h1>

Docker container for running virtual machines using QEMU.

## Features ✨

  - Web-based viewer to control the machine directly from your browser

  - Supports `.iso`, `.img`, `.qcow2`, `.vhd`, `.vhdx`, `.vdi`, `.vmdk` and `.raw` disk formats

  - High-performance options (like KVM acceleration, kernel-mode networking, IO threading, etc.) to achieve near-native speed

## Usage  🐳

Via Docker Compose:

```yaml
services:
  qemu:
    container_name: qemu
    image: qemux/qemu-docker
    environment:
      BOOT: "https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-virt-3.19.1-x86_64.iso"
    devices:
      - /dev/kvm
      - /dev/net/tun
    cap_add:
      - NET_ADMIN
    ports:
      - 8006:8006
    restart: always
    stop_grace_period: 2m
```

Via Docker CLI:

```bash
docker run -it --rm -e "BOOT=http://example.com/image.iso" -p 8006:8006 --device=/dev/kvm --device=/dev/net/tun --cap-add NET_ADMIN qemux/qemu-docker
```

Via Kubernetes:

```shell
kubectl apply -f https://raw.githubusercontent.com/qemus/qemu/refs/heads/master/kubernetes.yml
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

  Very simple! These are the steps:

  - Set the `BOOT` environment variable to the URL of any [disk image](#what-image-formats-are-supported) you want to install.

  - Start the container and connect to [port 8006](http://localhost:8006) using your web browser.

  - You will see the screen and can now install the OS of your choice using your keyboard and mouse.

  Enjoy your brand new machine, and don't forget to star this repo!

### How do I change the storage location?

  To change the storage location, include the following bind mount in your compose file:

  ```yaml
  volumes:
    - /var/qemu:/storage
  ```

  Replace the example path `/var/qemu` with the desired storage folder.

### How do I change the size of the disk?

  To expand the default size of 16 GB, add the `DISK_SIZE` setting to your compose file and set it to your preferred capacity:

  ```yaml
  environment:
    DISK_SIZE: "128G"
  ```
  
> [!TIP]
> This can also be used to resize the existing disk to a larger capacity without any data loss.

### How do I boot a local image?

  You can use a local image file directly, and skip the download altogether, by binding it in your compose file:
  
  ```yaml
  volumes:
    - /home/user/example.iso:/boot.iso
  ```

  This way you can supply a `boot.iso`, `boot.img` or `boot.qcow2` file.
  
> [!NOTE]
> The URL of the `BOOT` variable will be ignored in this case.

### How do I boot ARM images?

  You can use [qemu-arm](https://github.com/qemus/qemu-arm/) to run ARM64-based images.

### How do I boot Windows?

  Use [dockur/windows](https://github.com/dockur/windows) instead, as it includes all the drivers required during installation, amongst many other features.

### How do I boot macOS?

  Use [dockur/macos](https://github.com/dockur/macos) instead, as it uses all the right settings and automaticly downloads the installation files.

### How do I boot without VirtIO drivers?

  By default, the machine makes use of `virtio-scsi` drives for performance reasons, and even though most Linux kernels bundle the necessary driver for this device, that may not always be the case for other operating systems.

  If your machine fails to detect the hard drive, you can modify your compose file to use `virtio-blk` instead:

  ```yaml
  environment:
    DISK_TYPE: "blk"
  ```

> [!TIP]
> If it still fails to boot, you can set the value to `ide` to emulate a IDE drive, which is slow but requires no drivers and is compatible with almost every system.

### How do I change the amount of CPU or RAM?

  By default, the container will be allowed to use a maximum of 1 CPU core and 1 GB of RAM.

  If you want to adjust this, you can specify the desired amount using the following environment variables:

  ```yaml
  environment:
    RAM_SIZE: "4G"
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

  If you do not receive any error from `kvm-ok` but the container still complains about KVM, please check whether:

  - you are not using "Docker Desktop for Linux" as it does not support KVM, instead make use of Docker Engine directly.
 
  - it could help to add `privileged: true` to your compose file (or `sudo` to your `docker run` command), to rule out any permission issue.

### How do I assign an individual IP address to the container?

  By default, the container uses bridge networking, which shares the IP address with the host. 

  If you want to assign an individual IP address to the container, you can create a macvlan network as follows:

  ```bash
  docker network create -d macvlan \
      --subnet=192.168.0.0/24 \
      --gateway=192.168.0.1 \
      --ip-range=192.168.0.100/28 \
      -o parent=eth0 vlan
  ```
  
  Be sure to modify these values to match your local subnet. 

  Once you have created the network, change your compose file to look as follows:

  ```yaml
  services:
    qemu:
      container_name: qemu
      ..<snip>..
      networks:
        vlan:
          ipv4_address: 192.168.0.100

  networks:
    vlan:
      external: true
  ```
 
  An added benefit of this approach is that you won't have to perform any port mapping anymore, since all ports will be exposed by default.

> [!IMPORTANT]
> This IP address won't be accessible from the Docker host due to the design of macvlan, which doesn't permit communication between the two. If this is a concern, you need to create a [second macvlan](https://blog.oddbit.com/post/2018-03-12-using-docker-macvlan-networks/#host-access) as a workaround.

### How can the VM acquire an IP address from my router?

  After configuring the container for [macvlan](#how-do-i-assign-an-individual-ip-address-to-the-container), it is possible for the VM to become part of your home network by requesting an IP from your router, just like a real PC.

  To enable this mode, add the following lines to your compose file:

  ```yaml
  environment:
    DHCP: "Y"
  devices:
    - /dev/vhost-net
  device_cgroup_rules:
    - 'c *:* rwm'
  ```

> [!NOTE]
> In this mode, the container and the VM will each have their own separate IPs.

### How do I add multiple disks?

  To create additional disks, modify your compose file like this:
  
  ```yaml
  environment:
    DISK2_SIZE: "32G"
    DISK3_SIZE: "64G"
  volumes:
    - /home/example:/storage2
    - /mnt/data/example:/storage3
  ```

### How do I pass-through a disk?

  It is possible to pass-through disk devices directly by adding them to your compose file in this way:

  ```yaml
  devices:
    - /dev/sdb:/disk1
    - /dev/sdc:/disk2
  ```

  Use `/disk1` if you want it to become your main drive, and use `/disk2` and higher to add them as secondary drives.

### How do I pass-through a USB device?

  To pass-through a USB device, first lookup its vendor and product id via the `lsusb` command, then add them to your compose file like this:

  ```yaml
  environment:
    ARGUMENTS: "-device usb-host,vendorid=0x1234,productid=0x1234"
  devices:
    - /dev/bus/usb
  ```

### How can I provide custom arguments to QEMU?

  You can create the `ARGUMENTS` environment variable to provide additional arguments to QEMU at runtime:

  ```yaml
  environment:
    ARGUMENTS: "-device usb-tablet"
  ```

### What image formats are supported?

  The `BOOT` URL accepts files in any of the following formats:
  
  | **Extension** | **Format**   |
  |---|---|
  | `.img`       | Raw           |
  | `.raw`       | Raw           |
  | `.iso`        | Optical       |
  | `.qcow2` | QEMU         |
  | `.vmdk`   | VMware      |
  | `.vhd`       | VirtualPC   |
  | `.vhdx`     | Hyper-V     |
  | `.vdi`        | VirtualBox |

> [!TIP]
> It will also accept `.img.gz`, `.qcow2.xz`, `.iso.zip` and many more, as it automaticly extracts compressed files.

## Stars 🌟
[![Stars](https://starchart.cc/qemus/qemu.svg?variant=adaptive)](https://starchart.cc/qemus/qemu)

[build_url]: https://github.com/qemus/qemu/
[hub_url]: https://hub.docker.com/r/qemux/qemu-docker/
[tag_url]: https://hub.docker.com/r/qemux/qemu-docker/tags
[pkg_url]: https://github.com/qemus/qemu/pkgs/container/qemu-docker

[Build]: https://github.com/qemus/qemu/actions/workflows/build.yml/badge.svg
[Size]: https://img.shields.io/docker/image-size/qemux/qemu-docker/latest?color=066da5&label=size
[Pulls]: https://img.shields.io/docker/pulls/qemux/qemu-docker.svg?style=flat&label=pulls&logo=docker
[Version]: https://img.shields.io/docker/v/qemux/qemu-docker/latest?arch=amd64&sort=semver&color=066da5
[Package]: https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fipitio.github.io%2Fbackage%2Fqemus%2Fqemu%2Fqemu-docker.json&query=%24.downloads&logo=github&style=flat&color=066da5&label=pulls
