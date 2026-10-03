# Sistem Monitörü — Yapı Planı

macOS 26 Tahoe / Apple Silicon için Stats eşdeğeri bir sistem izleyicisi.
Web hâli: https://claude.ai/code/artifact/be70e490-01fb-43d1-adb5-33f127c33b58

Ortam: macOS 26.5.1 · Xcode 26.6 · Swift 6.3 · Hedef macOS 26.0+
Tahmin: ~26–32 çalışma günü

---

## Sabitlenmiş kararlar

| Konu | Karar | Gerekçe |
|---|---|---|
| Kapsam | Tam Stats eşdeğeri (10 modül) | Remote/bulut modülü kapsam dışı |
| Arayüz | Menü çubuğu + pencere | Modül başına NSStatusItem + popover + ayar/detay penceresi |
| Dağıtım | Sandbox kapalı, GitHub | Developer ID + notarization. **Mac App Store hedef değil** — SMC/IOReport orada çalışmaz |
| Render | AppKit menübar, SwiftUI pencere | Widget'lar NSView+CoreGraphics; pencere/popover SwiftUI |
| Veri saklama | Yalnızca bellek | Modül başına 300 örneklik halka tampon, diske yazma yok |
| Dil | Türkçe + İngilizce | String Catalog, varsayılan Türkçe |

---

## Mimari

Tek yönlü akış. Modüller birbirini tanımaz, hepsi aynı motora abonedir.

```
Reader          MachHost · SysctlBridge · IOKitBridge · IOReportBridge†
                SMCReader · HIDSensorReader · DiskArbitration
                NetworkInterfaces · PowerSources · ProcessLister
   ▼
SamplingEngine  TimerHub (1s/3s/5s/10s) · Sampler protokolü
                RingBuffer<Double> (cap 300) · MetricSnapshot
                Uyku/uyanma askıya alma
   ▼
Modules         Dashboard · CPU · GPU · RAM · Disk · Sensors
                Network · Battery · Bluetooth · Clock
   ▼
Presentation    StatusItemController · WidgetRenderer (NSView)
                PopoverHost · MainWindow (SwiftUI)
                SettingsStore (@Observable) · NotificationEngine
```

† **IOReport.framework belgelenmemiş bir Apple çerçevesi.** CPU frekansı, ANE kullanımı ve güç
tüketimi başka türlü okunamıyor (`powermetrics` de bunu kullanıyor). dlopen ile çalışma anında
yüklenecek — yoksa veya macOS güncellemesiyle bozulursa uygulama çökmez, o metrikler gizlenir.
Bu tercih Mac App Store kapısını kalıcı kapatır.

---

## Veri kaynakları

Zorluk etiketi hem emeği hem "hiç çalışmama" ihtimalini ifade eder.

### Gösterge paneli
| Metrik | Kaynak | Zorluk |
|---|---|---|
| Model adı ve görseli | `system_profiler SPHardwareDataType -json` + `hw.model` (Mac17,8 → pazarlama adı kendi kataloğumuzda; cihaz görselini kendimiz çiziyoruz) | Orta |
| İşlemci / çekirdek dağılımı | `machdep.cpu.brand_string`, `hw.perflevel{N}.physicalcpu`, `hw.perflevel{N}.name` — çekirdek sınıfı adları donanımdan okunur, sabit kodlanmaz | Düşük |
| Bellek / GPU çekirdeği / ekran | `hw.memsize` · IORegistry `gpu-core-count` · NSScreen + CGDisplayCopyDisplayMode | Düşük |
| Seri no, çalışma süresi | IOPlatformExpertDevice · `kern.boottime` | Düşük |

