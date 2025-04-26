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

OSX (macOS) dentro de um contêiner Docker.

## Funcionalidades ✨

 - Aceleração KVM
 - Visualizador online
 - Download automático

## Uso  🐳

##### Via Docker Compose:

```yaml
services:
  macos:
    image: dockurr/macos
    container_name: macos
    environment:
      VERSION: "13"
    devices:
      - /dev/kvm
      - /dev/net/tun
    cap_add:
      - NET_ADMIN
    ports:
      - 8006:8006
      - 5900:5900/tcp
      - 5900:5900/udp
    volumes:
      - ./macos:/storage
    restart: always
    stop_grace_period: 2m
```

##### Via Docker CLI:

```bash
docker run -it --rm --name macos -p 8006:8006 --device=/dev/kvm --device=/dev/net/tun --cap-add NET_ADMIN -v "${PWD:-.}/macos:/storage" --stop-timeout 120 dockurr/macos
```

##### Via Kubernetes:

```shell
kubectl apply -f https://raw.githubusercontent.com/dockur/macos/refs/heads/master/kubernetes.yml
```

##### Via Github Codespaces:

[![Abra no GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/dockur/macos)

## FAQ 💬

### Como eu uso?

  Muito simples! Estes são os passos:
  
  - Inicie o container e conecte à [porta 8006](http://127.0.0.1:8006/) usando seu navegador web.

  - Vá em `Disk Utility` e então selecione o maior disco `Apple Inc. VirtIO Block Media`.

  - Clique no botão `Erase` para formatar o disco para APFS, e dê o nome de sua preferência.

  - Feche a janela atual e continue com a instalação clicando em `Reinstall macOS`.
  
  - Quando solicitado sobre onde instalar, selecione o disco que você criou anteriormente.
 
  - Após a cópia dos arquivos, selecione sua região, idioma e configurações de conta.
  
  Aproveite sua mais nova máquina e não se esqueça de dar uma estrela neste repositório!

### Como eu seleciono a versão do macOS?

  Por padrão, o macOS 13 (Ventura) estará instalado, mas você pode adicionar a variável de ambiente `VERSION` com o intuito de especificar uma alternativa:

  ```yaml
  environment:
    VERSION: "13"
  ```

  Selecione a partir dos valores abaixo:
  
  |   **Valor** | **Versão**    | **Nome** |
  |-------------|----------------|------------------|
  | `15`        | macOS 15       | Sequoia          |
  | `14`        | macOS 14       | Sonoma           |
  | `13`        | macOS 13       | Ventura          |
  | `12`        | macOS 12       | Monterey         |
  | `11`        | macOS 11       | Big Sur          |

> [!NOTA]
> O suporte para macOS 15 (Sequoia) ainda está em fase inicial de desenvolvimento, e por isso ainda não permite que você entre na sua conta da Apple. 

### Como eu mudo o local de armazenamento?

  Para mudar o local de armazenamento, adicione o seguinte bind mount no seu arquivo de compose:

  ```yaml
  volumes:
    - ./macos:/storage
  ```

 Substitua o caminho de exemplo `./macos` pela pasta de armazenamento desejada ou volume nomeado.

### Como eu altero o tamanho do disco?

  Para aumentar o tamanho padrão de 64 GB, adicione a configuração de `DISK_SIZE` ao seu arquivo compose e defina o seu tamanho de preferência:

  ```yaml
  environment:
    DISK_SIZE: "256G"
  ```
  
> [!DICA]
> Isso também pode ser usado para redimensionar o disco existente para uma capacidade maior sem perda de dados.

### Como eu altero a capacidade de CPU ou RAM?

  Por padrão, o container pode usar no máximo 2 núcleos de CPU e 4 GB de RAM.

  Se você deseja ajustar isso, pode especificar a quantidade desejada usando as seguintes variáveis de ambiente:

  ```yaml
  environment:
    RAM_SIZE: "8G"
    CPU_CORES: "4"
  ```

### Como eu atribuo um endereço IP individual ao container?

  Por padrão, o container usa rede em bridge, compartilhando o endereco IP com o host.

  Se você quiser atribuir um endereço IP individual ao container, pode criar uma rede macvlan da seguinte maneira:

  ```bash
  docker network create -d macvlan \
      --subnet=192.168.0.0/24 \
      --gateway=192.168.0.1 \
      --ip-range=192.168.0.100/28 \
      -o parent=eth0 vlan
  ```
  
  Certifique-se de ajustar esses valores para ficar de acordo com à sua sub-rede local. 

  Depois de criar a rede, altere seu arquivo de compose da seguinte forma:

  ```yaml
  services:
    macos:
      container_name: macos
      ..<snip>..
      networks:
        vlan:
          ipv4_address: 192.168.0.100

  networks:
    vlan:
      external: true
  ```
 
  Um benefício adicional dessa abordagem é que você não precisará mais realizar o mapeamento de portas, pois todas as portas serão expostas por padrão.

> [!IMPORTANTE]  
> Este endereço IP não será acessível a partir do host Docker devido ao design do macvlan, que não permite comunicação entre os dois. Se isso for um problema, você precisará criar um [segundo macvlan](https://blog.oddbit.com/post/2018-03-12-using-docker-macvlan-networks/#host-access) como solução alternativa.

### Como o macOS pode adquirir um endereço IP do meu roteador?

  Após configurar o container para o [macvlan](#how-do-i-assign-an-individual-ip-address-to-the-container), é possível que o macOS se conecte à sua rede local solicitando um IP do roteador, assim como os seus outros dispositivos.

  Para habilitar este modo, no qual o container e o macOS terão endereços IP separados, adicione as seguintes linhas ao seu arquivo de compose:

  ```yaml
  environment:
    DHCP: "Y"
  devices:
    - /dev/vhost-net
  device_cgroup_rules:
    - 'c *:* rwm'
  ```

### Como eu passo um disco para o container?

  Você pode passar dispositivos ou partições de disco diretamente para o container, adicionando-os ao seu arquivo de compose desta maneira:

  ```yaml
  devices:
    - /dev/sdb:/disk1
    - /dev/sdc1:/disk2
  ```

  Use `/disk1` se você quiser torná-lo o disco principal e `/disk2` ou um valor maior, para adicionar como discos secundários.
  
### Como eu passo um dispositivo USB para o container?

  Para passar um dispositivo USB, primeiro encontre o ID do fabricante e do produto via comando `lsusb` depois adicione ao seu compose da seguinte forma:

  ```yaml
  environment:
    ARGUMENTS: "-device usb-host,vendorid=0x1234,productid=0x1234"
  devices:
    - /dev/bus/usb
  ```

### Como eu compartilho arquivos com o host?

  Adicione o seguinte volume ao seu compose para compartilhar arquivos com o host:

  ```yaml
  volumes:
    - ./example:/shared
  ```

  Depois, inicie o macOS e execute o seguinte comando:
  
  ```shell
  sudo -S mount_9p shared
  ```

  No menu do Finder, clique em “Ir – Computador” para acessar a pasta compartilhada, que mostrará o conteúdo de `./example`.
  
### Como eu verifico se meu sistema suporta KVM?

  Primeiro, verifique a compatibilidade do seu software usando a tabela abaixo:

  | **Produto**  | **Linux** | **Win11** | **Win10** | **macOS** |
  |---|---|---|---|---|
  | Docker CLI        | ✅   | ✅       | ❌        | ❌ |
  | Docker Desktop    | ❌   | ✅       | ❌        | ❌ | 
  | Podman CLI        | ✅   | ✅       | ❌        | ❌ | 
  | Podman Desktop    | ✅   | ✅       | ❌        | ❌ | 

  Em seguida, execute os comandos no Linux para verificar seu sistema:

  ```bash
  sudo apt install cpu-checker
  sudo kvm-ok
  ```

  Se você receber um erro do `kvm-ok` indicando que o KVM não pode ser usado, verifique se:

  - As extensões de virtualização (`Intel VT-x` ou `AMD SVM`) estão ativadas no BIOS.

  - "Virtualização aninhada" foi habilitada se você estiver executando o container dentro de uma máquina virtual.

  - Você não está utilizando um provedor de nuvem, pois a maioria deles não permite virtualização aninhada em suas VPS.

  Se não houver erro de `kvm-ok` mas o container ainda reclamar sobre a falta de um dispositivo KVM, adicione `privileged: true` no seu compose (ou `sudo` no comando `docker`) para resolver possíveis problemas de permissão.

### Como eu rodo o Windows em um container?

  Você pode usar o [dockur/windows](https://github.com/dockur/windows) para isso, que compartilha muitos recursos, incluindo instalação automática.

### Como eu rodo um desktop Linux em um container?

  Você pode usar o [qemus/qemu](https://github.com/qemus/qemu) nesse caso.

### Este projeto é legal?

  Sim, este projeto contém apenas código open-source e não distribui material com direitos autorais. Também não tenta contornar medidas de proteção de copyright. Portanto, de acordo com todas as leis aplicáveis, este projeto será considerado legal.

  No entanto, ao instalar o macOS da Apple, você deve aceitar o contrato de licença de usuário final, que não permite a instalação em hardware não oficial. Portanto, execute este container apenas em hardware vendido pela Apple, pois qualquer outro uso violará seus termos e condições.

 ## Agradecimentos 🙏

Agradecimentos especiais a [seitenca](https://github.com/seitenca), sem o trabalho valioso dela, este projeto não existiria.

## Estrelas 🌟
[![Estrelas](https://starchart.cc/dockur/macos.svg?variant=adaptive)](https://starchart.cc/dockur/macos)

## Isenção de responsabilidade ⚖️

*Execute este container apenas em hardware da Apple, qualquer outro uso não é permitido pelo EULA deles. Os nomes dos produtos, logotipos, marcas e outras marcas registradas mencionados neste projeto são propriedade de seus respectivos detentores. Este projeto não é afiliado, patrocinado ou endossado pela Apple Inc.*

[build_url]: https://github.com/dockur/macos/
[hub_url]: https://hub.docker.com/r/dockurr/macos/
[tag_url]: https://hub.docker.com/r/dockurr/macos/tags
[pkg_url]: https://github.com/dockur/macos/pkgs/container/macos

[Build]: https://github.com/dockur/macos/actions/workflows/build.yml/badge.svg
[Size]: https://img.shields.io/docker/image-size/dockurr/macos/latest?color=066da5&label=size
[Pulls]: https://img.shields.io/docker/pulls/dockurr/macos.svg?style=flat&label=pulls&logo=docker
[Version]: https://img.shields.io/docker/v/dockurr/macos/latest?arch=amd64&sort=semver&color=066da5
[Package]: https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fipitio.github.io%2Fbackage%2Fdockur%2Fmacos%2Fmacos.json&query=%24.downloads&logo=github&style=flat&color=066da5&label=pulls
