# Environment Variables

This page lists all the environment variables that can be used to configure the container.

An empty default means the variable is unset and its value is determined automatically when applicable.

## 🍎 macOS

| Variable | Default | Description |
|---|---|---|
| `VERSION` | `14` | macOS version to install, such as `14` or `sonoma`. |
| `MODEL` | `iMacPro1,1` | Mac model identifier used by OpenCore. |
| `SN` |  | Mac serial number. Generated automatically when unset. |
| `MLB` |  | Mac board serial number. Generated automatically when unset. |
| `UUID` |  | Mac system UUID. Generated automatically when unset. |

## 🧠 CPU and Memory

| Variable | Default | Description |
|---|---|---|
| `CPU_CORES` | `1` | Number of virtual CPU cores, such as `4`, `half`, or `max`. |
| `CPU_MODEL` |  | QEMU CPU model. Selected automatically for Intel or AMD hosts when unset. |
| `CPU_FLAGS` |  | Additional QEMU CPU flags. |
| `KVM` | `Y` | Enables KVM hardware acceleration. |
| `RAM_SIZE` | `4G` | Amount of RAM assigned to macOS, such as `8G`, `half`, or `max`. |
| `RAM_CHECK` | `Y` | Checks whether enough host memory is available before starting macOS. |

## 💾 Storage

| Variable | Default | Description |
|---|---|---|
| `DISK_SIZE` | `64G` | Size of the primary disk. |
| `DISK_FMT` | `raw` | Disk image format: `raw` or `qcow2`. |
| `DISK_TYPE` | `blk` | Disk device type, such as `sata`, `scsi`, `nvme`, or `blk`. |
| `DISK_CACHE` | `none` | Disk cache mode, such as `none` or `writeback`. |
| `DISK_IO` | `native` | Disk I/O mode, such as `native`, `threads`, or `io_uring`. |
| `DISK_DISCARD` | `unmap` | Discard/TRIM mode for the primary disk. |
| `DISK_ROTATION` | `1` | Rotation rate reported to the guest. Use `1` to identify the disk as an SSD. |
| `DISK_FLAGS` |  | Additional options used when creating `qcow2` disks. |
| `ALLOCATE` | `N` | Preallocates space for the primary disk. |
| `STORAGE` | `/storage` | Storage directory used for disks, firmware variables, and downloads. |

## 🌐 Networking

| Variable | Default | Description |
|---|---|---|
| `NETWORK` |  | Network mode, such as `nat`, `passt`, `slirp`, or `N` to disable networking. |
| `DHCP` | `N` | Enables macvtap networking so macOS receives an address from the external LAN through DHCP. |
| `HOST` | `macOS` | Hostname assigned to macOS. |
| `IP` |  | Overrides the automatically selected guest IPv4 address. |
| `MAC` |  | Guest network adapter MAC address. Generated automatically when unset. |
| `ADAPTER` | `virtio-net-pci` | QEMU network adapter model. |
| `DEV` | `eth0` | Container network interface used as the uplink. |
| `MTU` |  | MTU assigned to the guest network interface. |
| `MASK` | `255.255.255.0` | IPv4 netmask. |
| `TAP` | `qemu` | TAP or macvtap interface name. |
| `BRIDGE` | `docker` | Bridge name used for NAT networking. |
| `HOST_PORTS` |  | Ports excluded from guest forwarding. |
| `USER_PORTS` |  | Additional ports to forward to macOS when using user-mode networking. |
| `DNSMASQ_OPTS` |  | Additional options passed to dnsmasq. |
| `DNSMASQ_DEBUG` | `N` | Enables dnsmasq debug output. |
| `DNSMASQ_DISABLE` | `N` | Disables the internal dnsmasq resolver. |
| `PASST_OPTS` |  | Additional options passed to passt. |
| `PASST_DEBUG` | `N` | Enables passt debug output. |

## 🖥️ Display

