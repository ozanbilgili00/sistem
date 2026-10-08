# Keşif bulguları — Mac17,8 (M5 Pro, macOS 27.0)

Kaynak: `sistem-probe` (2026-10-03). Ham veri: `Mac17,8.json` (yük testi dahil), `power-Mac17,8.json`.
Yeniden üretmek: `swift run -c release --package-path Packages/SystemKit sistem-probe Tools/discovery/Mac17,8.json --load`

## Okuma maliyetleri (ölçüldü)

| İşlem | Süre | Not |
|---|---|---|
| SMC tek anahtar | **0.22 ms** | Sıcaklık + güç için birincil kaynak |
| HID 77 sıcaklık sensörü | **71–75 ms** | Sensör başına ~1 ms — SMC'nin ~4 katı |
| HID istemci kurulumu | 6–7 ms | Bir kez |
| SMC 3626 anahtarın tamamı | 1057 ms | Yalnızca keşif |
| IOReport tüm kanallar | 78 ms | Yalnızca keşif |

**Karar:** Sıcaklıklar SMC'den okunur. HID yalnızca SMC'de karşılığı olmayan sensör gerekirse kullanılır.
Menü çubuğu sıcaklığı tek bir toplu anahtardan gelir (≈0.3 ms).

## Çekirdekler

- `hw.perflevel0` = Super (6), `hw.perflevel1` = Performance (12). Verimlilik çekirdeği yok.
- IOReport adlandırması **ters sezgili**: `PCPU0…5` = **Super** çekirdekler, `MCPU00…05` + `MCPU10…15` = **Performance** (iki küme).
  Doğrulama: 6 iş parçacığı `.userInteractive` → yalnızca `PCPU0…5` meşgul oldu.
- DVFS durumları: `DOWN, IDLE, V0P14 … V14P0` (Performance) ve `V0P19 … V19P0` (Super). Frekans tablosu Faz 4'te eşlendi, aşağıda.
- GPU durumları: `OFF, P1 … P15`.

## Sıcaklık (SMC, yük testiyle eşlendi)

Taban → 6 Super çekirdek → 18 çekirdek → GPU, grup ortalaması °C:

| Grup | Anahtar | Taban | 6 çekirdek | 18 çekirdek | GPU | Anlamı |
|---|---|---|---|---|---|---|
| `Tp??` | 23 | 39.9 | **55.6** | 61.9 | 51.1 | Super çekirdekler |
| `Tm??` | 40 | 39.3 | 43.5 | **59.1** | 50.4 | Performance çekirdekleri |
| `Tg??` | 41 | 39.1 | 42.8 | 48.8 | **58.4** | GPU |
| `TPD?` | 16 | 37.4 | 45.6 | 51.5 | 40.7 | CPU kalıbı (≈ HID `PMU tdie`) |
| `TRD?` | 16 | 37.7 | 37.9 | 44.2 | 49.1 | GPU/SoC bölgesi |
| `TUD?` | 16 | 36.3 | 36.2 | 36.9 | 46.6 | GPU bölgesi |
| `TCMb` | 1 | 50.2 | 70.3 | 76.5 | 66.0 | SoC en sıcak nokta |

- `…X` anahtarları (`TPDX`, `TRDX`, `TUDX`) grubun **en yüksek** değeri — 4 fazın 4'ünde birebir doğrulandı. Tek okumayla "en sıcak" verir.
- HID `PMU tdie*` değerleri SMC `TPD*` ile neredeyse aynı (44.4 / 45.6, 50.9 / 51.5) → aynı fiziksel sensörler, SMC yolu ucuz.
- HID `PMU tdev*`'lerin bir kısmı −9200 °C döndürüyor; filtre (`isPlausibleTemperature`) şart.
- Batarya: SMC `TB0T/TB1T/TB2T`, HID `gas gauge battery`. NAND: HID `NAND CH0 temp`.

## Güç

| Ölçüm | Kaynak | Boşta | CPU yükü | GPU yükü |
|---|---|---|---|---|
| Sistem toplamı | SMC `PSTR` | 8.6 W | 39.2 W | 38.5 W |
| Adaptör girişi | SMC `PDTR` | 6.7 W | 45.3 W | 41.2 W |
| **CPU** | SMC `PPMC` | 1.3 W | **26.8 W** | 2.5 W |
| **GPU** | IOReport `Energy Model / GPU Energy` (nJ) | 0.04 W | 0.04 W | **29.0 W** |
| ANE | IOReport `ANE0` | 0 | 0 | 0 (ANE yükü denenmedi) |

- IOReport Energy Model'deki CPU kanalları (`MCPU0_0` vb.) %100 yükte bile **0** — root olmadan doldurulmuyor. CPU gücü SMC'den.
- Energy Model birimleri karışık: `mJ`, `uJ`, `nJ` — kanal başına dönüştür.

