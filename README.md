# LanXfer

Ethernet kablosuyla (veya aynı ağdaki) iki Windows bilgisayar arasında **kurulumsuz** dosya aktarımı.
[winutil](https://github.com/ChrisTitusTech/winutil) gibi tek satırla terminalden çalışır, tamamen RAM'de durur — diske hiçbir şey kurmaz.

## Kullanım

1. İki PC'yi Ethernet kablosuyla bağlayın (modern kartlarda düz kablo yeterli, IP ayarı gerekmez — Windows otomatik `169.254.x.x` adresi verir).
2. **Her iki PC'de** PowerShell açın (tercihen *Yönetici olarak*) ve çalıştırın:

```powershell
irm https://raw.githubusercontent.com/OgeaN/lanxfer/main/lanxfer.ps1 | iex
```

3. Tarayıcıda arayüz açılır, karşı PC birkaç saniye içinde otomatik bulunur ve bağlanılır.
4. Dosya/klasörleri sürükleyip bırakın → karşı PC'nin `İndirilenler\LanXfer` klasörüne gider.

### Karşı PC'de internet yoksa

Bir PC'de LanXfer açıkken, diğer PC'de şunu çalıştırın (IP, açık olan PC'nin ekranında yazar):

```powershell
irm http://169.254.x.x:8765/s | iex
```

Betik doğrudan kablo üzerinden diğer PC'den indirilir.

## Ayarlar

Çalıştırmadan önce ortam değişkeni olarak verilebilir:

| Değişken | Varsayılan | Açıklama |
|---|---|---|
| `LANXFER_PORT` | `8765` | HTTP portu |
| `LANXFER_UDP` | `8766` | Otomatik bulma (UDP yayın) portu |
| `LANXFER_DIR` | `%USERPROFILE%\Downloads\LanXfer` | Gelen dosyalar klasörü |
| `LANXFER_NOBROWSER` | — | `1` ise tarayıcı otomatik açılmaz |

```powershell
$env:LANXFER_DIR = 'D:\Gelen'; irm https://raw.githubusercontent.com/OgeaN/lanxfer/main/lanxfer.ps1 | iex
```

## Nasıl çalışır

- `lanxfer.ps1` saf PowerShell 5.1 — Windows 10/11'de hazır gelir, ek bir şey gerekmez.
- Betik içinde küçük bir HTTP sunucusu (`TcpListener`) çalışır; arayüz (HTML/CSS/JS) betiğin içine gömülüdür ve tarayıcıda açılır.
- Her bağlantı ayrı bir runspace'te işlenir; dosyalar 1 MB'lık parçalarla doğrudan diske akar (büyük dosyalarda RAM şişmez).
- Karşı PC, UDP yayın mesajlarıyla otomatik bulunur.
- Yönetici olarak açıldıysa geçici güvenlik duvarı kuralı ekler, `Ctrl+C` ile kapanırken siler. Yönetici değilse Windows'un sorduğu uyarıda **Ortak (Public)** ağlara da izin verin — doğrudan kablo bağlantısı "Tanımlanamayan ağ / Ortak" sayılır.

## Güvenlik notu

Aynı ağdaki herkes gelen kutusuna dosya gönderebilir ve oradaki dosyaları indirebilir. Doğrudan kablo bağlantısı için tasarlanmıştır; kafe/okul gibi ortak ağlarda açık bırakmayın.

## Yerel çalıştırma (repo klonlandıysa)

`start.cmd` dosyasına çift tıklayın.
