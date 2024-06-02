<h1 align="center">OSX<br />
<div align="center">
<a href="https://github.com/dockur/osx/"><img src="https://github.com/dockur/osx/raw/master/.github/logo.png" title="Logo" style="max-width:100%;" width="128" /></a>
</div>
<div align="center">

[![Build]][build_url]
[![Version]][tag_url]
[![Size]][tag_url]
[![Pulls]][hub_url]

</div></h1>

OSX inside a Docker container.

## Features

 - KVM acceleration
 - Image downloader
 - Web-based viewer

## Usage

Via Docker Compose:

```yaml
services:
  osx:
    image: dockurr/osx
    container_name: osx
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
docker run -it --rm -p 8006:8006 --device=/dev/kvm --cap-add NET_ADMIN --stop-timeout 120 dockurr/osx
```

Via Kubernetes:

```shell
kubectl apply -f kubernetes.yml
```

## FAQ

* ### How do I use it?

  Very simple! These are the steps:
  
  - Start the container and connect to [port 8006](http://localhost:8006) using your web browser.

  - Select `macOs Base System` using your keyboard to begin the installation.

  - Select `Disk Utility` and then select the largest `Apple Inc. VirtIO Block Media` disk.

  - Click `Erase` to format the disk, and give it a recognizable name you like.

  - Close the window and proceed the installation by clicking `Reinstall macOS <version>`.
  
  - When prompted where to install it, select the disk you just created.

  - Once you see the desktop, your OSX installation is ready for use.
  
  Enjoy your brand new machine, and don't forget to star this repo!

* ### How do I select the OSX version?

  By default, Ventura will be installed. But you can add the `VERSION` environment variable to your compose file, in order to specify an alternative OSX version to be downloaded:

  ```yaml
  environment:
    VERSION: "ventura"
  ```

  Select from the values below:
  
  |   **Value**   | **Version**        | **Size** |
  |----|-----|----|
  | `sonoma`      | Sonoma             | ? GB     |
  | `ventura`     | Ventura            | 3.0 GB   |
  | `monterey`    | Monterey           | ? GB     |
  | `big-sur`     | Big Sur            | ? GB     |
  | `catalina`    | Catalina           | ? GB     |
  | `mojave`      | Mojave             | ? GB     |
  | `high-sierra` | High Sierra        | ? GB     |

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

* ### How do I verify if my system supports KVM?

  To verify if your system supports KVM, run the following commands:

  ```bash
  sudo apt install cpu-checker
  sudo kvm-ok
  ```

  If you receive an error from `kvm-ok` indicating that KVM acceleration can't be used, check the virtualization settings in the BIOS.

* ### How do I change the amount of CPU or RAM?

  By default, the container will be allowed to use a maximum of 2 CPU cores and 4 GB of RAM.

  If you want to adjust this, you can specify the desired amount using the following environment variables:

  ```yaml
  environment:
    RAM_SIZE: "8G"
    CPU_CORES: "4"
  ```
 
* ### Is this project legal?

  Yes, this project contains only open-source code and does not distribute any copyrighted material. So under all applicable laws, this project will be considered legal.

 ## Acknowledgements

Special thanks to [OSX-KVM](https://github.com/kholia/OSX-KVM) and [qemu-docker](https://github.com/qemus/qemu-docker/). This would not exist without their invaluable work.

## Stars
[![Stars](https://starchart.cc/dockur/osx.svg?variant=adaptive)](https://starchart.cc/dockur/osx)

## Disclaimer

The product names, logos, brands, and other trademarks referred to within this project are the property of their respective trademark holders. This project is not affiliated, sponsored, or endorsed by Apple Inc.

[build_url]: https://github.com/dockur/osx/
[hub_url]: https://hub.docker.com/r/dockurr/osx/
[tag_url]: https://hub.docker.com/r/dockurr/osx/tags

[Build]: https://github.com/dockur/osx/actions/workflows/build.yml/badge.svg
[Size]: https://img.shields.io/docker/image-size/dockurr/osx/latest?color=066da5&label=size
[Pulls]: https://img.shields.io/docker/pulls/dockurr/osx.svg?style=flat&label=pulls&logo=docker
[Version]: https://img.shields.io/docker/v/dockurr/osx/latest?arch=amd64&sort=semver&color=066da5
