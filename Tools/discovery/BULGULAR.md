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
- DVFS durumları: `DOWN, IDLE, V0P14 … V14P0` (frekans tablosu Faz 4'te IORegistry'den eşlenecek).
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
- **Karar:** Faz 4'te `swap / subframes` sayaçlarıyla tekrar denenir; doğrulanamazsa FPS özelliği çıkar.

## ANE

- Kullanım (utilization) için IOReport kanalı **bulunamadı**. Yalnızca enerji kanalı `ANE0`.
- **Karar:** ANE yüzdesi yerine ANE gücü gösterilir.

## Süreçler

- libproc: 886 sürecin 564'ü okunuyor, 322 root süreci EPERM. `ps` setuid root.
- `proc_pid_rusage` CPU süreleri Mach tick (×125/3 ns).
