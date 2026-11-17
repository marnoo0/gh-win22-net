gh-win22-net

شغّل Windows Server 2022 على GitHub Actions، ووصّله بجهازك عبر Tailscale، واخرج بالإنترنت من شبكة Azure.

---

1. الملفات اللي في المشروع

gh-win22-net/
├── .github/
│   └── workflows/
│       └── win2022.yml          ← التشغيل والتشغيل التلقائي
├── scripts/
│   └── setup-runner.ps1         ← كل الإعداد جوه الجهاز
├── client/
│   ├── set-proxy.ps1            ← يشغّل البروكسي على جهازك
│   └── clear-proxy.ps1          ← يوقف البروكسي
└── README.md                    ← الملف ده

جاهز بالكامل: win2022.yml و setup-runner.ps1 و client/*.
مش جاهز ومحتاج منك: إنشاء الريبو، مفتاح Tailscale، تشغيل الـ workflow. كلها مشروحة تحت خطوة خطوة.

---

2. إيه اللي بيحصل بالظبط

1. جيت هوب بتشغّل.Windows Server 2022 (مجاني، ريبو عام)
2. السكربت بينصّب Tailscale ويدخل الجهاز في شبكتك الخاصة
3. بينصّب sing-box ويفتح بروكسي جوه الجهاز
4. البروكسي مقفول على شبكة Tailscale بس — مفيش وصول من الإنترنت
5. جهازك بيتصل بالبروكسي → كل ترافيكك يخرج من Azure
6. بعد 5 ساعات و50 دقيقة الجهاز بيتمسح لوحده

المنافذ:

المنفذ  الخدمة  متاح لمين

1080  SOCKS5  أجهزتك في الـ tailnet بس
1081  HTTP proxy  أجهزتك في الـ tailnet بس
3389  RDP  أجهزتك في الـ tailnet بس

---

3. الخطوات — الجزء اللي عليك

الخطوة 1 — اعمل ريبو عام جديد

افتح https://github.com/new
الاسم: gh-win22-net
اختار Public
متعلّمش على أي حاجة تانية
اضغط Create repository

---

الخطوة 2 — ارفع الملفات

من الموقع (الأسهل):

في الريبو الفاضي، اضغط uploading an existing file
اسحب المجلد gh-win22-net بالكامل من جهازك
في خانة الـ commit اكتب: init
اضغط Commit changes

من الطرفية (لو عندك git):

cd gh-win22-net
git init
git add .
git commit -m "init"
git branch -M main
git remote add origin https://github.com/<اسمك>/gh-win22-net.git
git push -u origin main

تحقق: افتح تبويب Actions في الريبو. لازم تشوف win2022-egress في القائمة الشمال.

---

الخطوة 3 — اعمل مفتاح Tailscale

افتح https://login.tailscale.com/admin/settings/keys
اضغط Generate auth key...
اختار الإعدادات دي بالظبط

الإعداد  القيمة  ليه

Reusable  ✅ مفعّل  عشان تشغّل أكتر من مرة
Ephemeral  ✅ مفعّل  الجهاز يطلع من الشبكة لوحده بعد ما يتمسح
Expiration  90 days  أقصى مدة
Tags  سيبه فاضي  مش لازم

اضغط Generate key
انسخ المفتاح (tskey-auth-...) — بيظهر مرة واحدة بس

---

الخطوة 4 — حط المفتاح في أسرار الريبو

في الريبو: Settings → Secrets and variables → Actions
اضغط New repository secret
الاسم: TS_AUTHKEY (بالظبط، حروف كبيرة)
القيمة: المفتاح اللي نسخته
Add secret

اختياري بس مستحسن: سر تاني بنفس الطريقة

الاسم  القيمة

RDP_PASSWORD  باسورد قوي من اختيارك لكلمة سر الدخول

لو مش حاططه، السكربت بيولّد باسورد عشوائي وبيطبعه في الـ log. والـ log في ريبو عام أي حد يقدر يقراه. المنفذ مش مكشوف للإنترنت (محتاج يكون في الـ tailnet عشان يوصله) بس برضه الأفضل تحطه.

---

الخطوة 5 — فعّل الـ workflow

Actions → win2022-egress (من القائمة الشمال)
لو ظهرت رسالة تفعيل، اضغط I understand my workflows, go ahead and enable them
اضغط Run workflow (يمين)
الإعدادات

الخانة  القيمة

Runtime in minutes  350
Enable RDP  true
proxy_user  سيبها فاضية
proxy_pass  سيبها فاضية

اضغط Run workflow الأخضر

انتظر 2–4 دقايق لحد ما تلاقي في الـ log

=== ready ===
runner public IPv4 : 20.x.x.x
SOCKS5             : 100.x.x.x:1080  (or win-runner:1080)
HTTP proxy         : 100.x.x.x:1081  (or win-runner:1081)
RDP                : 100.x.x.x:3389   user runneradmin
deadline           : 2026-11-17 ...

سجّل الـ IP بتاع 100.x.x.x — هتحتاجه لو MagicDNS مش شغال.

---

الخطوة 6 — نصّب Tailscale على جهازك

حمّل من https://tailscale.com/download/windows
نصّب وافتح
سجّل دخول بنفس الحساب اللي عملت بيه المفتاح
تأكد إن win-runner ظاهر في القائمة (أيقونة Tailscale في شريط المهام)

مهم: شغّل Tailscale وانتظر لحد ما يبقى Connected قبل أي خطوة تانية.

---

الخطوة 7 — اتصل

الطريقة الأولى — البروكسي (تلقائي):

في PowerShell على جهازك، من مجلد client

.\set-proxy.ps1 -Test

لو ظهرلك egress IPv4 -> 20.x.x.x يبقى شغال. الرقم ده IP مايكروسوفت، مش IP بيتك.

الطريقة الثانية — RDP:

mstsc /v:win-runner

المستخدم: runneradmin
الباسورد: اللي حطيته في RDP_PASSWORD أو اللي في الـ log

لو الاسم مش شغال، استخدم الـ IP

mstsc /v:100.x.x.x

---

الخطوة 8 — أوقف

.\clear-proxy.ps1

أو من جيت هوب: Actions → الـ run الجاري → Cancel workflow.

---

4. لو win-runner مش بيتحل

الاسم ده محتاج MagicDNS مفعّل

https://login.tailscale.com/admin/dns
تحت MagicDNS اضغط Enable MagicDNS

لو مش عايز تفعّله، استخدم الـ IP اللي في الـ log في كل الأوامر

.\set-proxy.ps1 -ProxyHost 100.x.x.x
mstsc /v:100.x.x.x

---

5. الأخطاء الشائعة

الأعراض  السبب  الحل

Secret TS_AUTHKEY is empty  السر مش متضاف أو اسمه غلط  Settings → Secrets، الاسم لازم TS_AUTHKEY بالظبط
tailscale up failed  المفتاح خلص أو اتلغي  اعمل مفتاح جديد
win-runner مش بيتحل  MagicDNS مقفول  الخطوة 4 فوق
البروكسي مش شغال  الـ workflow خلص أو اتلغى  شوف Actions، شغّله تاني
node never received a tailnet address  Tailscale مش قادر يوصل  عيد تشغيل الـ workflow
المواقع بتطلب captcha  IP داتا سنتر  مفيش حل — طبيعة الموضوع
البطء في البداية  تجهيز الجهاز  طبيعي، 2–4 دقايق
sing-box died  المنفذ مشغول أو الكونفيج مرفوض  الـ log بيطبع السبب، شغّل تاني

---

6. الحدود

الحد  القيمة

أقصى مدة للتشغيل  6 ساعات (السكربت بيقف عند 5:50)
عدد التشغيلات المتوازية  1 (مقفول في الـ workflow)
الدقايق المجانية  غير محدودة للريبو العام
الـ IP  بيتغيّر كل تشغيل
التخزين  بيتمسح مع الجهاز
سيرفر ويب عام  مش ممكن — مفيش بورت داخل

---

7. اللي مش موجود

مفيش إعداد تلقائي بعد 6 ساعات. لازم تدوس Run workflow تاني. تقدر تعمل schedule في الملف لو عايز، بس كل تشغيل بياخد جهاز جديد فالاتصال بيقطع ويرجع.
مفيش VPN كامل جوه النظام. اللي جاهز هو بروكسي HTTP/SOCKS. لو عايز VPN كامل، ده تعديل على setup-runner.ps1 (نضيف inbound من نوع tun).
الريبو العام = الـ logs عامة. السكربت مبيكتبش المفتاح في أي مكان، لكن أي حاجة تطبعها إنت هتبقى ظاهرة.