### CPU
| Metrik | Kaynak | Zorluk |
|---|---|---|
| Toplam + çekirdek başına yük | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` tick deltası; ilk örnek atılır | Düşük |
| Sistem/kullanıcı/boşta | Aynı çağrının CPU_STATE_* alanları | Düşük |
| Ortalama yük | `getloadavg()` | Düşük |
| Frekans (MHz) | IOReport "CPU Stats" / "CPU Complex Performance States" DVFS kalış süreleri × IORegistry voltage-states tablosu | **Yüksek** |
| Üst süreçler | `ps -Aceo pid,pcpu,comm -r` (ortak ProcessLister, yalnızca popover açıkken) | Düşük |

### GPU
| Metrik | Kaynak | Zorluk |
|---|---|---|
| Kullanım / render / tiler | `IOServiceMatching("IOAccelerator")` → PerformanceStatistics | Düşük |
| ANE kullanımı | IOReport "ANE" kanal grubu | **Yüksek** |
| FPS | IOAccelerator kare sayacı deltası — alan adı modele göre değişebilir, Faz 3'te doğrulanacak | Orta |
| GPU gücü (mW) | IOReport "Energy Model" | **Yüksek** |

### RAM
| Metrik | Kaynak | Zorluk |
|---|---|---|
| Uygulama/bağlı/sıkıştırılmış/serbest | `host_statistics64(HOST_VM_INFO64)` — Activity Monitor formülü belgelenmemiş, Faz 2'de kalibre edilecek | Orta |
| Takas | `sysctlbyname("vm.swapusage")` | Düşük |
| Bellek baskısı | `kern.memorystatus_vm_pressure_level` + DispatchSource memorypressure (olay tabanlı) | Düşük |
| Üst süreçler | `ps -Aceo pid,pmem,rss,comm -m` | Düşük |

### Disk
| Metrik | Kaynak | Zorluk |
|---|---|---|
| Birimler / kapasite / FS | FileManager.mountedVolumeURLs + DiskArbitration | Düşük |
| Okuma / yazma hızı | IOBlockStorageDriver → `Statistics` deltası | Düşük |
| Model / BSD adı / protokol | DADiskCopyDescription | Düşük |
| SMART | IONVMeSMARTUserClient — **Apple Silicon dahili NVMe'de çoğu zaman erişim vermiyor** (Stats'te de "Bilinmeyen"). Harici NVMe'de çalışır | **Yüksek** |

### Sensörler — en riskli modül
| Metrik | Kaynak | Zorluk |
|---|---|---|
| Sıcaklıklar | `IOHIDEventSystemClient`, AppleVendor sayfası 0xFF00, kullanım 5. Apple Silicon'da sıcaklık SMC'den değil HID'den gelir; adlar modele göre değişir | **Yüksek** |
| Voltaj / akım | HID kullanım 6 + SMC anahtarları | Orta |
| Güç (CPU/GPU/ANE/RAM/toplam) | IOReport "Energy Model" + SMC PSTR | **Yüksek** |
| Fan RPM / min / maks / mod | AppleSMC → IOConnectCallStructMethod (F0Ac/F0Mn/F0Mx/FS!). Fansız modellerde bölüm gizlenir | Orta |
| Türetilmiş (Ortalama/En sıcak CPU-GPU, Toplam tüketim) | Ham sensörlerden hesaplanır | Düşük |

### Ağ
| Metrik | Kaynak | Zorluk |
|---|---|---|
| İndirme / yükleme | `getifaddrs()` AF_LINK → `if_data.ibytes/obytes` deltası | Düşük |
| Birincil arayüz / durum | SCDynamicStore + SCNetworkReachability | Düşük |
| Wi-Fi ad / sinyal / hız | CoreWLAN — **macOS 14+ ağ adı için Konum Servisleri izni ister.** İzin yoksa sadece sinyal/hız | Orta |
| Yerel / genel IP / DNS | getifaddrs · HTTPS sorgusu. **Genel IP varsayılan kapalı** (gizlilik) | Düşük |
| Gecikme / jitter | ICMP `SOCK_DGRAM` ping (root gerektirmez) | Düşük |
| Süreç başına trafik | `nettop -P -L 1 -J bytes_in,bytes_out` | Orta |

### Batarya / Bluetooth / Saat
| Metrik | Kaynak | Zorluk |
|---|---|---|
| Yüzde / durum / kalan süre | IOPSCopyPowerSourcesInfo | Düşük |
| Sağlık / döngü / sıcaklık / voltaj | AppleSmartBattery IORegistry düğümü | Düşük |
| Adaptör (Watt) | IOPSCopyExternalPowerAdapterDetails | Düşük |
| Eşleşmiş BT cihazları | `IOBluetoothDevice.pairedDevices()` (deprecated ama alternatifi yok) | Orta |
| AirPods pil (sol/sağ/kutu) | `system_profiler SPBluetoothDataType -json` | Orta |
| Çoklu saat dilimi + NTP | DateFormatter + TimeZone · özel SNTP/UDP istemcisi | Düşük |

---

## Fazlar

Her fazın sonunda çalışan, denenebilir bir uygulama var. Kabul ölçütü tutmadan sonraki faza geçilmez.

### Faz 0 — İskelet ve tasarım sistemi · ~1 gün
- Xcode projesi + yerel SPM paketi `SystemKit` + git
- Entitlements: sandbox kapalı, hardened runtime açık, `LSUIElement`
- SwiftUI ana pencere: sol kenar çubuğu (10 modül + Ayarlar), boş detay alanı
- Tek dummy NSStatusItem + boş popover
- `SettingsStore`: `@Observable`, UserDefaults destekli, tip güvenli anahtarlar
- String Catalog (tr+en), tasarım token'ları

**Kabul:** Açılıyor, menü çubuğunda görünüyor, pencere geziliyor, sıfır uyarı ile derleniyor.

### Faz 1 — Örnekleme motoru ve CPU · ~3 gün
En önemli faz; motorun şekli kalan dokuz modülü belirliyor.
- `TimerHub` (1/3/5/10 sn kovaları, tek zamanlayıcı, uyku/uyanmada askıya alma)
- `Sampler` protokolü, `RingBuffer<Double>`, `MetricSnapshot`
- CPU okuyucu: yük, çekirdek topolojisi, ortalama yük, çalışma süresi
- CPU detayı: toplam halka, geçmiş grafiği, çekirdek barları, ortalama yük
- Widget motoru v1 — 3 tür: yüzde metni, mini çizgi grafik, halka
- CPU popover + "Modül" ve "Widget'lar" ayar sekmeleri

**Kabul:** Canlı CPU yüzdesi, Activity Monitor ile ±2 puan; boşta CPU < %0.5.

### Faz 2 — RAM ve süreç listesi · ~2 gün
- Sanal bellek okuyucu, takas, bellek baskısı olay kaynağı
- Ortak `ProcessLister` (CPU+RAM paylaşır, yalnızca popover açıkken)
- RAM detayı: baskı göstergesi, takas halkası, yığılmış çubuk, geçmiş

**Kabul:** Uygulama/Bağlı/Sıkıştırılmış/Serbest, Activity Monitor ile ±200 MB.

### Faz 3 — GPU ve IOReport köprüsü · ~2 gün
- `IOReportBridge`: dlopen ile isteğe bağlı yükleme, sembol yoksa zarif düşüş
- IOAccelerator istatistikleri, ANE, FPS doğrulaması
- GPU detayı: 4 kullanım grafiği + FPS geçmişi
- Faz 1'in CPU frekans alanı geriye dönük tamamlanır

**Kabul:** Metal yükü altında değerler hareket ediyor; IOReport devre dışıyken çökme yok.

### Faz 4 — Disk ve Ağ · ~3 gün
- Disk: birim keşfi, kapasite, okuma/yazma hızı, SMART denemesi + "Bilinmeyen" düşüşü
- Ağ: arayüz hızı, birincil arayüz takibi, Wi-Fi, gecikme/jitter
- Bağlantı geçmişi ızgara grafiği; genel IP varsayılan kapalı

**Kabul:** Hız testi sırasında değerler Activity Monitor ağ sekmesiyle uyuşuyor.

### Faz 5 — Sensörler · ~4 gün
Projenin en belirsiz kısmı. Ayrı bir keşif adımıyla başlar: önce cihazdaki tüm sensörler dökülür, sonra kataloglanır.
- HID sensör okuyucu (sıcaklık/voltaj/akım) + SMC okuyucu (fan)
- Sensör kataloğu: ham ad → yerelleştirilmiş ad; eşleşme yoksa ham ad
- Türetilmiş sensörler
- Gruplu liste (Fanlar/Sıcaklık/Voltaj/Akım/Güç/Enerji), tek tek aç-kapa
- Sensör yığın widget'ı (iki satırlı kompakt)

**Kabul:** Sensörlerin ≥%90'ı adlandırılmış listeleniyor, yük altında yükseliyor.

### Faz 6 — Batarya, Bluetooth, Saat · ~2 gün
- Batarya: yüzde/süre/sağlık/döngü/adaptör, ikon+metin widget'ı, XL boyut
- Bluetooth: cihazlar + pil seviyeleri, boş durum metni
- Saat: çoklu dilim, özel biçim, NTP, takvim popover'ı

**Kabul:** Pil yüzdesi/süresi sistem menüsüyle birebir; AirPods pili görünüyor.

### Faz 7 — Bildirimler, gösterge paneli, genel ayarlar · ~2 gün
- Eşik motoru: sınır + **histerezis + soğuma süresi** (spam engeli)
- Gösterge paneli: cihaz kartı, donanım satırları, seri no, çalışma süresi
- Genel ayarlar: `SMAppService` ile başlangıçta çalıştır, Dock'ta göster, sıcaklık birimi, ayar dışa/içe aktar/sıfırla

**Kabul:** Eşik aşımında tek bildirim; sınır etrafında salınırken tekrar gelmiyor.

### Faz 8 — Widget setinin genişletilmesi · ~2 gün
- Yeni türler: bar grafik, batarya, ağ okları, çift satırlı sensör yığını, hız grafiği
- Widget ayarları: hizalama, sabit genişlik, eşit aralıklı font, renklendirme, ekran modu
- **Kombine modüller** (birden fazla modül tek öğede)
- Öğe konumunun oturumlar arası korunması

**Kabul:** Yeniden başlatmada aynı sıra; kırpılma/titreme yok.

### Faz 9 — Fan kontrolü (opsiyonel) · ~3 gün
Donanıma yazma içerir. Ayrı karar noktası — atlanabilir.
- `SMAppService.daemon` ayrıcalıklı yardımcı + XPC
- SMC yazma: mod anahtarı + hedef RPM
- Güvenlik: donanım min/max kelepçeleme, çıkışta otomatik moda dönüş, watchdog

**Kabul:** Elle hız uygulanıyor; zorla sonlandırmada fan 30 sn içinde otomatik moda dönüyor.

### Faz 10 — Cila ve dağıtım · ~2 gün
- Instruments performans profili, enerji etkisi
- Uyku/uyanma, ekran kapanması, hızlı kullanıcı değişimi, harici ekran
- İkon, hakkında ekranı, isim kararı
- Developer ID + notarization + DMG, Sparkle otomatik güncelleme
- GitHub deposu, çift dilli README, ekran görüntüleri

**Kabul:** Temiz Mac'te açılıyor, Gatekeeper uyarısı yok, 24 saat kesintisiz çalışıyor.

---

## Risk kaydı

Risklerin çoğu "kod yanlış" değil, "Apple bu veriyi vermiyor" biçiminde.
Ortak azaltma stratejisi: **eksik veri arayüzden kaybolur, uygulamayı düşürmez.**

| Risk | Etki | Azaltma |
|---|---|---|
| IOReport belgelenmemiş | macOS güncellemesi frekans/ANE/güç metriklerini bozabilir | dlopen; sembol yoksa alanlar gizlenir |
| Sensör adları modele özgü | Başka Mac'te liste boş/anlamsız | Eşleşmezse ham ad; "bilinmeyen sensörleri göster" anahtarı |
| AS dahili NVMe'de SMART kapalı | Disk sağlığı okunamaz | "Bilinmeyen"; harici disklerde denemeye devam |
| Wi-Fi için konum izni | Ağ adı boş | Bağlam içinde bir kez iste; reddedilirse sinyal/hız göster, tekrar sorma |
| SMC yazma donanımı etkiler | Yanlış fan değeri → aşırı ısınma | Faz 9 opsiyonel + varsayılan kapalı, kelepçeleme, çıkışta otomatik mod |
| Alt süreç çağrıları | Uygulama kendi CPU tüketiminin kaynağı olur | Yalnızca popover açıkken, 3–5 sn, önbellekli |
| Menü çubuğunda 10 öğe | Çentikli MacBook'ta yer kalmaz | Varsayılan 3 modül açık; Faz 8 kombine modüller |

---

## Performans bütçesi

| Hedef | Değer | Koşul |
|---|---|---|
| Boşta CPU | < %0.5 | Tüm modüller açık, popover kapalı |
| Popover açıkken | < %2 | Süreç listesi dahil |
| Bellek | < 60 MB | Halka tamponlar dahil |
| Disk yazma | 0 | Ayarlar hariç, çalışma sırasında |

**Kurallar**
- Modül başına zamanlayıcı **yok** — dört kova, dört zamanlayıcı
- Menü çubuğunda SwiftUI yok; widget'lar yalnızca değer değişince yeniden çizilir
- Ekran uykudayken / kapak kapalıyken örnekleme durur
- Pahalı örnekleyiciler (süreç listesi, Bluetooth, genel IP) yalnızca görünürken
- Örnekleme arka plan kuyruğunda; ana iş parçacığına hazır anlık görüntü gider

---

## Tasarım dili

Stats'in bilgi mimarisi, kendi görünüşü. Referans dünya: enstrüman panelleri ve telemetri ekranları.

Palet: Mürekkep `#101619` · Yüzey `#151D21` · Sinyal `#0B6E78` · Serin `#2F6FA8` · Ilık `#9A6A0B` · Sıcak `#A93B27`

