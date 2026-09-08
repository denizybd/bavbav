# Bavbav

Klavye odaklı, yerel macOS arayüzü. Codex bölümü AppKit pencereleri içinde SwiftUI
ile çizilir ve Codex App Server'a yerel stdio bağlantısı kurar. Ayrı CHAT bölümü de
aynı native mesaj ekranını kullanır; proje dışı sohbetler `CHANNEL / ChatGPT`
başlığıyla açılır. Web sitesi, Safari veya ChatGPT masaüstü uygulaması açılmaz.

## Zengin mesaj görünümü

Codex sohbet mesajları yerel TextKit ile biçimlendirilir: başlıklar, kalın/italik
metin, iç içe ve numaralı listeler, görev listeleri, alıntılar, tablolar ve satır içi
kod. Koyu yüzeyler ve sade tipografi korunur; mesaj başlığındaki saat değişmez.
TRACE komut/diff/araç çıktıları biçimlendirme uygulanmadan olduğu gibi gösterilir.

LaTeX `\(...\)` / `$...$` satır içinde, `\[...\]` / `$$...$$` ayrı denklem olarak
çizilir. Kesir, kök, integral ve matrisler Retina'da keskin kalan vektör görüntülerdir.
Formül çizimi internet, HTML veya yeni bir WebKit süreci kullanmaz. Eksik veya
desteklenmeyen LaTeX, aşırı uzun/karmaşık formüller okunabilir kaynak metni olarak
kalır; tam LaTeX belge/makro çalıştırma sistemi değildir. Para tutarları ve kod
içindeki dolar işaretleri matematik olarak yorumlanmaz.

Üç backtick ile çevrili kod blokları, dil adı ve sağ üstte `KOPYALA` düğmesi olan
koyu kutulara dönüşür. `prompt` dil etiketi de desteklenir; kutunun içeriği aynen
kopyalanır. Serbest düzyazının prompt olduğu tahmin edilmez: kutu için yanıtın o
bölümünün Markdown kod bloğu olarak gelmesi gerekir.

Bir mesajı tıklayıp `⌘A` tüm mesajı seçer; `⌘C` metni kopyalar. Formüller panoya
anlamsız resim işareti yerine orijinal LaTeX'iyle, tablolar sekmeyle ayrılmış hücreler
olarak gider. Mesaj içindeki aktif seçim sırasında gelen güncellemeler son değerle
birleştirilir; seçim kaldırılınca veya yazma alanına geçilince hemen uygulanır.

Markdown bağlantıları ve metindeki normal HTTP(S) adresleri tıklanabilir. Yerel
dosya bağlantıları Finder'da gösterilir; komut/uygulama bağlantıları çalıştırılmaz.
Ham HTML yürütülmez, mesajdaki uzak görseller otomatik indirilmez.

Biçimlendirme önbelleği 80 kayıt/12 MiB, formül önbelleği 128 kayıt/8 MiB bütçelidir.
256 KiB üzerindeki mesajlar tam içerikleri korunarak düz metne döner; 12 sütun veya
249 gövde satırını aşan tablolar kaynak biçiminde gösterilir. Amaç çok uzun araç
çıktılarının veya bozuk akışın arayüzü sınırsız bellekle büyütmesini önlemektir.

