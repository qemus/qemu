<h1 align="center">QEMU<br />
<div align="center"><a href="https://github.com/qemus/qemu-docker"><img src="https://github.com/qemus/qemu-docker/raw/master/.github/logo.png" title="Logo" style="max-width:100%;" width="128" /></a>
</div>
<div align="center">

[![Build]][build_url]
[![Version]][tag_url]
[![Size]][tag_url]
[![Pulls]][hub_url]

</div></h1>

QEMU in a docker container for running x86 and x64 virtual machines.

It uses high-performance QEMU options (like KVM acceleration, kernel-mode networking, IO threading, etc.) to achieve near-native speed.

## Features

 - Multi-platform
 - KVM acceleration
 - Web-based viewer

## Usage

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
    cap_add:
      - NET_ADMIN
    ports:
      - 8006:8006
    stop_grace_period: 2m
```

Via Docker CLI:

```bash
docker run -it --rm -e "BOOT=http://example.com/image.iso" -p 8006:8006 --device=/dev/kvm --cap-add NET_ADMIN qemux/qemu-docker
```

Via Kubernetes:

```shell
kubectl apply -f kubernetes.yml
```

## FAQ

* ### How do I use it?

  Very simple! These are the steps:

  - Set the `BOOT` environment variable to the URL of an ISO image you want to install.

  - Start the container and connect to [port 8006](http://localhost:8006) using your web browser.

  - You will see the screen and can now install the OS of your choice using your keyboard and mouse.

  Enjoy your brand new machine, and don't forget to star this repo!

* ### How do I change the storage location?

  To change the storage location, include the following bind mount in your compose file:

  ```yaml
  volumes:
    - /var/qemu:/storage
  ```

  Replace the example path `/var/qemu` with the desired storage folder.

* ### How do I change the size of the disk?

  To expand the default size of 16 GB, add the `DISK_SIZE` setting to your compose file and set it to your preferred capacity:

  ```yaml
  environment:
    DISK_SIZE: "128G"
  ```
  
  This can also be used to resize the existing disk to a larger capacity without any data loss.

* ### How do I boot a local ISO?

  You can use a local file directly, and skip the download altogether, by binding it in your compose file in this way:
  
  ```yaml
  volumes:
    - /home/user/example.iso:/boot.iso
  ```

  Replace the example path `/home/user/example.iso` with the filename of the desired ISO file, the value of `BOOT` will be ignored in this case.

* ### How do I boot ARM images?

  You can use [qemu-arm](https://github.com/qemus/qemu-arm/) to run ARM64-based images.

* ### How do I boot Windows?

  Use [dockur/windows](https://github.com/dockur/windows) instead, as it includes all the drivers required during installation, amongst many other features.

* ### How do I boot without VirtIO drivers?

  By default, the machine makes use of `virtio-scsi` drives for performance reasons, and even though most Linux kernels bundle the necessary driver for this device, that may not always be the case for some other operating systems.

  If your machine fails to detect the hard drive, you can modify your compose file to use `virtio-blk` instead:

  ```yaml
  environment:
    DISK_TYPE: "blk"
  ```

   If it still fails to boot, you can set the value to `ide` to emulate a IDE drive, which is slow but compatible with almost every system.

* ### How do I verify if my system supports KVM?

  To verify if your system supports KVM, run the following commands:

  ```bash
  sudo apt install cpu-checker
  sudo kvm-ok
  ```

  If you receive an error from `kvm-ok` indicating that KVM acceleration can't be used, check the virtualization settings in the BIOS.

* ### How do I increase the amount of CPU or RAM?

  By default, a single CPU core and 1 GB of RAM are allocated to the container.

  If there arises a need to increase this, add the following environment variables:

  ```yaml
  environment:
    RAM_SIZE: "4G"
    CPU_CORES: "4"
  ```

* ### How do I assign an individual IP address to the container?

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

  Please note that this IP address won't be accessible from the Docker host due to the design of macvlan, which doesn't permit communication between the two. If this is a concern, you need to create a [second macvlan](https://blog.oddbit.com/post/2018-03-12-using-docker-macvlan-networks/#host-access) as a workaround.

* ### How can the VM acquire an IP address from my router?

  After configuring the container for macvlan (see above), it is possible for the VM to become part of your home network by requesting an IP from your router, just like a real PC.

  To enable this mode, add the following lines to your compose file:

  ```yaml
  environment:
    DHCP: "Y"
  devices:
    - /dev/vhost-net
  device_cgroup_rules:
    - 'c *:* rwm'
  ```

  Please note that in this mode, the container and the VM will each have their own separate IPs. The container will keep the macvlan IP, and the VM will use the DHCP IP.

* ### How do I add multiple disks?

  To create additional disks, modify your compose file like this:
  
  ```yaml
  environment:
    DISK2_SIZE: "32G"
    DISK3_SIZE: "64G"
  volumes:
    - /home/example:/storage2
    - /mnt/data/example:/storage3
  ```

* ### How do I pass-through a disk?

  It is possible to pass-through disk devices directly by adding them to your compose file in this way:

  ```yaml
  devices:
    - /dev/sdb:/disk1
    - /dev/sdc:/disk2
  ```

  Use `/disk1` if you want it to become your main drive, and use `/disk2` and higher to add them as secondary drives.

* ### How do I pass-through a USB device?

  To pass-through a USB device, first lookup its vendor and product id via the `lsusb` command, then add them to your compose file like this:

  ```yaml
  environment:
    ARGUMENTS: "-device usb-host,vendorid=0x1234,productid=0x1234"
  devices:
    - /dev/bus/usb
  ```

* ### How can I provide custom arguments to QEMU?

  You can create the `ARGUMENTS` environment variable to provide additional arguments to QEMU at runtime:

  ```yaml
  environment:
    ARGUMENTS: "-device usb-tablet"
  ```

## Stars
[![Stars](https://starchart.cc/qemus/qemu-docker.svg?variant=adaptive)](https://starchart.cc/qemus/qemu-docker)

[build_url]: https://github.com/qemus/qemu-docker/
[hub_url]: https://hub.docker.com/r/qemux/qemu-docker/
[tag_url]: https://hub.docker.com/r/qemux/qemu-docker/tags

[Build]: https://github.com/qemus/qemu-docker/actions/workflows/build.yml/badge.svg
[Size]: https://img.shields.io/docker/image-size/qemux/qemu-docker/latest?color=066da5&label=size
[Pulls]: https://img.shields.io/docker/pulls/qemux/qemu-docker.svg?style=flat&label=pulls&logo=docker
[Version]: https://img.shields.io/docker/v/qemux/qemu-docker/latest?arch=amd64&sort=semver&color=066da5
