# Changelog

Sürüm kuralı: PATCH hata düzeltmesi, MINOR geriye uyumlu yenilik, MAJOR oyun kodunu bozabilecek değişiklik
(başlıkta **Uyumsuz** yazılır ve geçiş adımı verilir).

## 0.9.0 — 2026-10-24 — **Uyumsuz**

Oyun içi StreamEmber girişi, oyunlar arası ortak giriş (Android) ve CDN'den kendini güncelleme.

- **Oyun içi giriş:** `make_connect_button()` (küçük "● Canlı" çipi) ve `open_connect_panel()` (çekirdeğin çizdiği panel:
  e-posta + şifre, şifremi unuttum, bağlantı durumu, yeniden bağlan, çıkış; 14 dil). Aynı işlemler `sign_in`, `sign_out`,
  `can_sign_in`, `account_email`, `ui_theme`. Falcon `api/auth/login` → `api/me/device-keys` (`dek_`); oturum token'ı
  telefonda kalmaz (ortak hesap hariç).
- **Ortak giriş (Android):** `StreamEmberAccount` eklentisi (`android/streamember-account.aar`, AccountManager); bir oyunda
  giriş yapılınca aynı imzalı diğer StreamEmber oyunları kendiliğinden bağlanır.
- **Kendini güncelleme:** eklenti kararlı kısım + `core/` olarak ayrıldı; `boot.gd` yeni çekirdeği CDN'den
  (`components/ember-core-godot`) imza + SHA-256 denetimiyle indirir, bir sonraki açılışta çalıştırır, iki kez takılırsa
  gömülüye döner. Ayarlar `streamember/cdn_url`, `streamember/runtime_updates`. CI imzalayıp CDN'e yayınlar.
- **Launcher "Oyna" (telefon) oyunu yalnız açar:** `streamember://play` intent filtresi çekirdeğin export eklentisinde.
- Launcher'a ulaşılamıyor / giriş yok uyarıları artık ekranda gösterilmez (log'da kalır); bağlanmayan oyuncu hiçbir şey görmez.
- Dosyalar: `event_fabric_client.gd`, `tiktok_capture.gd` → `core/`; `streamember.gd`'nin işi `core/live.gd`'de.

**Geçiş:** `claim_launch_token(token)` ve `set_manual_customer(uuid)` kaldırıldı (deep link jetonu ve elle UUID yok).
Oyun bunları çağıran kodu ve deep link eklentisini siler; yerine lobiye `add_child(StreamEmber.make_connect_button())`.
Oyun içinden çekirdek dosyalarına (`res://addons/streamember/event_fabric_client.gd` …) doğrudan `preload` yapan kod
`core/` yoluna geçer (normal oyunlar yapmaz).

## 0.8.0 — 2026-10-23 — **Uyumsuz**

Yeni EventFabric toplama modeli (live-data-flow-report D1–D14) ve makine (node) sistemiyle uyum.

- **Toplama:** `collection=true&platform=&target=` kalktı. Cihaz anahtarlı (`dek_`) kimlikte toplama
  `collect=self&key=…` ile istenir; EventFabric hedefleri Falcon'daki açık platformlardan çözer. Anahtarsız (elle
  girilen UUID) kimlik artık toplatamaz, yalnız dinler. Launcher kimliği hiç istemez (veriyi launcher üretir).
- **Telefonda kendi toplaması (D12):** yeni `tiktok_capture.gd`. Oyun TikTokSign'dan (`/connect`, `Bearer dek_…`)
  imzalı adres alır, TikTok soketine telefonun kendi IP'sinden bağlanır (oda girişi, 10 sn'de bir kalp atışı, ack) ve
  her çerçeveyi EventFabric `/ingress/tiktok/webcast` soketine aktarır. İmza servisi reddederse ya da 3 deneme
  çerçevesiz biterse EventFabric toplamasına (`collect=self`) düşer. Diğer platformlar EventFabric'ten.
  Proje ayarı `streamember/collect`: `auto` (telefon: cihaz, masaüstü: sunucu) | `device` | `server` | `off`;
  `streamember/tiktoksign_url`.
- **Durum:** `collection.state` / `collection_changed` / `collection_state` / `collection_allowed` kalktı. Yerine
  `stream.status`: `stream_changed(status)` sinyali ve `streams` sözlüğü (`platform:target` → durum). Kesin durumlarda
  (`ended`, `not_live`, `not_found`, `denied`) hiçbir şey kendiliğinden yeniden istemez; oyun `restart_collection()`
  ("Yeniden bağlan", `restart=manual`) çağırır. `claim_launch_token` / `set_manual_customer` artık
  `collection_allowed` döndürmez.
- **Makineler:** `wrong_region` yerine `wrong_node` / `node_disabled`; adres her bağlanmada (saklanan kimlikte de)
  Falcon'dan yeniden okunur. Yeniden bağlanma 1, 2, 4, 8, 15, 30 sn, ±%30 rastgele sapma.

**Geçiş:** `collection_changed` / `collection_state` kullanan oyun `stream_changed` / `streams`'e geçer; "yayın yok /
bitti" ekranındaki düğme `StreamEmber.restart_collection()` çağırır.