| Öğe | Karar |
|---|---|
| Vurgu | Tek teal sinyal rengi. Modül başına farklı renk **yok** — renk yalnızca durum taşır |
| Termal şerit | Serin→ılık→sıcak sadece sıcaklık ve eşik aşımı için, vurgudan ayrı dil |
| Sayılar | SF Mono, tabular figürler. Değer değişirken rakamlar yerinden oynamaz |
| Etiketler | Küçük, büyük harf, harf aralığı açık mono — ölçü aleti hissi |
| Kartlar | Yumuşak köşe, ince kenarlık, hafif gölge. **Döndürme/eğim yok** |
| Grafikler | Alan dolgusu + soluk ızgara + vurgulu son nokta. Animasyonlu geçiş yok |
| Menü çubuğu | `NSColor.labelColor` — koyu/açık menü çubuğuna kendiliğinden uyar |
| Aydınlık tema | Karanlık kadar özenli; ters çevirme değil, ayrı kalibre palet |

---

## Sıradaki adım

Faz 0 bir gün sürer, sonunda gezilebilir ama boş bir uygulama olur. Başlamadan önce:

1. **İsim** — Faz 10'a kadar bekleyebilir, ama bundle identifier Faz 0'da belirleniyor.
2. **Faz 5 keşfi** — Sensör modülüne başlamadan önce Mac'teki tüm HID/SMC sensörlerini döken küçük bir CLI aracı yazalım; kataloğu tahminle değil gerçek çıktıyla kuralım.
3. **Faz 9 kararı** — Fan kontrolünü şimdiden eleyip planı 10 faza indirmek de seçenek; sonraya bırakmanın maliyeti yok.
