<h1 align="center">OSX<br />
<div align="center">
<a href="https://github.com/seitenca/osx/"><img src="https://github.com/seitenca/osx/raw/master/.github/logo.png" title="Logo" style="max-width:100%;" width="128" /></a>
</div>
<div align="center">

</div></h1>

OSX inside a Docker container.

## Features

 - Auto image downloader
 - KVM acceleration
 - Web-based viewer

## Usage

Via Docker Compose:

```yaml
services:
  osx:
    build:
      dockerfile: Dockerfile
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
docker run -it --rm -p 8006:8006 --device=/dev/kvm --cap-add NET_ADMIN --stop-timeout 120 todo/osx
```

Via Kubernetes:

```shell
kubectl apply -f kubernetes.yml
```

## FAQ

* ### How do I use it?

  Very simple! These are the steps:
  
  - Start the container and connect to [port 8006](http://localhost:8006) using your web browser.

  - **With the keyboard!!** select "macOs Base System" to begin the installation

  - Select Disk Utility and then select the "QEMU HARDDISK Media" that has the size you specified

  - Click erase to format the disk, you can put the name you want.

  - When finished go back by closing the window and the proced the installation clicking "Reinstall macOS *version*"
  
  - When prompted where to install it select the disk you created 

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
  | `high-sierra` | High Sierra        | ? GB     |
  | `mojave`      | Mojave             | ? GB     |
  | `catalina`    | Catalina           | ? GB     |
  | `big-sur`     | Big Sur            | ? GB     |
  | `monterey`    | Monterey           | ? GB     |
  | `ventura`     | Ventura            | 3 GB     |
  | `sonoma`      | Sonoma             | ? GB     |


 ## Acknowledgements

Special thanks to [OSX-KVM](https://github.com/kholia/OSX-KVM) and [qemu-docker](https://github.com/qemus/qemu-docker/). This would not exist without their invaluable work.

## Disclaimer

The product names, logos, brands, and other trademarks referred to within this project are the property of their respective trademark holders. This project is not affiliated, sponsored, or endorsed by Apple Inc.