## 0.7.1 — 2026-10-22

- Düzeltme: `claim_launch_token` / `set_manual_customer` modül etkinleşmeden (ilk kareden önce, ör. sahnenin `_ready()`'sinde
  deep link işlenirken) çağrılınca `_config` boş olduğu için `falcon_url` hatasıyla çöküyordu; telefonda Launcher'dan açılan
  oyun müşteri kimliğini hiç alamıyordu. Proje ayarları artık ilk API çağrısında da okunuyor (`_load_config`).
- Düzeltme: dışa aktarma eklentisi `streamember/*.json` dosyalarını Godot zaten kaynak olarak eklediği hâlde ikinci kez
  ekliyordu; Android APK aynı adlı iki giriş yüzünden imzalanamıyordu. Kaynak olarak bilinen dosya artık eklenmiyor.

## 0.7.0 — 2026-10-21

- Yeni: `activity_received(event)` sinyali. EventFabric'in aynı soketten gönderdiği `packetType=event` çerçeveleri (normalize
  platform olayları: yorum, beğeni, katılım, takip, paylaşım, hediye …) olay `id`'sine göre tekilleştirilip hemen iletilir.
  Oyun bunu yalnız "kim aktif" bilgisi (izleyici karakteri vb.) için kullanır; oyun etkileri yine aksiyonla gelir.
  `event_fabric_client.gd`: `event_received(json)`. Eski davranış değişmedi (aksiyon akışı aynı).

## 0.6.0 — 2026-10-20

- Launcher'sız kimlik (mobil; karar #17): `claim_launch_token(token)` Launcher web'in deep link jetonunu Falcon
  `POST /public/mobile-launch/claim` ile müşteri kimliği + bölge + toplama hedefleri + cihaz anahtarına (`dek_…`) çevirir;
  `set_manual_customer(uuid)` oyuncunun yazdığı müşteri UUID'si için Falcon `/public/customers/{c}/region` + `/targets` okur;
  `set_identity(info)` / `clear_identity()` / `has_stored_identity()`. Kimlik `user://streamember/identity.cfg`'ye yazılır ve
  sonraki açılışlarda kendiliğinden kullanılır. Sıra: proje ayarı → Launcher (ulaşılabiliyorsa) → saklanan kimlik.
- Toplama: cihaz / elle kimliklerde `/events/ws` isteğine `collection=true&platform=&target=` eklenir (Launcher yokken
  EventFabric yayını kendisi toplar; müşterinin EulerStream anahtarı gerekir). `collection.state` çerçeveleri
  `collection_state` + `collection_changed(state)`; `collection_denied` uyarısı.
- Cihaz anahtarı yalnız presence bildirir: `write_scope` (`full` | `device` | ``); `reset_gcore` yalnız `sek_` ile.
- Yeni: `identity_source`, `targets`, `collection_allowed`, `identity_changed` sinyali; F10 durumunda kaynak ve toplama.
- Android / iOS'ta (ya da `streamember/probe_launcher = false`) Launcher hiç yoklanmaz; "Launcher'ı aç" uyarısı mobilde çıkmaz.
- Test düzeltmesi: `config.changed` artık uygulama süzgeci olmadan sayılır (0.5.1 davranışı).

## 0.5.1 — 2026-10-20

- `config.changed` her geldiğinde ayar yeniden okunur (EventFabric bu sinyali zaten yalnız bu müşteri + oyunun soketlerine gönderir;
  istemcideki, frame'de bulunmayan `applicationUuid` denetimi kaldırıldı). Launcher'da kaydedilen ayar oyunda hemen uygulanır.

## 0.5.0 — 2026-10-17

- API sözleşmesi: runtime token kaldırıldı; kimlik Launcher `GET /api/customer` (`customerUuid`, `secretKey`, `region.eventFabricUrl`).
  Yazmalar `?key=`; EventFabric adresi yayıncının bölgesinden, her bağlantıda yeniden okunur. Yollar `/presence/report`, `/sessions/reset`,
  Falcon `/public/customers/{c}/applications/{a}/config`. `config.changed` → ayar yenileme; `settings_seconds` varsayılanı 600.
- Proje ayarları: `secret_key` (geliştirme) eklendi; `eventfabric_url` artık yalnız geliştirme (varsayılan boş).
- `parse_jwt` kaldırıldı; `event_fabric_client` ilk argüman olarak adres çözücü `Callable` alır (yalnız çekirdeğin iç kullanımı).

## 0.4.0 — 2026-10-14

- Takımlar: `action.viewer.team` (`StreamEmberAction.Team`: `id`, `code`, `name`, `short_name`, `primary_color`,
  `secondary_color`, `logo_url`) izleyicinin takımıdır; GCore yorumdaki takım adı / kısa ad / anahtar kelimeden seçer, seçmeyeni
  ilk aksiyonunda en küçük takıma atar. Oyun ayarında takım yoksa `null`.
- Yeni üye: `StreamEmber.teams` — Falcon ayarındaki aktif takımlar (sıralı); `settings_changed` ile birlikte güncellenir.
- Şablonlarda `{team}` (izleyicinin takım adı).

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
