
<h1 align="center">OSX<br />
<div align="center">
<a href="https://github.com/dockur/macos/"><img src="https://github.com/dockur/macos/raw/master/.github/logo.png" title="Logo" style="max-width:100%;" width="128" /></a>
</div>
<div align="center">

[![Build]][build_url]
[![Version]][tag_url]
[![Size]][tag_url]
[![Package]][pkg_url]
[![Pulls]][hub_url]

</div></h1>

Bir Docker konteynerinin içindeki OSX (macOS).

## Özellikler ✨

- KVM hızlandırma
- Web tabanlı görüntüleyici
- Otomatik indirme

## Kullanım 🐳

Docker Compose aracılığıyla:

```yaml
hizmetler:
macos:
görüntü: dockurr/macos
kapsayıcı_adı: macos
ortam:
SÜRÜM: "13"
cihazlar:
- /dev/kvm
cap_add:
- NET_ADMIN
bağlantı noktaları:
- 8006:8006
- 5900:5900/tcp
- 5900:5900/udp
stop_grace_period: 2m
```

Docker CLI aracılığıyla:

```bash
docker run -it --rm -p 8006:8006 --device=/dev/kvm --cap-add NET_ADMIN --stop-timeout 120 dockurr/macos
```

Kubernetes Üzerinden:

```shell
kubectl apply -f https://raw.githubusercontent.com/dockur/macos/refs/heads/master/kubernetes.yml
```

## Uyumluluk ⚙️

| **Ürün** | **Platform** | |
|---|---|---|
| Docker Motoru | Linux| ✅ |
| Docker Masaüstü | Linux | ❌ |
| Docker Masaüstü | macOS | ❌ |
| Docker Masaüstü | Windows 11 | ✅ |
| Docker Masaüstü | Windows 10 | ❌ |

## SSS 💬

### Nasıl kullanırım?

Çok basit! İşte adımlar:

- Konteyneri başlatın ve web tarayıcınızı kullanarak [port 8006](http://localhost:8006) adresine bağlanın.

- `Disk Utility` öğesini seçin ve ardından en büyük `Apple Inc. VirtIO Block Media` diskini seçin.

- Diski biçimlendirmek için `Erase` düğmesine tıklayın ve istediğiniz tanınabilir adı verin.

- Geçerli pencereyi kapatın ve `Reinstall macOS` öğesine tıklayarak yüklemeye devam edin.

- Nereye yüklemek istediğiniz sorulduğunda, daha önce oluşturduğunuz diski seçin.

- Tüm dosyalar kopyalandıktan sonra bölgenizi, dilinizi ve hesap ayarlarınızı seçin.

Yepyeni makinenizin tadını çıkarın ve bu depoya yıldız eklemeyi unutmayın!

### macOS sürümünü nasıl seçerim?

Varsayılan olarak, en iyi performansı sunduğu için macOS 13 (Ventura) yüklenecektir.

Ancak alternatif bir macOS sürümünü indirmek için compose dosyanıza `VERSION` ortam değişkenini ekleyebilirsiniz:

```yaml
environment:
VERSION: "13"
```

Aşağıdaki değerlerden birini seçin:

| **Değer** | **Sürüm** | **Ad** |
|--------------|-----------------|------------------|
| `15` | macOS 15 | Sequoia |
| `14` | macOS 14 | Sonoma |
| `13` | macOS 13 | Ventura |
| `12` | macOS 12 | Monterey |
| `11` | macOS 11 | Big Sur |

### Depolama konumunu nasıl değiştiririm?

Depolama konumunu değiştirmek için, compose dosyanıza aşağıdaki bağlama bağlantısını ekleyin:

```yaml
volumes:
- /var/osx:/storage
```

Örnek yol `/var/osx`'u istediğiniz depolama klasörüyle değiştirin.

### Diskin boyutunu nasıl değiştiririm?

Varsayılan 64 GB boyutunu genişletmek için, compose dosyanıza `DISK_SIZE` ayarını ekleyin ve tercih ettiğiniz kapasiteye ayarlayın:

```yaml
environment:
DISK_SIZE: "256G"
```

> [!TIP]
> Bu, herhangi bir veri kaybı olmadan mevcut diski daha büyük bir kapasiteye yeniden boyutlandırmak için de kullanılabilir.

### CPU veya RAM miktarını nasıl değiştiririm?

Varsayılan olarak, konteynerin en fazla 2 CPU çekirdeği ve 4 GB RAM kullanmasına izin verilir.

Bunu ayarlamak isterseniz, aşağıdaki ortam değişkenlerini kullanarak istediğiniz miktarı belirtebilirsiniz:

```yaml
environment:
RAM_SIZE: "8G"
CPU_CORES: "4"
```

### Bir USB aygıtını nasıl geçirebilirim?

Bir USB aygıtını geçirmek için, önce `lsusb` komutuyla satıcısını ve ürün kimliğini arayın, ardından bunları compose dosyanıza şu şekilde ekleyin:

```yaml
environment:
ARGUMENTS: "-device usb-host,vendorid=0x1234,productid=0x1234"
devices:
- /dev/bus/usb
```

### Sistemimin KVM'yi destekleyip desteklemediğini nasıl doğrulayabilirim?

Yalnızca Linux ve Windows 11 KVM sanallaştırmayı destekler, macOS ve Windows 10 ne yazık ki desteklemez.

Sisteminizi kontrol etmek için Linux'ta aşağıdaki komutları çalıştırabilirsiniz:

```bash
sudo apt install cpu-checker
sudo kvm-ok
```

`kvm-ok` komutundan KVM kullanılamayacağını belirten bir hata alırsanız lütfen şunları kontrol edin:

- BIOS'unuzda sanallaştırma uzantıları (`Intel VT-x` veya `AMD SVM`) etkindir.

- Konteyneri bir sanal makine içinde çalıştırıyorsanız "iç içe sanallaştırma"yı etkinleştirdiniz.

- Bir bulut sağlayıcısı kullanmıyorsunuz çünkü çoğu VPS'leri için iç içe sanallaştırmaya izin vermiyor.

`kvm-ok` komutundan herhangi bir hata almazsanız ancak konteyner hala KVM'den şikayet ediyorsa lütfen şunları kontrol edin:

- KVM'yi desteklemediği için "Linux için Docker Desktop" kullanmıyorsunuz, bunun yerine doğrudan Docker Engine'i kullanın.

- Herhangi bir izin talebini engellemek için `privileged: true` komutunu compose dosyanıza (veya `docker run` komutunuza `sudo` komutunu) eklemeniz yardımcı olabilir.