| Variable | Default | Description |
|---|---|---|
| `DISPLAY` | `web` | Display backend, such as `web`, `vnc`, `disabled`, or `none`. |
| `VGA` | `vmware` | QEMU video adapter model. |
| `WIDTH` | `1920` | Display width configured for macOS and OpenCore. |
| `HEIGHT` | `1080` | Display height configured for macOS and OpenCore. |

## 🌍 Web UI

| Variable | Default | Description |
|---|---|---|
| `WEB` | `Y` | Enables the web interface. |
| `WEB_PORT` | `8006` | Port for the web interface. |
| `VNC_PORT` | `5900` | Port for the VNC server. |
| `WSS_PORT` | `5700` | WebSocket port used by noVNC. |
| `WSD_PORT` | `8004` | Internal websocketd port used for the display stream. |
| `AUDIO` | `N` | Streams guest audio to the web viewer. |
| `SOUND` | `usb-audio` | QEMU audio device used by the web viewer. |
| `AUX_PORT` | `8003` | Internal WebSocket port used for the audio stream. |
| `PROTECT` | `N` | Enables password protection for the web interface. |

## ⚙️ System

| Variable | Default | Description |
|---|---|---|
| `MACHINE` | `q35` | QEMU machine type. |
| `HPET` | `off` | QEMU HPET timer setting. |
| `VMPORT` | `off` | QEMU VMware port setting. |
| `ARGUMENTS` |  | Additional raw arguments appended to the QEMU command line. |

## 🚀 Boot

| Variable | Default | Description |
|---|---|---|
| `PICKER` | `N` | Shows the OpenCore boot picker. |
| `SECURE` | `off` | QEMU Secure Boot flag. |
| `LOGO` | `Y` | Enables the custom boot logo. |
| `BOOT_INDEX` | `9` | Boot priority index for the OpenCore boot media. |
| `USB` | `nec-usb-xhci,id=xhci` | QEMU USB controller configuration. |

## 🎈 Memory Ballooning

Also see [Dynamic memory allocation](https://github.com/qemus/qemu/blob/master/docs/ballooning.md) for usage instructions and important caveats.

| Variable | Default | Description |
|---|---|---|
| `BALLOONING` | `N` | Enables dynamic memory ballooning. |
| `BALLOONING_MIN_MEM` | `33%` | Minimum amount of memory retained by the VM. |
| `BALLOONING_RAM_THRESHOLD` | `80.0` | Host RAM usage percentage at which ballooning begins adjusting memory. |
| `BALLOONING_RAM_THRESHOLD_HARD` | `90.0` | Host RAM usage percentage at which ballooning becomes more aggressive. |
| `BALLOONING_PSI_PRESSURE` | `10.0` | PSI memory pressure level at which ballooning becomes more aggressive. |
| `BALLOONING_PSI_PRESSURE_MAX` | `50.0` | PSI memory pressure level at which ballooning reaches its strongest response. |
| `BALLOONING_HYSTERESIS` | `128M` | Minimum memory change before the balloon target is updated. |
| `BALLOONING_KP` | `0.5` | Proportional gain used by the ballooning controller. |
| `BALLOONING_KI` | `0.05` | Integral gain used by the ballooning controller. |
| `BALLOONING_INTERVAL` | `5` | Polling interval in seconds. |
| `BALLOONING_DEBUG` | `N` | Enables debug output for the ballooning monitor. |

## 🔌 Shutdown

| Variable | Default | Description |
|---|---|---|
| `SHUTDOWN` | `Y` | Enables graceful ACPI shutdown. |
| `TIMEOUT` | `115` | Maximum time, in seconds, to wait before forcing macOS to stop. |

## 🐞 Debugging

| Variable | Default | Description |
|---|---|---|
| `DEBUG` | `N` | Enables verbose debug output. |
| `TRACE` | `N` | Enables shell command tracing. |
| `SERIAL` | `mon:stdio` | QEMU serial device configuration. |
| `MONITOR` | `unix:$QEMU_DIR/monitor.sock,server,wait=off,nodelay` | QEMU monitor configuration. |
