# Sistem Monitörü — Yapı Planı v2

Stats eşdeğeri, **pil ve bellek dostu** macOS sistem izleyicisi.
v2: 2026-10-03 · v1'in yerine geçer (`PLAN-v1.md` arşiv).
v2.1: 2026-10-03 · Faz 1 keşif sonuçlarıyla düzeltildi (§1-b, `Tools/discovery/BULGULAR.md`).

Ortam (doğrulandı): macOS 27.0 (26A428) · Xcode 27.0 · Swift 6.4 · Mac17,8 Apple M5 Pro
(6 Super + 12 Performance çekirdek, **verimlilik çekirdeği yok**) · 48 GB · 2 fan
Hedef: macOS 26.0+ (SDK 27). Tahmin: ~27–32 çalışma günü.

---

## 1. v1'deki hatalar — bu Mac üzerinde ölçülerek bulundu

Prob kaynağı: `Tools/probe/probe.c`

| # | v1 ne diyordu | Gerçek | Düzeltme |
|---|---|---|---|
| 1 | macOS 26 / Xcode 26.6 / Swift 6.3 | macOS 27 / Xcode 27 / Swift 6.4 | Hedef 26.0 kalır, SDK 27 |
| 2 | "IOReport.framework" | Framework yok. `/usr/lib/libIOReport.dylib` — diskte dosya da yok (dyld paylaşımlı önbelleği) ama `dlopen` **çalışıyor**. Energy Model 364, CPU Stats 130, GPU Stats 140 kanal | Yol düzeltildi. ANE grubu "H11ANE" değil → adı keşifte bulunacak |
| 3 | "Sensör adları HID'den gelir (CPU performance core 7…)" | HID'de 77 sıcaklık servisi var ama adları `PMU tdie5`, `PMU tdev1`, `gas gauge battery`. "CPU performance core 1" Stats'in **kendi eşlemesi** | Eşleme tablosu keşif çıktısından elle kurulur |
| 4 | — | Bazı `tdev` sensörleri **−9200 °C** döndürüyor | Geçerlilik filtresi zorunlu (−40…+150 °C dışı atılır) |
| 5 | SMC sıcaklık anahtarları (Tp01, Tg0f) | M5'te **yok** (M1/M2 dönemi anahtarları) | Sıcaklık yalnızca HID'den; SMC yalnız fan ve güç |
| 6 | Fan yazma: `FS!` | `FS!`, `F0Md`, `Ftst` **hiçbiri yok**. Okuma çalışıyor: FNum=2, F0Mn=1350, F0Mx=5349 rpm, PSTR=21.6 W | Fan kontrolü riski yükseldi; yazma anahtarları keşifte bulunmazsa faz iptal |
| 7 | "P çekirdek / E çekirdek" | `hw.perflevel0` = **Super** (6), `perflevel1` = **Performance** (12). E çekirdek yok | Hiçbir kod sınıf sayısını/adını varsaymaz; frekanstaki voltage-states indeksleri çipe özgü |
| 8 | Üst süreçler: `ps -r` pcpu, rss | `ps` %CPU çürüyen ortalama (Activity Monitor'le tutmaz); rss ≠ Activity Monitor "Bellek" (`phys_footprint`). libproc 886 sürecin 564'ünü okuyor, 322 root süreci EPERM. `ps` **setuid root** olduğu için hepsini görüyor | Hibrit: libproc (ucuz, kendi kullanıcı) + `ps -o time` deltası (root süreçler, yalnız liste görünürken) |
| 9 | RAM formülü "kalibre edilecek" | Formül biliniyor | Uygulama = internal − purgeable · Bağlı = wire · Sıkıştırılmış = compressor_page_count · Kullanılan = üçünün toplamı · Önbellek = external + purgeable |
| 10 | SCNetworkReachability | macOS 14.4'te deprecated | `NWPathMonitor` (olay tabanlı) |
| 11 | 1/3/5/10 sn için 4 ayrı zamanlayıcı | 4 ayrı uyanma kaynağı = pil kaybı | Tek temel tick + %20 tolerans (bkz. §3) |
| 12 | Ping ve genel IP periyodik | Wi-Fi radyosunu uyandırır, pil yer | Varsayılan kapalı, olay tabanlı |
| 13 | Bluetooth: `system_profiler` | Ölçüldü: 0.17 sn, 60 M komut, 9 MB **her çağrıda** | Yalnızca popover açıkken, 60 sn'de bir |
| 14 | Performans bütçesi vardı, ölçüm yoktu | Ölçülmeyen bütçe tutmaz | Yerleşik öz-izleme + `scripts/perf-check.sh`, her faz kapısında |
| 15 | `host_processor_info` | Dönen dizi `vm_deallocate` edilmezse **her tick sızar** (Stats-türü uygulamalardaki klasik sızıntı) | Okuyucu testine sızıntı kontrolü |
| 16 | Developer ID + notarization varsayıldı | Ücretli Apple Developer hesabı ister; fan daemon'u da imza ister | Açık soru (§8) |
| 17 | Teal vurgu, gölgeli kartlar | Ozan: klasik siyah, kırık beyaz, mavi; gradyan yok | §6 yeniden yazıldı |

### 1-b. v2'deki hatalar — Faz 1 keşfiyle bulundu

v2'nin kendi ölçümü de eksikti: yalnızca M1 dönemi anahtar adlarını denemişti.

| v2 ne diyordu | Keşif ne gösterdi | Sonuç |
|---|---|---|
| "SMC'de sıcaklık yok, yalnızca HID" | SMC'de **256 sıcaklık anahtarı** var (`Tp??` Super, `Tm??` Performance, `Tg??` GPU — yük testiyle eşlendi) | Sıcaklık birincil kaynağı **SMC** |
| HID sıcaklığı ucuz | HID sensör başına **~1 ms** (77 sensör 75 ms); SMC anahtarı **0.22 ms** | HID yalnızca SMC'de olmayan sensörler için |
| "Fan yazma anahtarı yok" | **`F0md`** (küçük harf) ve **`F0Tg`** var, yazılabilir işaretli | Fan kontrolü mümkün; Developer hesabına bağlı |
| CPU/GPU/ANE gücü IOReport Energy Model'den | CPU kanalları root olmadan hep 0. CPU gücü SMC **`PPMC`**, GPU gücü IOReport **`GPU Energy`** | Kaynaklar ayrıldı |
| ANE kullanımı IOReport'tan | Kullanım kanalı yok; yalnızca `ANE0` enerji | ANE yüzdesi yerine ANE gücü |
| `…X` anahtarı tahmini | `TPDX/TRDX/TUDX` grubun en yükseği — 4 fazda doğrulandı | "En sıcak" tek okumayla |
| IOReport `PCPU` = Performance | `PCPU` = **Super**, `MCPU0/1` = **Performance** | Eşleme tablosu donanımdan, isimden değil |

Referans: Ozan'ın ekran görüntüsünde Stats **298.5 MB RAM** ve **%2.9 CPU** kullanıyordu. Hedefimiz bunun ~10'da biri.

---

## 2. Sabitlenmiş kararlar

| Konu | Karar |
|---|---|
| Kapsam | 10 modül: Gösterge paneli, CPU, GPU, RAM, Disk, Sensörler, Ağ, Batarya, Bluetooth, Saat. Remote yok |
| Arayüz | Modül başına NSStatusItem + popover + sol kenar çubuklu pencere |
| Dağıtım | Sandbox kapalı, GitHub. App Store hedef değil |
| Render | Menü çubuğu AppKit (CALayer/CoreGraphics), pencere ve popover SwiftUI (Canvas, Swift Charts yok) |
| Veri | Yalnızca bellek, Float32 halka tampon. Diske yazma yok |
| Dil | Türkçe + İngilizce String Catalog, varsayılan Türkçe |
| **Öncelik** | **Pil ve bellek tüketimi özellikten önce gelir.** Bütçeyi aşan özellik varsayılan kapalı gelir |

---

## 3. Enerji ve bellek mimarisi

### Bütçe (M5 Pro, pilde, ölçülerek)

| Durum | CPU (tek çekirdek %) | Uyanma/sn | Bellek (phys_footprint) |
|---|---|---|---|
| Boşta: pencereler kapalı, 3 menübar widget'ı, 2 sn aralık | < 0.3 | < 2 | < 35 MB |
| Bir popover açık | < 1.5 | < 4 | < 50 MB |
| Ana pencere ön planda, grafikler canlı | < 4 | < 10 | < 80 MB |
| 24 saat boşta koşu sonrası bellek büyümesi | — | — | < 5 MB |
| Disk yazma (ayarlar hariç) | 0 | | |
| Varsayılan ayarlarla dış ağ isteği | 0 | | |

Activity Monitor "Enerji Etkisi" boşta < 1.0, 12 saatlik sütunda ilk 25'te yer almamalı.

### A. Zamanlama — ne zaman uyanıyoruz
- **Tek** `DispatchSourceTimer`; temel tick = kullanıcı aralığı (varsayılan 2 sn), **leeway %20** → çekirdek bizim uyanmamızı diğer süreçlerinkiyle birleştirir.
- Örnekleyiciler tick'in katlarında çalışır: CPU/RAM her tick, disk/ağ 1 tick, sensörler 2 tick, batarya 15 tick, Bluetooth 30 tick.
- **Talep sayacı (DemandRegistry):** her metrik "kimin ihtiyacı var" sayar — menübar widget'ı, açık popover, görünür pencere bölümü, bildirim eşiği. Tüketicisi olmayan metrik **hiç okunmaz.** Yalnızca bildirim için izlenen metrik 10 sn'ye düşer.
- **Tamamen duraklat:** sistem uykusu, ekran uykusu, ekran kilidi, oturum pasif (hızlı kullanıcı değişimi). Uyanınca ilk örnek atılır (delta bozuk).
- **PowerPolicy:** Düşük Güç Modu veya pil < %20 → aralık ×2; `thermalState ≥ .serious` → ×2; prizdeyken kullanıcı isterse 1 sn.
- Örnekleme kuyruğu QoS `.utility`. `.userInteractive` hiçbir yerde yok. App Nap'i kapatan `beginActivity` yok.

### B. Okuma maliyeti
- IOKit servisleri, HID servis istemcileri, SMC bağlantısı ve IOReport aboneliği **bir kez** açılıp önbelleklenir. Her tick'te yeniden eşleme yok. Disk tak/çıkar gibi değişiklikler `IOServiceAddMatchingNotification` ile gelir.
- **Sıcaklık okuma bütçesi (ölçüldü):** SMC anahtarı 0.22 ms, HID sensörü ~1 ms. Menü çubuğu sıcaklığı tek bir `…X` toplu anahtarından gelir (≈0.3 ms/okuma). Tüm sensör listesi (~256 anahtar ≈ 75 ms) yalnızca Sensörler sayfası görünürken okunur.
- **Fork bütçesi:** varsayılan yapılandırmada saniyede **0** alt süreç. `ps` yalnız süreç listesi görünürken 3 sn'de bir (~30 ms sistem zamanı ölçüldü). `nettop` varsayılan kapalı. `system_profiler` yalnız popover açıkken 60 sn'de bir.
- Bellek yönetimi kuralları: `host_processor_info` → `vm_deallocate`; IOReport/HID `Copy`/`Create` dönüşleri `takeRetainedValue`; okuyucu birim testleri 10 000 tick sonrası footprint'i kontrol eder.

### C. Çizim maliyeti
- Menübar: biçimlendirilmiş metin veya piksel değişmediyse **yeniden çizim yok** (%5 → %5 = 0 iş). Değerler gösterim hassasiyetine yuvarlanıp karşılaştırılır.
- Mini çizgi grafik: yeni nokta gelince tüm yolu yeniden kurmak yerine bitmap 1 px kaydırılıp son sütun çizilir.
- SwiftUI: halka tamponlar `@Observable` **değil**. Görünür görünüm kendi zamanında anlık görüntü çeker → gözlem fırtınası yok.
- `NSWindow.occlusionState` görünür değilse (arkada, küçültülmüş, başka Space) pencere güncellemesi durur.
- Değer geçişlerinde animasyon yok — tasarım kararı aynı zamanda enerji kararı.

### D. Bellek
- Halka tampon `Float32`, sabit kapasite 300 → metrik başına 1.2 KB; ~150 metrik ≈ 180 KB. Tick içinde bellek ayırma yok.
- Pencere kapanınca SwiftUI hiyerarşisi bırakılır (hosting controller yok edilir). Popover içeriği her açılışta kurulur, kapanınca atılır.
- Cihaz görseli, uygulama ikonları tembel yüklenir; ikon önbelleği `NSCache` 64 öğe.
- Sızıntı kapısı: her faz sonunda `leaks` + 1 saatlik footprint eğrisi.

### E. Ağ ve radyo
- Genel IP varsayılan kapalı; açıksa yalnız `NWPathMonitor` ağ değişikliği bildirdiğinde.
- Gecikme/jitter varsayılan kapalı; açıksa 60 sn, pilde kapalı.
- Güncelleme kontrolü günde bir.

### F. Ölçüm — kendini kendi aracıyla izler
- Gizli **Tanılama** paneli (⌥ tıklama): kendi CPU %, `phys_footprint`, uyanma/sn (`ri_pkg_idle_wkups + ri_interrupt_wkups` deltası), güç (`ri_energy_nj` deltası → mW), saniyedeki fork sayısı, aktif örnekleyiciler.
- `scripts/perf-check.sh`: uygulamayı 10 dk boşta çalıştırır, `proc_pid_rusage` ile ölçer, bütçe aşılırsa başarısız döner. **Her fazın kabul kapısı.**
- Yan kazanç: `ri_energy_nj` kendi kullanıcı süreçleri için de okunuyor → üst süreç listesinde Activity Monitor'deki gibi **Enerji** sütunu.

---

## 4. Mimari

```
sistem/
├─ Sistem.xcodeproj
├─ App/                    AppDelegate · StatusBarController · WindowController · Popover
├─ Packages/SystemKit/     UI'sız, test edilebilir çekirdek
│   ├─ Readers/            MachHost · Sysctl · IOKit · IOReport(dlopen) · SMC · HIDSensors
│   │                      DiskArbitration · NetIf · PowerSources · ProcessLister
│   ├─ Sampling/           TickClock · DemandRegistry · PowerPolicy · RingBuffer<Float>
│   └─ Model/              ModuleID · MetricID · Snapshot (Sendable)
├─ Packages/SistemUI/      Tasarım token'ları · Canvas grafikleri · halka · çubuk · liste satırı
├─ Tools/probe/            Keşif aracı (Faz 1)
├─ Tools/discovery/        Mac17,8.json — gerçek sensör/anahtar dökümü
└─ scripts/perf-check.sh
```

Akış: `Readers` → `Sampling` (tek seri yürütücü) → `Snapshot` → MainActor `MetricStore` → AppKit menübar + SwiftUI.

Swift 6 eşzamanlılığı: IOKit/HID/SMC tanıtıcıları `Sendable` değil → tüm okuyucular özel seri yürütücülü **tek bir `SamplerActor`**'a hapsedilir. Dışarıya yalnızca değer tipli `Snapshot` çıkar.

---

## 5. Veri kaynakları

✓ = 2026-10-03'te bu Mac'te doğrulandı.

### Gösterge paneli
| Metrik | Kaynak | Risk |
|---|---|---|
| Model, çip, bellek | `hw.model`, `machdep.cpu.brand_string`, `hw.memsize` ✓ | Düşük |
| Pazarlama adı | `system_profiler SPHardwareDataType` — **bir kez**, sonuç bellekte | Düşük |
| Cihaz görseli | `UTType(tag: "Mac17,8", tagClass: "com.apple.device-model-code")` → `NSWorkspace.icon(for:)`; olmazsa SF Symbol | Orta |
| Çekirdek sınıfları | `hw.nperflevels`, `hw.perflevelN.name/physicalcpu` ✓ (Super 6, Performance 12) | Düşük |
| Seri no, çalışma süresi | IOPlatformExpertDevice, `kern.boottime` | Düşük |

### CPU
| Metrik | Kaynak | Risk |
|---|---|---|
| Toplam / çekirdek başına yük | `host_processor_info` tick deltası (+ `vm_deallocate`) | Düşük |
| Ortalama yük | `getloadavg()` | Düşük |
| Frekans | IOReport `CPU Core Performance States` ✓ (durumlar `V0P14…V14P0`) × IORegistry frekans tablosu; `PCPU`=Super, `MCPU`=Performance | Orta |
| Üst süreçler | libproc `proc_pid_rusage` (564/886 ✓) + `ps -Ao pid,time,comm` deltası (root süreçler) | Orta |

### GPU
| Metrik | Kaynak | Risk |
|---|---|---|
| Kullanım / render / tiler / bellek | IOAccelerator `PerformanceStatistics` ✓ (Device/Renderer/Tiler Utilization %, In use system memory) | Düşük |
| ANE kullanımı | Kanal **yok** ✓ → yerine ANE gücü gösterilir | — |
| GPU gücü | IOReport `Energy Model / GPU Energy` ✓ | Düşük |
| FPS | Aday: IOReport `DCP / display stats / frame_count` — 241/sn ölçüldü, 120 Hz ekranda anlamsız → doğrulanmadı. Faz 4'te `swap/subframes` denenir, olmazsa çıkar | Yüksek |

### RAM
| Metrik | Kaynak | Risk |
|---|---|---|
| Uygulama / bağlı / sıkıştırılmış / önbellek | `host_statistics64(HOST_VM_INFO64)` + §1-9 formülü | Düşük |
| Takas | `vm.swapusage` ✓ | Düşük |
| Bellek baskısı | `DispatchSource.makeMemoryPressureSource` (olay) + `kern.memorystatus_vm_pressure_level` ✓ | Düşük |
| Süreç belleği | `ri_phys_footprint` (Activity Monitor ile aynı), root süreçler için rss | Orta |

### Disk
| Metrik | Kaynak | Risk |
|---|---|---|
| Birimler, kapasite | `volumeAvailableCapacityForImportantUsage` + DiskArbitration | Düşük |
| Okuma/yazma hızı | IOBlockStorageDriver `Statistics` deltası | Düşük |
| SMART | IONVMeSMARTUserClient — dahili diskte büyük olasılıkla kapalı | Yüksek |

### Sensörler
| Metrik | Kaynak | Risk |
|---|---|---|
| Sıcaklıklar | **SMC** `Tp??` (Super) · `Tm??` (Performance) · `Tg??` (GPU) · `…X` toplu en yüksek ✓ (yük testiyle eşlendi). HID yalnızca yedek (sensör başına ~1 ms) | Düşük |
| Fan RPM / min / maks | SMC `FNum`, `F{n}Ac/Mn/Mx` ✓ | Düşük |
| Sistem gücü | SMC `PSTR` ✓ | Düşük |
| CPU gücü | SMC `PPMC` ✓ (1.3 W boşta → 26.8 W yükte) | Düşük |
| GPU gücü | IOReport `GPU Energy` (nJ) ✓ (29 W yükte) | Orta |
| ANE gücü | IOReport `ANE0` — ANE yükünde doğrulanacak | Orta |
| Voltaj / akım | HID 0xFF00/6–8 + AppleSmartBattery | Orta |
| Türetilmiş (ort./en sıcak) | hesap | Düşük |

### Ağ
| Metrik | Kaynak | Risk |
|---|---|---|
| Hız | `getifaddrs` AF_LINK `if_data` deltası | Düşük |
| Bağlantı / arayüz değişimi | `NWPathMonitor` (olay) | Düşük |
| Wi-Fi adı / sinyal | CoreWLAN — ad için Konum izni | Orta |
| Genel IP / gecikme | varsayılan kapalı (§3-E) | Düşük |
| Süreç başına trafik | `nettop` — varsayılan kapalı | Orta |

### Batarya · Bluetooth · Saat
| Metrik | Kaynak | Risk |
|---|---|---|
| Yüzde, süre, durum | `IOPSCopyPowerSourcesInfo` + `IOPSNotificationCreateRunLoopSource` (olay, polling yok) | Düşük |
| Sağlık, döngü, voltaj, akım | AppleSmartBattery ✓ (CycleCount, DesignCapacity, NominalChargeCapacity, InstantAmperage, PowerTelemetryData) | Düşük |
| Adaptör | `AdapterDetails` ✓ | Düşük |
| Bluetooth cihazlar + pil | `IOBluetoothDevice.pairedDevices()` + `system_profiler` 60 sn (yalnız görünürken). IORegistry'de BatteryPercent anahtarı yok ✓ | Orta |
| Saat, NTP | DateFormatter; SNTP yalnız istek üzerine | Düşük |

---

## 6. Tasarım dili

Klasik siyah ve kırık beyaz; tek vurgu mavi. Gradyan yok, parlama yok, gölge neredeyse yok.

| Token | Koyu tema | Açık tema |
|---|---|---|
| Zemin | `#141416` yumuşak siyah | `#F6F5F2` kırık beyaz |
| Yüzey (kart) | `#1C1C1F` | `#FCFBF9` |
| Yüzey 2 (satır/hover) | `#242428` | `#EFEEEA` |
| Çizgi | `#2E2E33` | `#E2E0DB` |
| Metin | `#ECECEE` | `#1B1B1E` |
| İkincil metin | `#9C9CA4` | `#6C6C73` |
| Vurgu mavi | `#5E9BF2` | `#2F6FD3` |
| Mavi yumuşak (dolgu) | `#5E9BF2` %22 | `#2F6FD3` %14 |
| İyi / Uyarı / Kritik | `#5DBB82` / `#E0B04E` / `#E2685A` | `#2F8F57` / `#B07C14` / `#C0473A` |

- Saf siyah `#000` ve saf beyaz `#FFF` hiçbir yerde kullanılmaz.
- Veri serileri mavinin tonları + nötr gri (ör. CPU kullanıcı = mavi, sistem = açık mavi, boşta = gri). Kırmızı/sarı yalnızca durum ve eşik için.
- Grafikler: düz mavi çizgi + %22 düz dolgu (gradyan dolgu yok) + soluk ızgara + vurgulu son nokta.
- Sayılar SF Mono / tabular rakam; etiketler SF Pro. Kartlar 10 pt köşe, 1 px çizgi, gölge yok; döndürme/eğim yok.
- Menübar tek renk (`labelColor`), mavi yalnızca popover ve pencerede.
- Açık tema ters çevirme değil, ayrı kalibre edilmiş palet.

---

## 7. Fazlar

Her fazın iki kapısı var: **doğruluk** (Activity Monitor/sistemle karşılaştırma) ve **enerji/bellek** (`perf-check.sh` bütçe içinde). Biri tutmazsa sonraki faza geçilmez.

### Faz 0 — İskelet, tasarım sistemi, ölçüm altyapısı · ~1.5 gün
- Xcode projesi, `SystemKit` ve `SistemUI` yerel paketleri, git deposu
- Sandbox kapalı, hardened runtime, `LSUIElement`; bundle id geçici `com.ozan.sistem`
- SwiftUI pencere: kenar çubuğu (10 modül + Ayarlar), boş detay alanları, koyu/açık tema token'ları
- Tek NSStatusItem + boş popover
- `SettingsStore` (UserDefaults, tip güvenli anahtarlar), String Catalog tr+en
- **Ölçüm önce gelir:** Tanılama paneli iskeleti (kendi CPU/footprint/uyanma/enerji) + `scripts/perf-check.sh`

Kapı: sıfır uyarıyla derleniyor; boşta < %0.1 CPU, < 25 MB.

### Faz 1 — Keşif aracı · ~1 gün · ✅ 2026-10-03
v1'de Faz 5'in başındaydı; tüm riskli fazları besledigi için öne alındı.
- `Tools/probe`'u Swift CLI'a çevir: tüm HID sensörleri (ad, sayfa/kullanım, değer, geçerli mi), tüm SMC anahtarları (`#KEY` sayısı + indeksle okuma, tip, değer), IOReport grup/alt grup/kanal listesi, libproc kapsamı
- Çıktı: `Tools/discovery/Mac17,8.json`
- Hedefli aramalar: ANE IOReport grubu, fan mod/hedef yazma anahtarları, GPU FPS kaynağı, sıcaklık sensörü → çekirdek eşlemesi (yük altında hangi `tdie` ısınıyor)

Kapı: JSON üretildi; ANE, fan yazma ve FPS için "var / yok" kararı verildi; Faz 10'un yapılıp yapılmayacağı netleşti.

Sonuç: `Tools/discovery/BULGULAR.md`. SMC sıcaklıkları eşlendi, fan yazma anahtarları bulundu (`F0md`/`F0Tg`), ANE kullanımı yok (güç var), FPS doğrulanmadı.

### Faz 2 — Örnekleme motoru ve CPU · ~3 gün
- `TickClock` (tek zamanlayıcı, tolerans, çarpanlar), `DemandRegistry`, `PowerPolicy`, uyku/kilit/oturum duraklatma
- `SamplerActor`, `RingBuffer<Float>`, `Snapshot`, MainActor `MetricStore`
- CPU okuyucu (çekirdek sınıflarını dinamik okur), ortalama yük
- Widget motoru v1 (CALayer): yüzde metni, mini çizgi grafik, halka — değişmezse çizmez
- CPU popover + detay sayfası + "Modül" ve "Widget'lar" ayar sekmeleri

Kapı: CPU % Activity Monitor ile ±2 puan; boşta < %0.3 CPU, < 2 uyanma/sn; ekran kilitlenince uyanma ≈ 0.

### Faz 3 — RAM ve süreç listesi · ~2 gün
- VM okuyucu (§1-9 formülü), takas, bellek baskısı olay kaynağı
- `ProcessLister`: libproc + `ps` hibriti, CPU zamanı deltası, footprint, enerji sütunu; yalnız görünürken
- RAM detayı ve popover

Kapı: Uygulama/Bağlı/Sıkıştırılmış Activity Monitor ile ±100 MB; süreç %CPU'su Activity Monitor ile tutarlı; popover açıkken < %1.5.

### Faz 4 — GPU ve IOReport köprüsü · ~2.5 gün
- `IOReportBridge`: `dlopen` + `dlsym`, abonelik bir kez, örnek deltası, sembol yoksa zarif düşüş
- GPU kullanım/render/tiler/bellek, ANE (keşif sonucuna göre), GPU/ANE gücü
- CPU frekansı geriye dönük tamamlanır

Kapı: Metal yükünde değerler hareket ediyor; IOReport yokken çökme yok; 1 saat koşuda footprint büyümesi < 1 MB.

### Faz 5 — Disk ve Ağ · ~3 gün
- Disk: birimler, kapasite, okuma/yazma hızı, tak/çıkar bildirimi, SMART denemesi
- Ağ: `getifaddrs` hız, `NWPathMonitor`, CoreWLAN (Konum izni akışı), bağlantı geçmişi; genel IP ve gecikme varsayılan kapalı

Kapı: hız testi değerleri Activity Monitor ile uyumlu; varsayılan ayarlarla dış ağ isteği 0.

### Faz 6 — Sensörler · ~3.5 gün
- SMC okuyucu birincil: `Tp/Tm/Tg` grupları, `…X` toplu anahtarlar, fanlar, `PSTR/PDTR/PPMC`; HID yalnızca SMC'de olmayanlar için
- Eşleme tablosu `Mac17,8.json`'dan; bilinmeyen model → ham ad
- Türetilmiş sensörler, gruplu liste (Fanlar · Sıcaklık · Voltaj · Akım · Güç · Enerji)
- İki satırlı sensör yığını widget'ı

Kapı: geçerli sensörlerin tamamı listeleniyor, −9200 °C gibi çöp değer yok; sensör modülü açıkken boşta < %0.4.

### Faz 7 — Batarya, Bluetooth, Saat · ~2 gün
- Batarya: `IOPSNotification` ile olay tabanlı; sağlık, döngü, adaptör, anlık güç; batarya widget'ı
- Bluetooth: cihazlar + pil, 60 sn, yalnız görünürken
- Saat: çoklu dilim, özel biçim, takvim popover'ı, isteğe bağlı NTP

Kapı: pil yüzdesi/süresi sistemle birebir; Bluetooth popover kapalıyken `system_profiler` çağrısı 0.

### Faz 8 — Bildirimler, gösterge paneli, genel ayarlar · ~2 gün
- Eşik motoru: histerezis + soğuma süresi; eşik metrikleri DemandRegistry'ye düşük frekanslı tüketici olarak kaydolur
- Gösterge paneli (cihaz görseli, donanım satırları)
- Genel ayarlar: başlangıçta çalıştır (`SMAppService.mainApp`), Dock'ta göster, sıcaklık birimi, **güç profili** (Otomatik / Pil tasarrufu / Hassas), ayar dışa/içe aktar/sıfırla

Kapı: eşik aşımında tek bildirim; sınır etrafında salınırken tekrar yok.

### Faz 9 — Widget seti ve kombine modüller · ~2 gün
- Bar grafik, batarya, ağ okları, hız grafiği widget'ları; hizalama, sabit genişlik, eşit aralıklı font
- Kombine modüller (tek NSStatusItem'da birden fazla modül — daha az status item = daha az çizim)
- Öğe konumunun korunması

Kapı: yeniden başlatmada sıra korunuyor; 6 widget açıkken boşta < %0.5.

### Faz 10 — Fan kontrolü (opsiyonel) · ~3 gün
Faz 1'de yazma anahtarları bulundu (`F0md`, `F0Tg`). Root yardımcı imzalı uygulama ister → Developer hesabı geldikten sonra.
- `SMAppService.daemon` + XPC; donanım min/max kelepçeleme; çıkışta ve çökmede otomatik moda dönüş (watchdog)

Kapı: zorla sonlandırmada fan 30 sn içinde otomatiğe dönüyor.

### Faz 11 — Cila ve dağıtım · ~2 gün
- Instruments (Energy Log, Allocations, Leaks); 24 saat boşta koşu
- Uyku/uyanma, harici ekran, Space değişimi, hızlı kullanıcı değişimi senaryoları
- İkon, hakkında ekranı, isim; imza + DMG (+ notarization hesap varsa)
- GitHub deposu, README (tr+en)

Kapı: §3 bütçesinin tamamı tutuyor; 24 saatte bellek büyümesi < 5 MB.

---

## 8. Risk kaydı

| Risk | Azaltma |
|---|---|
| IOReport belgelenmemiş, macOS güncellemesinde bozulabilir | `dlopen`, sembol yoksa metrik gizlenir |
| Sensör eşlemesi modele özgü | Ham ad yedeği; başka Mac için keşif aracı kullanıcıya açık |
| Fan yazmanın davranışı denenmedi (`F0md` değerleri, `Ftst` kilidi gerekmiyor mu) | Faz 10'da önce tek fan, düşük hız, otomatiğe dönüş testiyle |
| Root süreçleri libproc'la okunamıyor | `ps` hibriti, yalnız görünürken |
| FPS kaynağı yok | Keşifte yoksa özellik çıkarılır |
| Çentikli ekranda menübar yeri | Varsayılan 3 widget; kombine modüller |
| Yeni özellik bütçeyi deler | Her faz kapısında `perf-check.sh`; aşan özellik varsayılan kapalı |

---

## 9. Açık sorular

1. **Ücretli Apple Developer hesabı var mı?** Yoksa: ad-hoc imza ile kişisel kullanım sorunsuz, ama notarization ve fan daemon'u olmaz.
2. **İsim** — geçici bundle id `com.ozan.sistem`, sonra değişebilir.
3. **Varsayılan menübar widget'ları** — öneri: CPU, RAM, en sıcak CPU sıcaklığı.
4. **Varsayılan güncelleme aralığı** — öneri: 2 sn (Stats'te 1 sn); pilde otomatik 4 sn.
