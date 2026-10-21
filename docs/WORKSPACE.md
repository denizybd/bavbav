# Deniz ve Emir Workspace

Bavbav 0.11.0, Workspace'in SwiftUI ve AppKit arayüzünü kendi işleminin içinde
çalıştırır. `⌘7`, Windows menüsündeki Workspace ve durum menüsündeki Workspace
aynı pencereyi açar. Kısayol Ayarlar'dan değiştirilebilir. Önceki sürümde `⌘7`
başka bir eyleme atanmışsa o atama korunur; Workspace menüden açılabilir.

Workspace ayrı bir `.app` olarak başlatılmaz. Native görünümler
`Sources/IkiWorkspaceKit` hedefinde derlenir. P2P çekirdeği, önceki native sürümdeki
gibi özel stdio üzerinden çalışan paket içindeki Node işlemidir. Ana menü,
Dock kimliği, pencere yaşam süresi ve kapanış Bavbav'a aittir.

Mevcut `~/Library/Application Support/IkiWorkspace` dizini kullanılır. Uygulama
paketinin değiştirilmesi kimlik, eşleştirme anahtarları, sohbet veya proje
kayıtlarını değiştirmez. Bu veri dizinini silmeyin veya başka bir bilgisayara
kopyalamayın. Aynı veri dizini için tek çekirdek kuralı geçerlidir.

Workspace penceresini kapatmak eş bağlantısını durdurmaz; `⌘7` aynı pencereyi
yeniden açar. Önceden eşleştirilmiş bir kayıt varsa normal Bavbav açılışı
Workspace istemcisini pencere açmadan hazırlar. Bavbav kapanırken kendi
istemcisini düzgün kapatır; paylaşılan bağlantı hizmetinin yaşam süresi
Workspace çekirdeği tarafından yönetilir.

## Kaynaktan derleme

Bu sürümün kanonik Workspace native kaynakları `Sources/IkiWorkspaceKit`
altında, bunlarla eşleşen runtime ve motor kaynakları
`Vendor/IkiWorkspace/Resources` altında hazırlanır. Bu kaynaklar özel Workspace
projesinden gelir; bu entegrasyonu paylaşırken özel kaynakların yayın izinleri
ayrıca değerlendirilmelidir.

Hazırlanan kaynaklarla kanonik, kurulum yapmayan derleme:

```sh
BAVBAV_STAGE_ONLY=1 zsh scripts/build-app.sh
```

Yerel geliştirmede hazırlanmış eşleşen bir Workspace paketinin kaynakları
açıkça seçilebilir:

```sh
IKI_WORKSPACE_APP="/absolute/path/Iki Workspace.app" \
  BAVBAV_STAGE_ONLY=1 zsh scripts/build-app.sh
```

Derleme bu paket içindeki `Contents/Resources` içeriğini
`Bavbav.app/Contents/Resources/IkiWorkspace` altına gömer. İç içe uygulama veya
ayrı Workspace GUI işlemi paketlenmez. `app-version.json`, Node runtime ve
native bridge eksikse derleme aday paketi oluşturmadan durur. Standart Bavbav
imzalama ve tüm paket kontrolleri bu aday üzerinde uygulanır.

## Uygulamanın kendi native pencere kontrolü

```sh
"/absolute/path/Bavbav.app/Contents/MacOS/Bavbav" \
  --workspace-ui-check \
  --workspace-report /tmp/bavbav-workspace-report.json \
  --workspace-render /tmp/bavbav-workspace.png
```

Bu kontrol geçici UUID veri dizini ve çevrimdışı motor kullanır. `⌘7` için yerel
olay yönlendirmesini, menü atamasını, Bavbav'ın `NSApplication` nesnesine ait tek
native pencereyi, kapanınca bağlantı motorunun çalışmaya devam etmesini ve
uygulama kapanışında motorun durmasını denetler. Üretim verisine dokunmaz.
PNG, uygulamanın kendi native görünümünden çizilir; fiziksel klavye kullanımı
veya iki gerçek cihazın canlı bağlantısının kanıtı değildir.
