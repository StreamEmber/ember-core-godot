# StreamEmberAccount (Android eklentisi)

Telefondaki bütün StreamEmber oyunlarının **ortak girişi**. Bir oyunda giriş yapılınca Falcon oturumu Android
AccountManager'da `com.streamember.account` türündeki tek hesaba yazılır; aynı imza anahtarıyla imzalanmış diğer
oyunlar açılışta bu hesabı okur ve kendi cihaz anahtarını (`dek_`) kendiliğinden alır. Hesap Ayarlar › Hesaplar'da
"StreamEmber" olarak görünür, oradan da silinebilir.

GDScript tarafı: `addons/streamember/core/live.gd` (`Engine.get_singleton("StreamEmberAccount")`):
`get_account()` → `{"email","token","customerUuid"}` JSON ya da `""`, `set_account(email, token, customerUuid)`,
`clear_account()`.

Derleme (JDK 17+, Android SDK; `local.properties` içinde `sdk.dir=…`):

    cd android/streamember_account
    gradle assembleRelease
    cp build/outputs/aar/streamember_account-release.aar ../../addons/streamember/android/streamember-account.aar

Export eklentisi (`addons/streamember/plugin.gd`) AAR'ı her Android export'una ekler ("Use Gradle Build" açık olmalı).

Bilinmesi gerekenler:

- **Aynı imza şart.** Hesabı yalnız hesap türünün sahibi olan uygulamayla aynı anahtarla imzalanmış uygulamalar görür.
  Google Play App Signing her uygulamaya ayrı anahtar üretir; yeni oyunu açarken "başka bir uygulamayla aynı anahtarı
  kullan" seçilmeli. Debug derlemesi mağaza derlemesinin hesabını göremez (sessizce "hesap yok" gibi davranır).
- Hesap türünü ilk kurulan oyun sahiplenir; o oyun kaldırılınca Android hesabı da siler (diğer oyunlar kendi `dek_`
  anahtarlarıyla çalışmaya devam eder, bir sonraki girişte hesap yeniden yazılır).
- iOS karşılığı (Keychain Sharing, ortak erişim grubu) Mac + Xcode gerektirir; henüz yok. iOS'ta her oyun kendi girişini saklar.
