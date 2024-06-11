<h1 align="center">OSX<br />
<div align="center">
<a href="https://github.com/dockur/macos/"><img src="https://github.com/dockur/macos/raw/master/.github/logo.png" title="Logo" style="max-width:100%;" width="128" /></a>
</div>
<div align="center">

[![Build]][build_url]
[![Version]][tag_url]
[![Size]][tag_url]
[![Pulls]][hub_url]

</div></h1>

OSX (macOS) inside a Docker container.

## Features

 - KVM acceleration
 - Web-based viewer
 - Automatic download

## Usage

Via Docker Compose:

```yaml
services:
  macos:
    image: dockurr/macos
    container_name: macos
    environment:
      VERSION: "ventura"
    devices:
      - /dev/kvm
    cap_add:
      - NET_ADMIN
    ports:
      - 8006:8006
      - 5900:5900/tcp
      - 5900:5900/udp
    stop_grace_period: 2m
```

Via Docker CLI:

```bash
docker run -it --rm -p 8006:8006 --device=/dev/kvm --cap-add NET_ADMIN --stop-timeout 120 dockurr/macos
```

Via Kubernetes:

```shell
kubectl apply -f kubernetes.yml
```

## FAQ

* ### How do I use it?

  Very simple! These are the steps:
  
  - Start the container and connect to [port 8006](http://localhost:8006) using your web browser.

  - Choose `Disk Utility` and then select the largest `Apple Inc. VirtIO Block Media` disk.

  - Click the `Erase` button to format the disk, and give it any recognizable name you like.

  - Close the current window and proceed the installation by clicking `Reinstall macOS`.
  
  - When prompted where you want to install it, select the disk you just created previously.
 
  - After all files are copied, select your region, language, and account settings.
  
  Enjoy your brand new machine, and don't forget to star this repo!

* ### How do I select the macOS version?

  By default, macOS Ventura will be installed. But you can add the `VERSION` environment variable to your compose file, in order to specify an alternative macOS version to be downloaded:

  ```yaml
  environment:
    VERSION: "ventura"
  ```

  Select from the values below:
  
  |   **Value** | **Version**    |
  |----|-----|
  | `sonoma`    | macOS Sonoma   |
  | `ventura`   | macOS Ventura  |
  | `monterey`  | macOS Monterey |
  | `big-sur`   | macOS Big Sur  |

* ### How do I change the storage location?

  To change the storage location, include the following bind mount in your compose file:

  ```yaml
  volumes:
    - /var/osx:/storage
  ```

  Replace the example path `/var/osx` with the desired storage folder.

* ### How do I change the size of the disk?

  To expand the default size of 64 GB, add the `DISK_SIZE` setting to your compose file and set it to your preferred capacity:

  ```yaml
  environment:
    DISK_SIZE: "256G"
  ```
  
  This can also be used to resize the existing disk to a larger capacity without any data loss.

* ### How do I change the amount of CPU or RAM?

  By default, the container will be allowed to use a maximum of 2 CPU cores and 4 GB of RAM.

  If you want to adjust this, you can specify the desired amount using the following environment variables:

  ```yaml
  environment:
    RAM_SIZE: "8G"
    CPU_CORES: "4"
  ```

  Please be aware that macOS may have issues when the configured CPU core count is not a power of two (2, 4, 8, 16, etc).

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

* ### How do I verify if my system supports KVM?

  To verify that your system supports KVM, run the following commands:

  ```bash
  sudo apt install cpu-checker
  sudo kvm-ok
  ```

  If you receive an error from `kvm-ok` indicating that KVM acceleration can't be used, check whether the virtualization extensions (`Intel VT-x` or `AMD SVM`) are enabled in your BIOS. If you are running the container inside a VM instead of directly on the host, you will also need to enable nested virtualization in its settings. If you are using a cloud provider, you may be out of luck as most of them do not allow nested virtualization for their VPS's. If you are using Windows 10 or MacOS, you are also out of luck, as only Linux and Windows 11 support KVM.

  If you don't receive any error from `kvm-ok` at all, but the container still complains that `/dev/kvm` is missing, it might help to add `privileged: true` to your compose file (or `--privileged` to your `run` command), to rule out any permission issue.

* ### How do I run Windows in a container?

  You can use [dockur/windows](https://github.com/dockur/windows) for that. It shares many of the same features, and even has completely automatic installation.

* ### Is this project legal?

  Yes, this project contains only open-source code and does not distribute any copyrighted material. Neither does it try to circumvent any copyright protection measures. So under all applicable laws, this project will be considered legal.

  However, by installing Apple's macOS, you must accept their end-user license agreement, which does not permit installation on non-official hardware. So only run this container on hardware sold by Apple, as any other use will be a violation of their terms and conditions.

 ## Acknowledgements

Special thanks to [seitenca](https://github.com/seitenca), [OpenCore](https://github.com/acidanthera/OpenCorePkg), [OSX-KVM](https://github.com/kholia/OSX-KVM) and [KVM-Opencore](https://github.com/thenickdude/KVM-Opencore), this project would not exist without their invaluable work.

## Stars
[![Stars](https://starchart.cc/dockur/macos.svg?variant=adaptive)](https://starchart.cc/dockur/macos)

## Disclaimer

Only run this container on Apple hardware, any other use is not permitted by their EULA. The product names, logos, brands, and other trademarks referred to within this project are the property of their respective trademark holders. This project is not affiliated, sponsored, or endorsed by Apple Inc.

[build_url]: https://github.com/dockur/macos/
[hub_url]: https://hub.docker.com/r/dockurr/macos/
[tag_url]: https://hub.docker.com/r/dockurr/macos/tags

[Build]: https://github.com/dockur/macos/actions/workflows/build.yml/badge.svg
[Size]: https://img.shields.io/docker/image-size/dockurr/macos/latest?color=066da5&label=size
[Pulls]: https://img.shields.io/docker/pulls/dockurr/macos.svg?style=flat&label=pulls&logo=docker
[Version]: https://img.shields.io/docker/v/dockurr/macos/latest?arch=amd64&sort=semver&color=066da5
