# Changelog

Sürüm kuralı: PATCH hata düzeltmesi, MINOR geriye uyumlu yenilik, MAJOR oyun kodunu bozabilecek değişiklik
(başlıkta **Uyumsuz** yazılır ve geçiş adımı verilir).

## 0.3.0 — 2026-10-12

- Oyun duraklatıldığında canlı bağlantı durmaz (autoload `PROCESS_MODE_ALWAYS`); aksiyonlar kuyrukta bekler, oyun devam edince işlenir.
- Aksiyonlar menüde de kaybolmaz: hiç handler kayıtlı değilken veya `StreamEmber.hold_actions = true` iken kuyrukta bekler
  (en fazla 2048). Yeni üye: `hold_actions`. F10 durumunda kuyruk uzunluğu görünür.
- Export: `streamember/*.json` eklenti tarafından otomatik pakete eklenir; elle eklenen export filtresi artık gereksiz (kaldırılabilir).
- Güncelleyici: repo `StreamEmber/ember-core-godot`; CI'ın ürettiği release zip'i indirilir; dosyalar önce `.new` olarak
  yazılır, hepsi yazılınca eskilerin yerine geçer (yarıda kalan güncelleme eski sürümü bozmaz).

## 0.2.0 — 2026-10-10

- Merkezi güncelleme: editör günde bir GitHub Releases'ı denetler, yeni sürümü tek tıkla kurup editörü yeniden başlatır
  (Project → Tools → "StreamEmber Live: check for updates"; kapatmak için `streamember/editor/check_updates`).
- Komut satırı: `godot --headless --path . -s res://addons/streamember/update.gd` (`--version=`, `--from=`, `--check`).
- `.uid` dosyaları eklentiyle birlikte gelir (Godot 4.4+ projelerinde kimlikler sabit kalır).
- CI: her push'ta Godot 4.3 ve 4.7 ile birim + uçtan uca test; `v*` etiketi testler geçince GitHub Release olur.
- 0.1.0'dan geçiş: `addons/streamember` klasörünü bu sürümle bir kez elle değiştir; sonraki güncellemeler otomatik.

## 0.1.0 — 2026-10-10

- İlk sürüm: StreamEmber.Live davranışının Godot 4.3+ GDScript karşılığı (kimlik, runtime token, EventFabric replay/geri çekilme/ping/tekrar eleme, Falcon ayarları, presence, test kısayolları, log, bildirim).
- Demo oyun, birim testleri ve sahte servislerle uçtan uca test.
