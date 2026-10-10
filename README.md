# ember-core-godot — StreamEmber Live for Godot

Godot 4 oyunlarını canlı yayına bağlayan eklenti. İzleyici hediyesi, yorumu veya beğenisi
(EventFabric + GCore üzerinden) oyunda bir aksiyona dönüşür. GTA V / RDR2 runtime'larındaki `StreamEmber.Live` ile
aynı davranış ve aynı mod API'si: kimlik, bağlantı, ayarlar ve presence eklentinin içindedir; oyun yalnız aksiyonları
işler.

- Godot **4.3+**, saf GDScript, bağımlılık yok. İlk sürüm masaüstü export içindir (Launcher aynı bilgisayarda).
- Bu repo aynı zamanda çalışan bir örnek oyundur (`demo/`): izleyiciler ekrana kutu düşürür, yazı yazar.

## Kurulum (yeni Godot oyunu)

1. [Releases](https://github.com/StreamEmberPlatform/ember-core-godot/releases/latest) sayfasından
   `streamember-godot-X.Y.Z.zip` indir, oyunun proje köküne aç (`addons/streamember/` oluşur);
   Project → Project Settings → Plugins → **StreamEmber Live** aç.
   Eklenti `StreamEmber` autoload'unu ve `streamember/*` proje ayarlarını ekler.
2. `res://streamember/streamember-module.json`: `applicationUuid` (Falcon oyun UUID'si), `code` (kebab-case), `name`.
3. `res://streamember/game-schema.json`: aksiyonlar ve ayarlar (GTA V/RDR2 şablonlarıyla aynı biçim; Falcon'a da bu yazılır).
4. Export: Export → Resources → "Filters to export non-resource files" alanına `streamember/*.json` ekle.
5. `addons/streamember/` oyunun reposuna commit'lenir (klonlayan herkes aynı sürümle açar), ama **elle değiştirilmez**:
   düzeltme bu repoya gelir, oyunlara güncellemeyle gider.

## Güncelleme

- **Editör:** açılışta günde bir kez son Release denetlenir; yenisi varsa "Update" ile indirilir, eklenti klasörü
  değiştirilir (artık olmayan dosyalar silinir) ve editör kaydedip yeniden başlar. Elle: Project → Tools →
  **StreamEmber Live: check for updates**. Kapatmak: Project Settings → `streamember/editor/check_updates`.
- **Komut satırı** (oyunun klasöründe; çok oyunu bir döngüyle güncellemek için):
  ```bash
  godot --headless --path . -s res://addons/streamember/update.gd                         # son sürüm
  godot --headless --path . -s res://addons/streamember/update.gd -- --version=0.2.0      # belirli sürüm
  godot --headless --path . -s res://addons/streamember/update.gd -- --from=../ember-core-godot   # yayınlanmamış yerel çekirdek
  godot --headless --path . -s res://addons/streamember/update.gd -- --check              # yalnız denetle (yeni varsa çıkış 2)
  godot --headless --path . --import
  ```
- Güncellemeden sonra değişikliği oyunun reposuna commit'le (`addons/streamember` + CHANGELOG'daki sürüm).
- Sürüm kuralı ve her sürümde ne değiştiği: `CHANGELOG.md`. MAJOR sürümde editör ayrıca uyarır.

## Yeni sürüm yayınlamak (çekirdek geliştiricisi)

1. Değişiklik + test; `streamember.gd` `VERSION` ve `plugin.cfg` `version` birlikte artar; `CHANGELOG.md`'ye `## X.Y.Z — tarih`.
2. Yeni `.gd` dosyası eklediysen projeyi Godot 4.4+ ile bir kez açıp oluşan `.uid` dosyasını da commit'le.
3. `git tag vX.Y.Z && git push origin main vX.Y.Z`. CI Godot 4.3 ve 4.7'de birim + uçtan uca testleri koşar, geçerse
   GitHub Release'i (zip + CHANGELOG notu) açar. Oyunların editörleri yalnız Release'leri görür.

## Kullanım

```gdscript
func _ready() -> void:
    StreamEmber.on("box.drop", _drop_boxes)                   # her şema aksiyonu için bir handler
    StreamEmber.settings_changed.connect(_apply_settings)      # başta şema varsayılanlarıyla da gelir
    StreamEmber.live_stopped.connect(_clear_everything)

func _apply_settings(settings: StreamEmberValues) -> void:
    _max_alive = settings.get_int("boxes.maxAlive", 50, 1, 200)

func _drop_boxes(action: StreamEmberAction) -> void:
    var units := mini(50, action.arguments.get_int("count", 3, 1, 20) * action.quantity)   # çarp, sonra sınırla
    _queue_boxes(units, action.viewer.display_name)                                       # işi karelere yay
```

| Üye | Görev |
|---|---|
| `on(id, handler)`, `off(id, handler)` | Aksiyon handler'ı (ana thread'de çalışır) |
| `live_started`, `live_stopped`, `action_received(action)`, `settings_changed(settings)`, `connection_changed(connected)`, `notified(text, level)` | Sinyaller |
| `settings`, `settings_revision`, `manifest`, `customer_uuid`, `application_uuid`, `language`, `is_active`, `live_connected`, `can_write` | Durum |
| `reload_settings()`, `reset_gcore(done)` | Ayarları hemen oku; GCore sayaçlarını sıfırla |
| `StreamEmberAction` | `action`, `arguments`, `quantity`, `viewer` (`display_name`, `username`, `avatar_url`), `gift`, `trigger`, `comment`, `like_count`, `is_test`, `render("{user} {gift}")`, `describe()` |
| `StreamEmberValues` | Noktalı yol: `get_int/get_float(path, fallback, min, max)`, `get_bool`, `get_string`, `get_string_list`, `get_object` |

## Proje ayarları (`streamember/*`)

| Ayar | Varsayılan | |
|---|---|---|
| `enabled` | `true` | Canlı bağlantıyı tamamen kapatır |
| `launcher_url` / `eventfabric_url` / `falcon_url` | `http://127.0.0.1:47880` / `https://eventfabric.streamember.com` / `https://falcon.streamember.com` | |
| `customer_uuid` | boş | Yalnız geliştirme: Launcher olmadan bu müşterinin aksiyonlarını dinle |
| `presence_seconds` / `settings_seconds` | 15 / 60 | |
| `announce_actions`, `show_notifications` | `true` | Ekranın sağ üstünde kısa bildirimler |
| `test_hotkeys` | `true` | Ctrl+Shift+F1–F9 şemanın ilk dokuz aksiyonu (test paketi), F10 durum, F11 ayarları yeniden oku, F12 GCore sıfırla |
| `debug` | `false` | Ayrıntılı log |

Log: `user://logs/streamember.log` (her açılışta yeniden başlar) + konsol, `[StreamEmber]` önekiyle.

## Nasıl çalışır

1. İlk karede (sahnenin `_ready` handler'ları kayıtlıyken) manifest ve şema okunur; `live_started` + `settings_changed`.
2. Müşteri: `customer_uuid` ayarı → Launcher `GET /api/customer` → runtime token `sub`.
3. EventFabric `/events/ws?format=json&customerUuid&applicationUuid`: kopunca cursor ile kaldığı yerden
   (1-2-5-10-20-30 sn geri çekilme), 20 sn ping, son 4096 id ile tekrar eleme, en fazla 2048 bekleyen, kare başına 25 aksiyon.
4. Falcon `/public/game/config/{müşteri}/{oyun}`: hemen ve 60 sn'de bir; şema varsayılanlarıyla derin birleştirme.
5. Her 15 sn: presence (Launcher'dan alınan runtime token ile), Launcher `/api/active-application`.
6. Başka oyuna ait aksiyon atılır; şema argüman varsayılanları eklenir; handler'lar çalışır, sonra `action_received`.

Token yalnız `Authorization` başlığında gider, loglanmaz; istemci doğrulamaz (doğrulama sunucudadır).

## Test

```bash
godot --headless --path . --import
godot --headless --path . -s res://tests/run_tests.gd        # birim testleri, ağsız
GODOT=godot tests/e2e/run.sh                                  # sahte Launcher/Falcon/EventFabric ile uçtan uca (python3 + websockets)
```

Ortak kurallar ve kararlar: `StreamEmberPlatform/docs` (`handbook/godot-core.md`).
