# Deniz / Emir otomatik dağıtımı

Bu Mac'te otomasyon yapılandırıldığında normal derleme sonundaki hook devreye girer.
Büyük güncellemeyi bitiren geliştirici:

1. `AppResources/Info.plist` sürüm/build numarasını artırır. İlk otomatik sürüm,
   kurulu 0.13.0 (68)'den daha yeni olmalı.
2. `BAVBAV_STAGE_ONLY=1 zsh scripts/build-app.sh` çalıştırır. Bütün paket kontrolleri
   başarılı olmalı; yalnızca `swift build` veya commit yapmak yayımlama başlatmaz.
3. Kaynakları değiştirmeden açık Bavbav görevlerini tamamlar. Yayımlayıcı
   Journal'daki işler bitince kendi commit/push, paketleme ve P2P paylaşımını yapar.

`scripts/release-source-hash.py` ignored özel Workspace kaynaklarını GitHub'a
koymadan derleme kaydına bağlar; gömülü sürüm bilgisini de host ile aynı tutar.
Başarılı kayıttan sonra kaynak değişirse yeni bir doğrulanmış derleme gerekir.
Public kaynaklar normal GitHub main'e push edilir; özel runtime/kimlikler gitmez.
Başka bir staged commit veya remote çatışması varsa otomasyon durur; force push
ya da otomatik rebase yapmaz. İlgili işler tamamlandıktan sonra release commit'i
otomatik oluşturulur, geliştiricinin ayrıca commit yapması gerekmez.

Deniz'deki durum:
`~/Library/Application Support/Bavbav Release Automation/publisher/`
`publisher-last-check.json`, `publisher-status.json`, `publisher-error.json`.
Yayımlama kontrolü başarılı derlemeden sonra 12 saate kadar tekrar dener.
Makine bu sırada kapanırsa tamamlanmış push/P2P paylaşımı korunur; tamamlanmamış
yayımlama bir sonraki başarılı derlemede tekrar ele alınır.

Emir, `Bavbav-Otomatik-Guncelleme-Emir.zip` yardımcısını bir kez kurmalıdır.
Sonrasında mevcut eşleştirmeden aldığı Deniz imzalı daha yeni sürümleri,
aktif Codex/dosya işleri bitince otomatik kurar. Eşleştirme ve projeler korunur.
Paketin gönderilmesi, karşı depoya ulaşması ve yeni sürümün gerçekten kurulması
ayrı durumlardır; sonuncusu Emir'in uygulamasından gelen sürüm/hash ile doğrulanır.
