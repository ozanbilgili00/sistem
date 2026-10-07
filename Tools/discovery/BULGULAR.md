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

## ANE

- Kullanım (utilization) için IOReport kanalı **bulunamadı**. Yalnızca enerji kanalı `ANE0`.
- **Karar:** ANE yüzdesi yerine ANE gücü gösterilir.

## Süreçler

- libproc: 886 sürecin 564'ü okunuyor, 322 root süreci EPERM. `ps` setuid root.
- `proc_pid_rusage` CPU süreleri Mach tick (×125/3 ns).
