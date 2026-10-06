# Üretim kuralları — Sistem Monitörü

Profil `YEREL` (macOS menübar aracı, GitHub dağıtımı) · Aşama `Prototip`. Kapılar ve rapor: Obsidian `Projeler/Sistem Monitörü/Plan.md`, `Kontrol.md`.

## Bu projede geçerli olan maddeler
A-01 A-02 D-01 D-06 F-01 F-03 J-04 J-05 J-06 K-01 L-02 N-01 N-02 N-03 N-05 O-04 O-07 + Özellik Bitti Tanımı

## Uygulanmayanlar ve gerekçe
T, V, Y, Z, O-02, G-02: App Store'a çıkmıyor, gelir yok. H-04, M-06: kalıcı kullanıcı verisi yok.

## Kod yazarken her zaman
- Her faz sonunda `scripts/perf-check.sh` bütçesi (boşta <%0.3 CPU, <2 uyanma/sn, <35 MB).
- Alt süreç (`ps`, `system_profiler`) yalnız sabit argüman dizisiyle, kabuk olmadan; çıktısı ayrıştırılırken doğrulanır.
- Yeni metin `Localizable.xcstrings`'e tr + en.
- Okuyucu birim testi + 10 000 okumada sızıntı testi.

## Asla
- Pencereyi öne getirme / odak çalma (ölçüm için `--measure-window`).
- Kişisel veri veya süreç argümanlarını loglama.
- Kullanıcı onayı olmadan push.