## Fanlar

- `FNum` = 2. `F0Ac/F1Ac` anlık rpm (flt), `F0Mn` 1350, `F0Mx` 5349, `F1Mx` 5777.
- Yazılabilir işaretli: **`F0md`/`F1md`** (mod, ui8 — küçük harf!), **`F0Tg`/`F1Tg`** (hedef rpm, flt).
- `FS!`, `F0Md`, `Ftst` **yok**.
- **Karar:** Fan kontrolü teknik olarak mümkün görünüyor. Yazma root ister → `SMAppService.daemon` yardımcısı → imzalı uygulama gerekir.
  Faz 10, Developer hesabı geldikten sonra.

## FPS

- Adaylar: IOReport `DCP / display stats / frame_count` (her ekran için ayrı grup: `DCP`, `DCPEXT0…3`).
- Dahili ekranda 241/sn ölçüldü — ekran en fazla 120 Hz, yani bu sayaç uygulama karesi değil. **Doğrulanmadı.**
- `IOAccelerator PerformanceStatistics`'te FPS alanı yok.
- **Faz 4 denemesi (2026-10-06, `sistem-probe --fps 12`):** `DCP / swap` ve `DCP / scanout` içindeki `subframes(0…24)` sayaçlarının toplamı, GPU %0 iken bile dahili ekranda sabit **121/sn** (= panelin 120 Hz yenilemesi); `frame_count` hâlâ ~242 (= 2 × yenileme). Harici ekranda (`DCPEXT0`) `swap` 3 ile 169/sn arasında içeriğe göre oynuyor, `scanout` 202 sabit. Yani sayaçlar ya panel yenilemesini ya da ekrandaki herhangi bir değişimi sayıyor; hiçbiri uygulama başına kare hızı değil ve GPU yüküyle ilişkisi yok.
- **Karar: FPS özelliği EKLENMEDİ.** Kare sayısıyla tutarlılık kanıtlanamadı (bilinen hızda çizen bir pencereyle kontrollü deney yapılmadı: Ozan'ın ekranına pencere koymak yasak). Sistem genelinde "ekran güncelleme hızı" ayrı bir iş olur, FPS adıyla sunulmaz.

## Faz 4: GPU, güç, CPU frekansı

**GPU** — `IOAccelerator` → `PerformanceStatistics` (tek `IORegistryEntryCreateCFProperty`, 15–20 µs): `Device Utilization %`, `Renderer Utilization %`, `Tiler Utilization %` (tam yüzde), `In use system memory`, `Alloc system memory` (bayt). Boştaki Mac'te Device %0–%30 arasında çok oynak (derleyici/kompozitör patlamaları); menü çubuğu bu yüzden GPU'da daha sert histerezis kullanır.

**IOReport maliyeti** — `IOReportCreateSamples` kanal sayısına bakmadan ~4.3 ms **CPU** (Energy Model 2 kanal 4.4 ms, tüm grup 5.1 ms, CPU Stats 4.2 ms; ikisi tek abonelikte 4.45 ms). GPU Stats/Performance States 0.09 ms, DCP swap 0.15 ms. SMC anahtarı 0.15 ms duvar saati / 16 µs CPU. Karar: güç ve CPU frekansı tek abonelik + tek örnek paylaşır (`IOReport.performanceSubscription()`, 0.25 sn yeniden kullanım) ve yalnız görünür bir sayfa/popover isteyince okunur; menü çubuğundaki GPU widget'ı yalnız `PerformanceStatistics`'i okur.

**GPU / ANE gücü** — `Energy Model / GPU Energy` (nJ). Boşta 0.1–0.2 W, Metal yükünde 29.4 W (`sistem-probe --gpu-check`). `ANE0` hâlâ 0 (ANE yükü altında denenmedi).

**CPU frekansı** — durum adındaki `V<i>P<j>` sayısı `i`, ilgili kümenin DVFS merdiveninde dizin. Merdiven: `IODeviceTree:/arm-io/pmgr` düğümündeki `voltage-states<N>-sram` özelliği = (frekans, voltaj) çiftleri, 4+4 bayt little-endian, frekans **kHz** (eski çiplerde Hz; `voltage-states<N>` sramsız olanlar farklı biçimde). Bu Mac:

| Küme | IOReport kanalı | Durum sayısı | Tablo | Aralık |
|---|---|---|---|---|
| Super (6) | `PCPU0…5` | 20 (`V0P19…V19P0`) | `voltage-states5-sram` | 1308 – 4608 MHz |
| Performance (12) | `MCPU00…05`, `MCPU10…15` | 15 (`V0P14…V14P0`) | `voltage-states22-sram` = `23-sram` (aynı frekanslar, voltaj farklı) | 1344 – 4380 MHz |

Eşleme durum sayısına göre yapılır (tek bir frekans listesi uyuyorsa kullanılır, birden fazla farklı liste uyuyorsa tahmin edilmez). Doğrulama: tek iş parçacıklı bir bağımlı-toplama döngüsü (1 toplama = 1 çevrim) en yüksek durumda 4.17–4.51 GHz ölçtü (tablo 4608; ~%93–98, zamanlayıcı ve geçiş kaybı); düşük önceliğe verilince Performance kümesinde 1.49–2.01 GHz ölçtü, IOReport×tablo en meşgul çekirdek için 1.56–2.15 GHz verdi. Ara durumlar yalnızca bu kaba aralıkta doğrulandı.

## Faz 5: Disk, ağ, Wi-Fi

- **Disk hızı:** `IOBlockStorageDriver` `Statistics` (Bytes/Operations okuma-yazma) fiziksel sürücü başına; yalnız fiziksel disk süzülür (APFS sanal birimleri iki kez saymaz). `sistem-probe --disk-check`: 512 MB yazma + 512 MB okuma, bizim toplam 1024.3 MB = `iostat disk0` 1024.3 MB (fark %0.0, 3 tekrarda aynı). Birim kapasitesi her 15. örnekte (`URLResourceValues`), tak/çıkar IOKit eşleşme + DiskArbitration bayrağıyla (polling yok).
- **SMART ÇALIŞIYOR (root'suz):** plan "büyük olasılıkla kapalı" diyordu; dahili Apple SSD'de `IONVMeSMARTUserClient` root olmadan açılıyor. Okuma ~52-60 µs (100 okuma ortalaması 5.3e-05 sn). Alanlar: sıcaklık, harcanan ömür, yedek alan, yazılan/okunan bayt, güç döngüsü, açık saat, güvensiz kapanış, ortam hatası. Harici sürücülerde ve VM'de yok → `nil`, UI "Sağlık verisi yok" der. 30 tikte bir, yalnız Disk sayfası ister.
- **Ağ hızı:** `getifaddrs` AF_LINK `if_data` deltası, 32-bit sayaç sarması 64-bit toplanır; loopback/tünel/köprü dışarıda. `--net-check`: en0 bizim ↓1382400 B ↑151552 B, `netstat -ib` ↓1382295 ↑152371 (zamanlama farkı, yüzlerce bayt).
- **Bağlantı:** `NWPathMonitor` olay tabanlı (zamanlayıcı yok), bağlandı/koptu/arayüz değişti olayları bellekte (en çok 50). Varsayılan rota arayüzü hız okuyucusuna aktarılır.
- **Wi-Fi:** CoreWLAN RSSI/gürültü/kanal/hız izin istemez; SSID Konum izni ister ve izin yokken `nil` döner. İzin yalnız kullanıcı "Ağ adını göster" düğmesine basınca istenir (başlangıçta asla); reddedilmiş durumda Sistem Ayarları yolu gösterilir. `NSLocationUsageDescription` tr + en (`InfoPlist.xcstrings`).
- **Genel IP / gecikme:** ikisi de varsayılan KAPALI. Genel IP yalnız bağlantı değişince ve açıksa (`api.ipify.org`, 5 sn zaman aşımı, ephemeral oturum, çerez/önbellek yok); gecikme 1.1.1.1:443 TCP el sıkışma süresi, 60 sn, yalnız görünürken ve prizdeyken. Varsayılan ayarlarda dış istek 0 (kodda `URLSession`/`NWConnection` yalnız `Network/Extras.swift`).
- **Ölçümler (Release, 60 sn):** boşta %0.17-0.34 CPU, 19 MB, 2.1-3.7 uyanma/sn (kullanıcı etkinliğiyle oynuyor); Disk penceresi %0.50, 41 MB, 2.7/sn; Ağ penceresi %0.70, 44 MB, 6.0/sn.

## ANE

- Kullanım (utilization) için IOReport kanalı **bulunamadı**. Yalnızca enerji kanalı `ANE0`.
- **Karar:** ANE yüzdesi yerine ANE gücü gösterilir.

## Süreçler

- libproc: 886 sürecin 564'ü okunuyor, 322 root süreci EPERM. `ps` setuid root.
- `proc_pid_rusage` CPU süreleri Mach tick (×125/3 ns).

## Faz 6: Sensörler

Yeniden üretmek: `swift run -c release --package-path Packages/SystemKit sistem-probe --sensors-check 30`

- **Anahtar listesi:** 3626 anahtar, SMC dizin sırası ada göre sıralı. `SMC.keys(withPrefix:)` ikili aramayla yalnız `T…` (285 anahtar) aralığını gezer; tam taramayla (3626 çağrı) birebir aynı sonucu verir (test `smcPrefixSearchMatchesFullWalk`). Katalog kurulumu (anahtar listesi + tür bilgisi + ilk okuma): 143 ms duvar / 13 ms CPU, **bir kez**, ilk talepte.
- **Okuma maliyeti (Release, ölçüldü):** anahtar bilgisi (tür, boyut) önbelleğe alınınca okuma tek IOKit çağrısı: ~12–13 µs CPU / ~100–140 µs duvar. Tam liste 266 anahtar = 3.4 ms CPU (37 ms duvar). Menü çubuğu okuması (63 CPU çekirdek anahtarı: 23 `Tp??` + 40 `Tm??`) = 0.71 ms CPU; GPU'lu yığın değişkeni +42 `Tg??` anahtarı.
- **Katalog:** 264 geçerli sıcaklık/voltaj/akım/güç sensörü + 2 fan. Gruplar: Super 23, Performance 40, GPU 42, SoC 52 (`TPD?` 16 + `TRD?` 16 + `TUD?` 16 + `TCMb` + `TPDX`…), SSD 3 (`TH0a/b/x`), Batarya 3 (`TB0T/1T/2T`), diğer ~94 ham adla. Bellek (DRAM) için ayrı SMC sensörü doğrulanamadı → grup boş, gösterilmiyor.
- **Adlar:** yalnız Mac17,8 için eşleme var; sıra numaralı ("Super sensörü 3"): SMC sensörün hangi fiziksel çekirdeğe ait olduğunu söylemiyor, bu yüzden numara anahtar sırasıdır, çekirdek no değil. Bilinmeyen model: her şey "Diğer", ham SMC anahtarı adıyla; menü çubuğu başlığı tüm sıcaklıkların en yükseği.
- **Süzme kuralları (`SensorValidity`):** (1) yalnız `flt ` türü sıcaklık anahtarı (`ioft` ve `si32` olanlar derece değil: `TG0B…`, `TVAi…`; `TTPD` çöp −306783232); (2) sonlu, −50…150 °C; (3) tam 0.0 = termistörü olmayan sensör (10 anahtar: `Tz1x`, `TfCB`…); (4) katalog girişinde < 5 °C reddedilir (`TVMD` sabit 1.0); (5) "diğer" gruptaki bir sıcaklık 60 tam okuma boyunca bit-bit aynıysa (~2 dk) gizlenir (`TVMX`/`TVmS`/`TVms`=42, `TVS1`=25 gibi sabit kodlar); adlandırılmış gruplar muaf (pil/SSD gerçekten sabit kalabilir). Voltaj 0…60 V, akım −30…30 A, güç 0…500 W, fan 0…20000 rpm (0 = durmuş fan, geçerli). Sonuç: listede çöp değer 0, min 1.0 → kural 4 sonrası 5 °C altı yok.
- **Voltaj/akım:** SMC'de ~50 voltaj ve ~60 akım ray anahtarı var (`VP1b`, `IS7l`…) ama adları belgesiz; yalnız `VD0R`/`ID0R` (DC girişi, 27.4 V) ve `Vb0f`/`Ib0f` (batarya paketi, 12.5 V) listelenir.
- **Güç:** `PSTR` sistem, `PDTR` adaptör girişi, `PPMC` CPU (yükte 30–39 W).
- **Fan:** `FNum`=2, `F{n}Ac/Mn/Mx`; boşta ~1350 rpm (min), yazma yok, `F0md/F0Tg` hiç dokunulmadı.
- **TPDX karşılaştırması:** yükte `TPDX` çekirdek maksimumunun 8–12 °C altında (örn. 76.4 vs 86.0). Menü çubuğu bu yüzden `TPDX` değil 63 çekirdek anahtarını okur (0.71 ms/okuma, 2 tikte bir → ~%0.02 CPU); sayfadaki "CPU en sıcak" ile aynı sayıyı verir.
- **HID kararı: ATLANDI.** HID'de SMC'de olmayan sıcaklık yok: `gas gauge battery` = `TB0T`, `NAND CH0 temp` = `TH0x`, `PMU tdie*` = `TPD*`; `PMU tcal` kalibrasyon sabiti (51.8), `PMU tdev*` −9200 çöp. Maliyeti sensör başına ~1 ms. Voltaj/akım için HID 0xFF08 ayrıca denenmedi: SMC'deki curated anahtarlar yeterli.
- **Yazma yok:** `SensorReader`/`SMC` tarafında SMC yazma çağrısı bulunmuyor (C katmanında yalnız `SMCReadKeyInfo`, `SMCReadBytesWithInfo`, `SMCReadKey`, `SMCKeyAtIndex`).
