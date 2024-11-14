[![CI](https://github.com/opensearch-project/security/workflows/CI/badge.svg?branch=main)](https://github.com/opensearch-project/security/actions) [![](https://img.shields.io/github/issues/opensearch-project/security/untriaged?labelColor=red)](https://github.com/opensearch-project/security/issues?q=is%3Aissue+is%3Aopen+label%3A"untriaged") [![](https://img.shields.io/github/issues/opensearch-project/security/security%20vulnerability?labelColor=red)](https://github.com/opensearch-project/security/issues?q=is%3Aissue+is%3Aopen+label%3A"security%20vulnerability") [![](https://img.shields.io/github/issues/opensearch-project/security)](https://github.com/opensearch-project/security/issues) [![](https://img.shields.io/github/issues-pr/opensearch-project/security)](https://github.com/opensearch-project/security/pulls) [![](https://img.shiel) ds.io/codecov/c/gh/opensearch-project/security)](https://app.codecov.io/gh/opensearch-project/security) [![](https://img.shields.io/github/issues/opensearch-project/security/v2.18.0)](https://github.com/opensearch-project/security/issues?q=is%3Aissue+is%3Aopen+label%3A "v2.18.0") [![](https://img.shields.io/github/issues/opensearch-project/security/v3.0.0)](https://github.com/opensearch-project/security/issues?q=is%3Aissue+is%3Aopen+label%3A"v3.0.0")
[![Slack](https://img.shields.io/badge/Slack-4A154B?&logo=slack&logoColor=white)](https://opensearch.slack.com/archives/C051Y637FKK)

## Duyuru: Slack çalışma alanı yayında! Lütfen [sohbete](https://opensearch.slack.com/archives/C051Y637FKK) katılın.

<img src="https://opensearch.org/assets/img/opensearch-logo-themed.svg" height="64px">

# OpenSearch Güvenlik Eklentisi

OpenSearch Güvenliği, şifreleme, kimlik doğrulama ve yetkilendirme sunan bir OpenSearch eklentisidir. OpenSearch Security-Advanced Modülleri ile birleştirildiğinde, Active Directory, LDAP, Kerberos, JSON web belirteçleri, SAML, OpenID ve daha fazlası aracılığıyla kimlik doğrulamayı destekler. Dizinlere, belgelere ve alanlara ince ayrıntılı rol tabanlı erişim denetimi içerir. Ayrıca OpenSearch Panolarında çoklu kiracı desteği sağlar.

- [OpenSearch Güvenlik Eklentisi](#opensearch-security-plugin)
- [Özellikler](#özellikler)
- [Şifreleme](#şifreleme)
- [Kimlik Doğrulama](#kimlik doğrulama)
- [Erişim denetimi](#erişim denetimi)
- [Denetim/Uyumluluk kaydı](#auditcompliance-logging)
- [OpenSearch Panoları çoklu kiracı](#opensearch-dashboards-çoklu kiracı)
- [Kurulum](#kurulum)
- [Test ve Derleme](#test-and-build)
- [Sıcak yeniden yüklemeyi yapılandır](#config-hot-reloading)
- [Yeni API'leri yerleştirme](#onboarding-new-apis)
- [Sistem Dizin Koruması](#system-index-protection)
- [Katkıda Bulunma](#contributing)
- [Alma Yardım](#getting-help)
- [Davranış Kuralları](#davranış-kuralları)
- [Güvenlik](#güvenlik)
- [Lisans](#lisans)
- [Telif Hakkı](#telif hakkı)

## Özellikler

### Şifreleme
* Transit sırasında tam veri şifrelemesi
* Düğümler arası şifreleme
* Sertifika iptal listeleri
* Sıcak Sertifika yenileme

### Kimlik doğrulama
* Dahili kullanıcı veritabanı
* HTTP temel kimlik doğrulaması
* PKI kimlik doğrulaması
* Proxy kimlik doğrulaması
* Kullanıcı Kimliğine Bürünme
* Active Directory / LDAP
* Kerberos / SPNEGO
* JSON web belirteci (JWT)
* OpenID Connect (OIDC)
* SAML

### Erişim denetimi
* Rol tabanlı küme düzeyinde erişim denetimi
* Rol tabanlı dizin düzeyinde erişim denetimi
* Kullanıcı, rol ve izin yönetimi
* Belge düzeyinde güvenlik
* Alan düzeyinde güvenlik
* REST yönetim API'si

### Denetim/Uyumluluk günlük kaydı
* Denetim günlüğü
* GDPR, HIPAA, PCI, SOX ve ISO uyumluluğu için uyumluluk günlüğü

### OpenSearch Panoları çoklu kiracı
* Gerçek OpenSearch Panoları çoklu kiracı

## Kurulum

OpenSearch Güvenlik Eklentisi varsayılan olarak OpenSearch dağıtımının bir parçası olarak birlikte gelir. OpenSearch Güvenlik Eklentisini yükleme ve yapılandırma hakkında ayrıntılı bilgi için lütfen [kurulum kılavuzuna](https://opensearch.org/docs/latest/opensearch/install/index/) ve [teknik belgelere](https://opensearch.org/docs/latest/security-plugin/index/) bakın.

Ayrıca, başlangıçta eklentiye sahip olmayan bir OpenSearch sunucusu için eklentinin kurulumunu adım adım açıklayan [geliştirici kılavuzuna](https://github.com/opensearch-project/security/blob/main/DEVELOPER_GUIDE.md) da bakabilirsiniz.

## Test ve Oluşturma

Tüm testleri çalıştırın:
```bash
./gradlew clean test
```

Testleri yerel kümeye karşı çalıştırın:
```bash
./gradlew integTestRemote -Dtests.rest.cluster=localhost:9200 -Dtests.cluster=localhost:9200 -Dtests.clustername=docker-cluster -Dsecurity=true -Dhttps=true -Duser=admin -Dpassword=admin -Dcommon_utils.version="2.2.0.0"
```
VEYA
```bash
./scripts/integtest.sh
```
Not: Uzak bir kümeye karşı çalıştırmak için cluster-name ve `localhost:9200` öğelerini o kümenin IPAddress:Port'uyla değiştirin.

Yapıtları derle (zip, deb, rpm):
```bash
./gradlew clean assembly
artifact_zip=`ls $(pwd)/build/distributions/opensearch-security-*.zip | grep -v admin-standalone`
./gradlew buildDeb buildRpm -ParchivePath=$artifact_zip
```

Bu şunu üretir:

``
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