Markdown ayrıştırıcısı [swift-markdown 0.8.0](https://github.com/swiftlang/swift-markdown/tree/0.8.0),
matematik motoru [SwiftMath 1.7.3](https://github.com/mgriebling/SwiftMath/tree/1.7.3).
SwiftMath, imzalı macOS paketinde fontların doğru bulunması için küçük bir kaynak
konumu düzeltmesiyle `Vendor/SwiftMath` altında tutulur; sürüm ve güncelleme notları
oradadır. Fontlar ve lisanslar uygulamayla birlikte paketlenir.

## Otomatik takvim / günlük

`⌘5`, aynı native karanlık tasarımda bir kişisel/proje günlüğüdür; Apple/Google
Takvim veya web sayfası açmaz. Bavbav üzerinden yapılan yeni `CODEX` ve `ChatGPT`
konuşmalarında önemli yaşanmış olayları, kesinleşmiş kararları ve açık planları
ayrı türlerde kısa cümlelere dönüştürür. Geçmiş sohbetleri kendiliğinden topluca
taramaz; eski bir sohbette yazılan yeni mesajlar kapsamdadır.

- Yakalama etkin pencereye bağlı değildir. `Q` ile sohbeti kapatmak not işini
  durdurmaz. Tamamlanan turlar, kalıcı iş kuyruğundan tek tek işlenir; yeniden
  açılışta yarım kalan bilinen turlar yalnız okunarak tamamlanır.
- Yakın bağlam son 8 mesaj / 16 KB ve 32 sohbetle sınırlıdır. Model girdisi en çok
  80 KB'dır; büyük veya başarısız işler sessizce kaybolmak yerine hata ile bekler.
  Üç otomatik deneme ve artan bekleme süresi vardır; `R` yeniden dener.
- Not çıkarma ek Codex kullanımı tüketir. Günlük en fazla 60 iş başlatılır;
  fazlası kuyruğa kalır. `P` durdurur; duraklatılan sürede yeni konuşmalar alınmaz.
  Çıkarıcı yalnız iş sırasında açılır ve sonra kapanır, sürekli ikinci model
  süreci tutmaz. Mevcut yenileme ritmi kullanılır; ayrı sürekli tarama yoktur.
- Çıkarıcı, [resmî App Server protokolü](https://learn.chatgpt.com/docs/app-server)
  üzerinden geçici, salt okunur bir oturum ve JSON çıktı şeması kullanır.
  Kullanıcının sohbetine prompt eklemez, model/çaba ayarlarını veya Codex'in
  kalıcı yapılandırmasını değiştirmez. Kabuk, web, uygulama araçları, MCP,
  alt ajanlar, hook ve bellek özellikleri yalnız çıkarıcı süreçte kapatılır.
- Her notta kaynak sohbet ve birebir kaynak alıntısı bulunur. Uydurma alıntı/ID,
  düşük güven veya yalnız önceki bağlama dayanan kayıtlar reddedilir. Tarih
  somut ifadeyle doğrulanır; belirsiz olaylar konuşuldukları günde **tarih belirsiz**
  etiketiyle görünür. Öneri bir karar, plan gerçekleşmiş bir olay sayılmaz.
  Otomatik anlam çıkarma kusursuz değildir: `E` ile not/tarih düzeltilebilir.
- Aynı işin tekrar işlenmesi, tekrar adaylar ve eşleşen olay kayıtları engellenir.
  Silinen kayıt bir engel kaydı olarak korunur; model onu yeniden oluşturmaz.
  `U` son silmeyi geri alır. Düzenlenen metin otomatik olarak üzerine yazılmaz.
- Veriler `~/Library/Application Support/Bavbav/Journal/journal.json` içindedir;
  `journal.previous.json` bir önceki kayıttır. Atomik yazım ve yalnız kullanıcıya
  açık dosya izinleri kullanılır; dosyalar ayrıca şifrelenmez. Bozuk veya daha
  yeni sürüm dosyası boş veriyle ezilmez. Normal uygulama çıkışı yazımı bekler.

Çevrimdışı ve gizli pencere regresyonu (gerçek sohbetlere dokunmaz):

```sh
swift build
BAVBAV_JOURNAL_CHECK=1 BAVBAV_CODEX_BIN="$PWD/.build/debug/BavbavFakeCodex" .build/debug/Bavbav
```

Yalnız yapay örneklerle gerçek Codex çıkarım testi (ek kullanım tüketir, kalıcı
sohbet oluşturmaz):

```sh
BAVBAV_JOURNAL_LIVE_CHECK=1 .build/debug/Bavbav
```

## Kontroller

Aşağıdaki tuşlar varsayılan atamalardır. Uygulamanın kısayolları Ayarlar →
Shortcuts sayfasından ayrı ayrı değiştirilebilir; macOS uygulama değiştiricisi
sisteme ait olduğu için bunun dışındadır.

- `⌘Tab` / `⇧⌘Tab`: macOS uygulama değiştiricisi; Bavbav Dock'ta ve bu listede görünür
- `⌘1`: Sol üst proje penceresini göster veya klavye odağını ona taşı
- `⌘2`: Sağ üst son 8 Codex sohbetini göster veya klavye odağını ona taşı
- `⌘3`: Sağ alttaki ayrı `CHAT` penceresini göster/odakla
- `⌘4`: Sol alttaki aktif-sohbet model, çaba ve limit penceresini göster/odakla
- `⌘5`: Yerel takvimi aç/odakla; tekrar basmak kapatmaz. `W/S` gün/not, `A/D` ay; `Space` gün → not → kaynak sohbet; `Q` geri/kapat. `E` düzenle, `⌫` silme onayı, `U` son silmeyi geri al, `P` otomatik notları durdur/aç, `R` bekleyen işi yeniden dene, `T` bugün. Düzenlerken `Q` normal harftir; `Enter` kaydeder, `⌘.` vazgeçer.
- `⌘X`: Üst ortadaki küçük genel ayar penceresini aç/odakla; tekrar basmak kapatmaz
- `Shift+W/A/S/D`: Yazı alanı odakta değilken üst/sol/alt/sağ pencereye geç; yazarken normal büyük harflerdir. `⌘A` metin seçer.
- `W` / `S`: Seçimi yukarı/aşağı taşı
- Kısa `Space`: Projeyi veya sohbeti aç
- `⌥Space`: ⌘1, ⌘2 ve ⌘3 listelerinde seçili proje veya sohbetin adını düzenle. Mevcut ad seçili gelir; `Enter` kaydeder, boş `Enter` veya `⌘.` vazgeçer. Projeler yalnızca Bavbav içindeki görünen adlarıyla değişir; klasör yolu sabit kalır. Sohbet adı Codex'e kaydedilir ve açık sohbet başlıkları güncellenir. ⌘3'ün `CHAT` düğmesi değişmez. Her bağlamın düzenleme, kaydetme ve vazgeçme tuşları ayarlarda ayrı ayrı değiştirilebilir.
- Uzun `Space`: Taşıma moduna gir; `W/S` ile taşı, `Space` ile kaydet
- `⌘1` penceresinde `Space+Enter`: Proje listesindeyken yeni proje, proje
  içindeyken yeni sohbet isim slotu aç; dolu `Enter` oluşturur, boş `Enter` iptal eder
- `Enter`: Açık sohbet penceresinde yazma alanını göster; proje seçiliyken yeni sohbet aç
- Sohbet içindeyken `Shift+Tab`: Komut, plan, dosya değişikliği ve araç mesajlarını göster/gizle. Senin mesajların, Codex yanıtları, düşünce özetleri ve alt ajan mesajları her iki görünümde de kalır. Yazarken de çalışır; taslağı değiştirmez.
- Sohbet ilk açıldığında son mesajdan başlar; geçmiş geç yüklense veya yanıt uzasa da alt konum korunur. Küçük trackpad hareketleri ve momentum dahil, yukarı kaydırıp okurken yeni mesajlar konumunu değiştirmez.
- Açık sohbetler arasında geçişte mevcut görünüm, okuma konumu ve metin seçimi korunur; geçmiş yenilenirken boş ekran gösterilmez. Q ile kapatmak görünümü ve pencere önbelleğini bırakır, arka plandaki Codex işini sonlandırmaz. Q sonrası yeniden açılış son mesajdan başlar.
- `B` / `End` (`Fn+→`): Yazmıyorken etkin sohbetin en altına git. Yukarı kaydırınca sağ altta çıkan küçük `↓` düğmesi de aynı işi yapar; diğer sohbetleri etkilemez.
- Yazarken `Enter`: Gönder; `Shift+Enter`: Yeni satır; `⌘.`: Yazma alanını gizle
- Yazma alanı boşken tekrar `Enter`: Yazma alanını kapat
- `⌘A`, `⌘C`, `⌘V`: Odaktaki metni seç, kopyala, yapıştır. Mesaj metnine
  tıklayıp `⌘A` yalnızca o mesajı seçer; `⌘C` kopyalar. Mesajlar salt okunurdur.
- YOU/CODEX yanında ince saat görünür. Sunucunun mesaj zamanı varsa kullanılır;
  yeni canlı mesajlarda ilk alınma zamanı saklanır. Tarih içermeyen eski kayıtlarda
  tahmini bir saat yerine `—` gösterilir.
- Aynı sohbetin Codex turu çalışırken gönderilen yeni mesaj sıraya eklenir
- `Space+Enter`: Sıra yönetimini aç/kapat
- Sıra yönetiminde kısa `Space`: Seçili mesajı çalışan Codex turuna hemen yönlendir
- Sıra yönetiminde uzun `Space` + `W/S`: Seçili mesajı sırada taşı; bırakınca kaydet
- Sıra yönetiminde `Q`: Seçili mesajı sıradan çıkarıp yazma alanına geri al
- `⌘H`: Uygulamayı macOS'un yerel gizleme işlemiyle gizle; `⌘Tab` veya Dock ile
  geri dönünce açık pencereler ve yazma durumu korunur
- `⌘Q`: Uygulamadan tamamen çık (tek başına `Q` ile pencere kapatmaktan farklıdır)
- `Q`: Yazma alanı kapalıyken aktif pencereyi kapat; yazarken normal `q` harfidir
- `⌘1` içindeki sohbet listesindeyken ilk `Q` seçili projeye geri döner;
  proje listesindeki ikinci `Q` pencereyi kapatır. Basılı tutmak iki adımı atlamaz.

`⌘1–4` birer aç/kapat anahtarı değildir. Aynı kısayola tekrar basmak görünür
pencereyi kapatmaz. `⌘1` ve `⌘2` hâlâ açık olan ilgili Codex sohbet pencerelerini,
`⌘4` ise ayarladığı aktif sohbeti kendi penceresiyle birlikte öne taşır; sayı
penceresi klavye odağını alır. Farklı sohbetler ayrı, hafifçe basamaklandırılmış
pencerelerde birlikte açık kalır. Listeden zaten
açık bir sohbeti seçmek o pencereyi öne getirir; yazma kapalıyken `Q` yalnız aktif
sohbet penceresini kapatır ve varsa önceki açık sohbete döner.

`⌘X` genel uygulama ayarlarını açar; `⌘4` hâlâ seçili sohbetin model ayarıdır.
Genel ayarlar ilk açılışta ekranın üst ortasında 360×320 punto yer kaplar, normal
macOS pencere seviyesinde çalışır ve köşelerinden boyutlandırılabilir. Bu kısayol
yalnız Bavbav içinde geçerlidir; diğer uygulamaların `⌘X` kes komutunu ele geçirmez.
Bavbav içinde yazarken de `⌘X` ayarları açar, metni kesmez. Pencereler arası
yönlendirme `Shift+W/A/S/D` ile yapılır; eski Command yön tuşları kullanılmaz.
Menü çubuğunda da Ayarlar öğesi vardır.

Ayarların ana sayfasında `W/S` ile **Shortcuts** veya **Görünüm** seçilir,
`Space/Enter` ile açılır. Shortcuts, her işlem ve her alternatif tuş için ayrı
satır sunar. Örneğin W ile yukarı gitmek, ↑ ile yukarı gitmek, dolu mesajı
göndermek ve boş yazma alanını kapatmak birbirinden bağımsızdır. Projeler,
projenin sohbetleri, kuyruk, takvim sayfaları ve ayarlar da ayrı bağlamlardır.

- Satırı seçip Enter veya Space ile tuş kaydını aç; yeni tuşlara basıp bırak.
  Önizlemede Enter uygular, Q vazgeçer, R yeniden kaydeder, D bu atamayı kapatır,
  geri silme tuşu yalnız bu atamayı varsayılana döndürür. Bu onay tuşları da ayrı
  satırlardan değiştirilebilir. Kayıt sürerken Q ve Enter da atanabilir.
- Tek tuş, değiştirici tuşlar ve birlikte basılan iki tuş desteklenir.
  Space + Enter hareketini örneğin Control + N olarak değiştirebilirsin.
  Uzun basışın tuşu kısa basıştan bağımsızdır; eşiği 200–2000 ms ayarlanabilir.
  Önizlemede W süreyi 20 ms azaltır, S artırır. Varsayılan eşik 440 ms'dir.
- Arama alanına tıkla veya kısayol listesinde Command + F kullan. Enter
  sonuç listesine döner; normal yazma ve pano işlemleri aramada korunur.
- Aynı bağlamdaki çakışmalar kaydedilmez. Yazarken sıradan harflerin mesaj
  göndermesini engelleyen doğrulama ve macOS'a ait Command + Tab koruması vardır.
  Kısa basış, uzun basış ve birleşimin başlangıcı aynı tuşu paylaşabilir.
- Ayarlar kullanıcıya özel `keyboard.bindings.v1` kaydında saklanır; anında
  uygulanır. Ekrandaki tuş ipuçları, native menüler ve beş global pencere tuşu
  aynı kaynaktan güncellenir. Global kayıt hatası değişikliği geri alır.
  Kayıt sırasında global tuşlar geçici bırakılır, kayıt bitince geri yüklenir.
- Üstteki sıfırlama düğmesi onaydan sonra yalnız kısayolları sıfırlar.
  Bozuk kayıt sessizce üzerine yazılmaz; güvenli varsayılanlar ve uyarı kullanılır.
  Hiçbir atama sohbet geçmişini, modeli veya pencere saydamlığını değiştirmez.

Kısayol regresyonu, gizli native pencereler ve yalnız yerel sahte Codex sunucusu
üzerinde tek gönderim/yanıt akışını da test eder:

```sh
swift build
BAVBAV_SHORTCUT_CHECK=1 BAVBAV_CODEX_BIN="$PWD/.build/debug/BavbavFakeCodex" .build/debug/Bavbav
```

Görünümde arka plan saydamlığı %0 (opak zemin) ile %100 (şeffaf zemin) arasındadır;
`W/S` −5/+5, `←/→` −1/+1 değiştirir, `Space/Enter` %0'a döndürür. Değer anında
uygulanır ve kaydedilir. Alt bölümde `Q` ana sayfaya döner, ana sayfada `Q` ayarı
kapatıp mümkünse önceki pencereye döner.

Saydamlık yalnızca arka plan dolgularına uygulanır: yazılar, çizgiler, ikonlar,
logolar ve kontrollerin netliği değişmez. Mesaj/kod balonları ve genel ayarlar da
aynı ayarı kullanır; mevcut, gizli ve sonradan açılan sohbetlerde değer korunur.
%100'de yalnız zemin kaybolur; pencereler tıklanabilir, klavyeyle yönetilebilir
kalmaya devam eder. Hesap giriş popup'ları değiştirilmez. `Space` ayarı sıfırlar.
Klavye odağı olan pencere 0,8 punto ince yeşil bir çizgiyle belirtilir; odak başka
pencereye taşınınca çizgi de taşınır. Başka uygulamaya geçince çizgi kaybolur.
Saydamlıktan etkilenmez, tıklama ve köşeden boyutlandırmayı engellemez.

%35 üzerindeki saydamlıkta yazı kontrastı kademeli artar: metin tam opak kalır,
ince koyu kenar/gölge açık zemin üzerinde ayrışmasını sağlar. Bu destek pencere
zeminini yeniden boyamaz; metin, kod kopyalama, seçim ve formül düzenini değiştirmez.

`⌘3` küçük CHAT menüsünü açar: üstte yeni sohbet açan `CHAT`, altında bu kanaldaki
son üç sohbet vardır. `W/S` seçer, kısa `Space` açar, uzun `Space` + `W/S` sıralar.
Yeni sohbet önceki pencereleri kapatmaz. Mesaj ekranı ortak native `ChatDetailView`
üzerindedir; yalnız kanal başlığı `CHANNEL / ChatGPT`, proje etiketi `PROJESİZ` olur.
Enter ile yazma, boş Enter ile kapatma, Q, Shift+Tab, model/çaba, formüller, kopyalama,
saydamlık ve odak çizgisi normal Codex sohbetleriyle aynı davranır.

Bu kanal ChatGPT web geçmişiyle senkronize değildir; mevcut Codex App Server
bağlantısını kullanır ([resmî protokol](https://learn.chatgpt.com/docs/app-server)).
Proje bağlamı yerine uygulamanın Application Support/Bavbav/StandaloneChats dizini
kullanılır. Bu dizin ve kanal sohbetleri Bavbav'ın proje ve Codex-son-sohbet listesine
eklenmez. Kanal kimlikleri ve sıralama yerel ayarlarda saklanır; mesaj geçmişi aynı
App Server üzerinden tekrar okunur. Eski web hesabının oturumu/geçmişi silinmez.

Bavbav pencereleri normal macOS pencere seviyesindedir. Kısayolla öne gelirler;
Safari, Haritalar veya başka bir uygulamaya dönüldüğünde onun arkasına geçebilirler.
Bavbav artık yardımcı/menü-çubuğu uygulaması değil, Dock ve `⌘Tab` içinde görünen
normal bir uygulamadır; standart uygulama ve Düzenle menüleri vardır. Pencereleri
tıklamak uygulamayı etkinleştirir. `⌘Tab` tuşlarına uygulama müdahale etmez;
uygulamadan ayrılırken bekleyen uzun-Space hareketi iptal edilir. `Q` ile tüm
pencereler kapatılmışsa Dock'tan ya da uygulama değiştiricisinden dönüşte PROJECTS
açılır; hâlâ açık pencereler varsa konumları ve odakları zorla değiştirilmez.
Tüm Bavbav panelleri yalnızca dört köşesinden sürüklenerek boyutlandırılır; köşeye
gelince çapraz boyutlandırma imleci görünür. Kenarlar boyutlandırma yapmaz, koyu
çerçevesiz tasarım korunur. Okunabilir minimum boyut ve ekran sınırı uygulanır.
Boyut sürükleme bitince bir kez kaydedilir; yeniden açılışta ve uygulama yeniden
başladığında korunur. Codex sohbetleri kendi boyutunu, CHAT'in küçük ve büyümüş
görünümleri birbirinden ayrı boyutlarını hatırlar.

Codex masaüstünün hâlen yazarı olduğu bir sohbet ikinci App Server sürecinden
doğrudan yazmaya kapalıysa Bavbav konuşmayı o noktadan sessizce çatallar, aynı
ekranda yeni yazılabilir kola geçer ve mesajı bir kez gönderir. Eski kol Bavbav
listelerinde gizlenir; Codex masaüstündeki özgün sohbet değişmeden kalır. Mesaj
taslakları uygulama yeniden başlatılsa da korunur.

Geçmiş Codex sohbetleri salt okunur değildir: sohbeti açıp `Enter` ile doğrudan
yazılabilir. Başka bir sohbet o sırada çalışıyor olsa bile mesaj seçili geçmiş
sohbette hemen başlar. Sıra yalnızca aynı sohbetin hâlihazırda çalışan turuna ait
ek mesajlar için kullanılır.

Görünür sohbet, yerel canlı tur yokken dört saniyede bir geçmişten eşitlenir.
Canlı tur kendi olay akışını kullanır. Aynı anda ikinci bir geçmiş okuması
başlatılmaz; eski bir okuma yeni canlı içeriğin üzerine yazılmaz.

`Q` yalnızca sohbet penceresini kapatır: Bavbav ve çalışan Codex turu arka planda
devam eder. Kapatılan pencerenin görünümü, mesajları ve TRACE içeriği bellekten
bırakılır; turun kimliği ve gönderim sırası korunur. Yeniden açılan çalışan sohbet
kayıtlı düşünce ve alt ajan etkinliklerini yeniden yükler. Komut görünürlüğü her
sohbet için ayrı saklanır; varsayılan kapalıdır, çalışan bir sohbeti açmak bunu
zorla değiştirmez. `Shift+Tab` komut ayrıntılarını açar/kapatır. Kapalıyken araç
çıktıları UI belleğinde biriktirilmez; düşünce ve alt ajan kayıtları korunur.
Tüm pencereler gizliyken periyodik katalog/geçmiş okumaları yapılmaz.
Uygulamadan tamamen çıkmak veya bilgisayarı kapatmak bu arka plan davranışının
dışındadır.

`⌘4`, seçili sohbetin son gerçek model ve effort değerini otomatik olarak okur.
Kullanıcı bir değer seçerse bu seçim sohbet için saklanır; `AUTO` seçeneği tekrar
sohbetin son ayarını izler.

Hesabın model kataloğunda `gpt-6-astra` varsa `GPT-6 ASTRA`, `AUTO` satırının
hemen altında görünür. Çaba seçenekleri sunucudan gelir. `⌘4` açılınca katalog
en fazla beş dakikada bir ayrı, kısa ömürlü bağlantıyla tazelenir; çalışan sohbet
bağlantıları yeniden başlatılmaz. Model eklenmesi mevcut sohbet seçimini değiştirmez.

Bavbav'dan açılan ve devam ettirilen Codex sohbetleri varsayılan olarak tam erişim
modundadır (`danger-full-access`, `approvalPolicy: never`). Komut, dosya ve ağ
işlemleri için onay kartı gösterilmez. Bu mod yalnız Bavbav'ın başlattığı turlara
uygulanmak üzere her mesajda yeniden doğrulanır ve sohbetin sonraki turlarına
aktarılır. Bağlı uygulamaların formları ve Codex'in gerçekten kullanıcı yanıtı
gerektiren soruları normal klavye akışında görünmeye devam eder.

## Derleme

```sh
swift run BavbavChecks
zsh scripts/build-app.sh
open dist/Bavbav.app
```

Zengin mesajların çevrimdışı regresyon ve görsel kontrolü:

```sh
swift build
BAVBAV_RICH_MESSAGE_CHECK=1 .build/debug/Bavbav
BAVBAV_RICH_MESSAGE_CHECK=1 BAVBAV_RICH_MESSAGE_SNAPSHOT_DIR=/tmp/bavbav-rich-message-review .build/debug/Bavbav
```

Kontrol gizli native görünümler üzerinde çalışır; kullanıcıya pencere açmaz veya
gerçek sohbete mesaj göndermez. Son komut 320/700 punto genişliğinde PNG örnekleri
üretir. Paketleme ayrıca aynı kontrolü imzalı `.app` üzerinde çalıştırır ve fontların
geliştirme klasöründen değil uygulamanın içinden yüklendiğini doğrular.

Sohbet kaydırmanın çevrimdışı regresyon kontrolü (geç yüklenen geçmiş, canlı yanıt,
yeniden boyutlandırma, okuma konumu, B/End ve pencere ayrımı; gizli SwiftUI/AppKit
pencereleri, gerçek hesaba veya açık uygulamaya dokunmaz):

```sh
BAVBAV_SCROLL_CHECK=1 .build/debug/Bavbav
```

Kaydırma/geçiş regresyonları ayrıca iki uzun geçmişte 100 hızlı ve 20 çizimi
tamamlanan geçişi, native görünüm kimliğini, metin seçimini, gecikmiş odak yarışını,
mesaj listesi önbelleğini ve Q sonrası bellek bırakılmasını sınar:

```sh
BAVBAV_PERFORMANCE_CHECK=1 BAVBAV_CODEX_BIN="$PWD/.build/debug/BavbavFakeCodex" .build/debug/Bavbav
```

Bu kontrol gizli gerçek AppKit/SwiftUI pencereleri ve yerel sahte sunucu kullanır;
canlı hesap veya ekrandaki uygulama üzerinde FPS/trackpad ölçümü değildir. Her iki
kontrol de paketleme sırasında imzalı uygulamada tekrar çalışır.

Ad düzenlemenin çevrimdışı kontrolü (proje adı kalıcılığı, sohbet adı kaydı,
aktif ve arka plandaki başlıklar, eski katalog yanıtları, sunucu hatası, native
metin düzenleme ve bağımsız kısayollar; gizli pencereler ve yerel sahte sunucu):

```sh
BAVBAV_RENAME_CHECK=1 BAVBAV_CODEX_BIN="$PWD/.build/debug/BavbavFakeCodex" .build/debug/Bavbav
```

Gerçek Codex bağlantı testini ayrıca çalıştırmak için:

```sh
swift run BavbavChecks --integration
```

Kalıcı sohbet oluşturmadan gerçek mesaj akışını sınamak için:

```sh
swift run BavbavChecks --integration --integration-turn
```

Tam etkinlik zaman çizgisini ve bütün kayıtlı sohbetleri doğrulamak için:

```sh
swift run BavbavChecks --integration --integration-activity
swift run BavbavChecks --integration --integration-all-history
```

Onay, izin, soru ve uygulama-formu JSON-RPC cevaplarını yerel güvenli sunucu
taklidiyle sınamak için (aktif-yazar devir akışı da buna dahildir):

```sh
swift build --product BavbavFakeCodex
BAVBAV_CODEX_BIN="$PWD/.build/debug/BavbavFakeCodex" swift run BavbavChecks --protocol-fixture
```

Proje dışı native kanalı gerçek hesaba mesaj göndermeden sınamak için:

```sh
swift build
BAVBAV_STANDALONE_CHECK=1 BAVBAV_CODEX_BIN="$PWD/.build/debug/BavbavFakeCodex" .build/debug/Bavbav
```

Kontrol sahte sunucuyla oluşturma, gönderme, geçmişi yeniden açma, proje ayrımı,
son üç sohbet ve sıralama akışlarını sınar. WebKit oluşturulmaz, pencere öne gelmez.

Köşe boyutlandırmasını ekranı öne getirmeden, gerçek sohbetlere dokunmadan sınamak için:

```sh
BAVBAV_RESIZE_CHECK=1 .build/debug/Bavbav
BAVBAV_APP_SWITCH_CHECK=1 .build/debug/Bavbav
BAVBAV_PREFERENCES_CHECK=1 .build/debug/Bavbav
```

Bu kontrol dört köşeyi, sabit karşı köşeyi, ekran/minimum sınırlarını, fare olaylarını,
içerik değişirken süren sürüklemeyi ve panel/sohbet/CHAT boyutlarının saklanmasını
geçici ve ayrı bir ayar alanında doğrular.
Uygulama-geçiş kontrolü normal uygulama politikasını, pencere odaklanma özelliklerini,
`⌘Tab`/`⇧⌘Tab` olaylarının değiştirilmeden geçirilmesini ve yerel Gizle/Çık menüsünü
sınar. Kullanıcının ön plandaki uygulamasını değiştirerek görsel bir uçtan uca
`⌘Tab` testi yapmaz.

Genel ayarlar kontrolü ayrı/geçici bir ayar alanında saydamlık sınırlarını,
kalıcılığı, yeni/gizli sohbet pencerelerini ve klavye akışını test eder. Pencereler
öne getirilmez. `BAVBAV_PREFERENCES_SNAPSHOT_DIR=/tmp/bavbav-preferences-review`
eklenirse ayar ekranlarının PNG örnekleri de kaydedilir.
