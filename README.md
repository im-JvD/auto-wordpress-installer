# 🚀 استقرار خودکار و ایزوله وردپرس در داکر (Auto WordPress Installer)

<div align="center">

![Version](https://img.shields.io/badge/version-v1.0.0-blue.svg?style=for-the-badge)
![License](https://img.shields.io/badge/license-MIT-green.svg?style=for-the-badge)
![Docker](https://img.shields.io/badge/Docker-2496ED?style=for-the-badge&logo=docker&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![WordPress](https://img.shields.io/badge/WordPress-21759B?style=for-the-badge&logo=wordpress&logoColor=white)
![OpenLiteSpeed](https://img.shields.io/badge/OpenLiteSpeed-283890?style=for-the-badge&logo=litespeed&logoColor=white)
![Nginx](https://img.shields.io/badge/Nginx-009639?style=for-the-badge&logo=nginx&logoColor=white)
![MariaDB](https://img.shields.io/badge/MariaDB-003545?style=for-the-badge&logo=mariadb&logoColor=white)
![Cloudflare](https://img.shields.io/badge/Cloudflare-F38020?style=for-the-badge&logo=cloudflare&logoColor=white)

**یک تولکیت خودکار، فوق‌سریع و کاملاً ایزوله به زبان Bash جهت راه‌اندازی و مدیریت یکپارچه وردپرس سازمانی روی سرورهای لینوکس با Docker**

[مشاهده در گیت‌هاب](https://github.com/im-JvD/auto-wordpress-installer) • [گزارش باگ / پیشنهاد](https://github.com/im-JvD/auto-wordpress-installer/issues)

</div>

---

## 📌 فهرست مطالب (Table of Contents)

- [معماری سیستم](#-ساختار-معماری-architecture-overview)
- [ویژگی‌های کلیدی و مزایا](#-ویژگیهای-کلیدی-و-مزایا)
- [نصب سریع (Quick Start)](#-نصب-سریع-با-دستور-تکخطی-quick-start)
- [دستور اختصاصی CLI سراسری](#-دسترسی-سریع-با-دستور-اختصاصی-wordpress)
- [ساختار منوی اصلی](#-ساختار-منوی-اصلی-categorized-main-menu)
  - [۱. استقرار و بازگردانی](#1-استقرار-و-بازگردانی-deployment--restoration)
  - [۲. مدیریت دیتابیس](#2-مدیریت-پیشرفته-دیتابیسها-database-management)
  - [۳. پایش و عملیات سرویس‌ها](#3-عملیات-و-پایش-سرویسها-service-operations)
  - [۴. نگهداری و بروزرسانی‌ها](#4-نگهداری-و-بروزرسانیها-maintenance--updates)
  - [۵. حذف کامل و ایمن](#5-حذف-کامل-و-ایمن-complete-uninstall)
- [پکیج کامل اکستنشن‌های PHP](#-پکیج-کامل-اکستنشنهای-php-php-extensions-suite)
- [سازگاری با هوش مصنوعی و پروتکل MCP](#-سازگاری-با-هوش-مصنوعی-و-پروتکل-mcp)
- [نحوه بازگردانی بکاپ (Duplicator و Backupino)](#-نحوه-بازگردانی-بکاپ-با-duplicator-یا-backupino)
- [اتصال به کلودفلر و پورت‌های سفارشی](#-راهنمای-اتصال-با-cloudflare-و-پورتهای-جایگزین-اختیاری)
- [ساختار فایل‌های پروژه](#-ساختار-فایلهای-پروژه-directory-structure)
- [نکات کلیدی امنیت](#-نکات-کلیدی-امنیت-security-highlights)
- [لایسنس](#-لایسنس)

---

## 🏗 ساختار معماری (Architecture Overview)

```text
                       [ Host Ports 80 & 443 / 8443 / 2087 ]
                                         │
                                         ▼
                    ┌─────────────────────────────────────────┐
                    │  Dual Web Server Engine (Zero-Downtime) │
                    │   OpenLiteSpeed (HTTP/3)  OR  Nginx     │
                    └────────────────────┬────────────────────┘
                                         │
                     ┌───────────────────┴───────────────────┐
                     │                                       │
                     ▼                                       ▼
           ┌───────────────────┐                   ┌───────────────────┐
           │   Certbot (ACME)  │                   │  PHP-FPM / LSAPI  │
           │ (Auto-renew loop) │                   │ (Watchdog 2s Loop)│
           └───────────────────┘                   └─────────┬─────────┘
                                                             │
                                                             │ Internal Bridge Network
                                                             ▼ (Port 3306 - Not Bound to Host)
                                                   ┌───────────────────┐
                                                   │ MariaDB 10.11 LTS │
                                                   │ (wp_db container) │
                                                   └───────────────────┘
```

---

## ✨ ویژگی‌های کلیدی و مزایا

- **سوییچ زنده بین وب‌سرورها (OpenLiteSpeed ⇄ Nginx):** امکان تغییر فوری موتور وب‌سرور بین OpenLiteSpeed (دارای LSCache بومی و پروتکل HTTP/3 QUIC) و Nginx پایدار و سبک، بدون از دست رفتن فایل‌ها یا دیتابیس.
- **تغییر نسخه PHP با یک کلیک:** پشتیبانی کامل از PHP 7.4 تا 8.3 و سوییچ خودکار بدون درگیری با مخازن لینوکس.
- **ناظر خودکار و پایداری بالا (Watchdog Supervisor):** مجهز به حلقه مانیتورینگ پیوسته در پس‌زمینه که پروسس‌های PHP را رصد کرده و در صورت هرگونه توقف ظرف کمتر از ۲ ثانیه بدون خطای 503 آن را احیا می‌کند.
- **عدم تداخل پورت دیتابیس:** پورت `3306` **هرگز روی سرور هاست باز (Expose) نمی‌شود**؛ بنابراین هر دیتابیس دیگری روی سرور کاملاً امن و دست‌نخورده باقی می‌ماند.
- **اسکن ایمن و فقط-خواندنی پورت‌ها (Read-Only Check):** پورت‌های `80` و `443` بررسی می‌شوند و در صورت اشغال توسط سایر سرویس‌ها، پورت‌های سازگار کلودفلر (مثل `2087` یا `8443`) به صورت هوشمند پیشنهاد داده می‌شوند.
- **پشتیبانی ویژه از مهاجرت و بازگردانی:** حالت اختصاصی برای بازگردانی سریع بکاپ با Duplicator و Backupino بدون نیاز به نصب خام وردپرس.

---

## ⚡ نصب سریع با دستور تک‌خطی (Quick Start)

کافیست دستور زیر را کپی کرده و در ترمینال سرور لینوکس خود (اوبونتو، دبیان و...) با دسترسی روت اجرا کنید:

```bash
git clone https://github.com/im-JvD/auto-wordpress-installer.git /opt/wp-docker && cd /opt/wp-docker && chmod +x setup.sh scripts/*.sh && sudo ./setup.sh
```

---

### 💻 دسترسی سریع با دستور اختصاصی `wordpress`

پس از اولین اجرا، دستور سیستمی `wordpress` در سرور شما ثبت می‌شود و از هر مسیری تنها با تایپ دستور زیر منو باز می‌شود:

```bash
wordpress
```

---

## 📋 ساختار منوی اصلی (Categorized Main Menu)

```text
  https://github.com/im-JvD/auto-wordpress-installer
====================================================================
       WordPress & Docker Stack Manager (Isolated) - [v1.0.0]
       Automated, High-Performance & Secure WordPress Stack
====================================================================

     1. Deploy & Restore (Fresh WordPress / Migration / Backup)
     2. Manage Database (Create, Delete, Credentials, phpMyAdmin)
     3. Service Control (Start, Stop, Restart, Stats, Live Logs)
     4. Maintenance & Updates (Switch Web Server/PHP, Self-Update)
     5. Uninstall Stack (Clean, Isolated & Safe Purge)

     0. Exit

====================================================================
```

---

### [1] استقرار و بازگردانی (Deployment & Restoration)
* **Deploy Fresh WordPress:** راه‌اندازی صفر تا صد وردپرس خام با وب‌سرور انتخابی، PHP، دیتابیس ایزوله، سرتیفیکیت SSL و شبکه اختصاصی.
* **Deploy Stack for Migration / Restore:** آماده‌سازی تمام زیرساخت‌ها با مقادیر بهینه‌شده برای فایل‌های حجیم و پوشه وب آماده برای ریستور توسط Duplicator یا Backupino.

### [2] مدیریت پیشرفته دیتابیس‌ها (Database Management)
* **مشاهده مشخصات و لیست دیتابیس‌ها:** نمایش هاست (`db`)، یوزر، رمز عبور اصلی و روت، به همراه فهرست تمامی دیتابیس‌های فعال.
* **ایجاد دیتابیس و کاربر جدید:** ساخت آسان دیتابیس‌های اضافی با دسترسی‌های تفکیک‌شده.
* **حذف ایمن دیتابیس:** امکان حذف دیتابیس‌های غیرضروری با تاییدیه دو مرحله‌ای و حفاظت از دیتابیس‌های سیستمی.
* **اجرای phpMyAdmin تحت وب:** راه‌اندازی با یک کلیک و در صورت نیاز (On-Demand) پنل گرافیکی phpMyAdmin روی پورت دلخواه (پیش‌فرض ۸۰۸۰).
* **توقف phpMyAdmin:** غیرفعال‌سازی و بستن آنی phpMyAdmin جهت حفظ کامل امنیت و آزادسازی حافظه رم سرور.

### [3] عملیات و پایش سرویس‌ها (Service Operations)
* **Start / Restart Services:** اجرای مجدد یا ری‌استارت تمام کانتینرهای استک (OpenLiteSpeed / Nginx, WordPress, Database, Certbot).
* **Stop Services:** متوقف کردن امن تمام کانتینرها بدون حذف دیتابیس یا فایل‌ها (آزادسازی فوری پورت‌ها و منابع پردازنده و رم).
* **Service Status & Stats:** مشاهده وضعیت سلامت کانتینرها (Healthcheck)، میزان مصرف پردازنده و رم، و تست زنده پاسخ‌دهی سایت.
* **View Service Logs:** مشاهده لاگ‌های اختصاصی وب‌سرور، سرویس PHP، دیتابیس، تمدید خودکار Certbot یا استریم زنده تمامی لاگ‌ها.
* **Auto-Start on Boot (systemd):** فعال‌سازی و ساخت خودکار سرویس سیستمی `wp-docker.service` جهت اجرای خودکار تمام کانتینرهای استک پس از ریبوت سرور.

### [4] نگهداری و بروزرسانی‌ها (Maintenance & Updates)
* **Switch / Change Web Server:** جابجایی و تغییر آنی و کاملاً ایمن بین وب‌سرورهای OpenLiteSpeed و Nginx بدون داون‌تایم.
* **Switch / Change PHP Version:** تغییر و سوییچ آنی نسخه PHP به هر کدام از نسخه‌های دلخواه (PHP 7.4, 8.0, 8.1, 8.2, 8.3) با یک کلیک.
* **Update Container Images:** دریافت آخرین نسخه‌های پایدار ایمیج‌های داکر و بازسازی مجدد کانتینرها بدون از دست رفتن اطلاعات.
* **Self-Update Script:** همگام‌سازی و بروزرسانی مستقیم و هوشمند اسکریپت از مخزن رسمی گیت‌هاب با یک کلیک.

### [5] حذف کامل و ایمن (Complete Uninstall)
* حذف با تاییدیه متنی `yes`.
* متوقف کردن و حذف **فقط و فقط** کانتینرها، ولوم‌ها و شبکه مرتبط با این پروژه بدون دستکاری به سایر سرویس‌های سرور.

---

## 🧩 پکیج کامل اکستنشن‌های PHP (PHP Extensions Suite)

تمامی اکستنشن‌های ضروری و توصیه شده برای اجرای روان **WooCommerce**، **Elementor Pro**، **Duplicator** و افزونه‌های چندزبانه به صورت پیش‌فرض کامپایل و فعال شده‌اند:

| نام افزونه | کاربرد و ضرورت |
| :--- | :--- |
| **`pdo_mysql` & `mysqli`** | اتصال و کوئری پایگاه‌داده، پیش‌نیاز حیاتی نصاب داپلیکیتور و بکاپینو |
| **`curl`** | ارتباط با APIها، وب‌سرویس‌ها و اعتبارسنجی درگاه‌های پرداخت |
| **`zip`** | خروج از حالت فشرده و ساخت بسته‌های پشتیبان و آپدیت خودکار افزونه‌ها |
| **`intl` & `mbstring`** | مدیریت کاراکترهای یونیکد، زبان‌های فارسی و راست‌چین و ماژول مالی ووکامرس |
| **`bcmath`** | محاسبات اعشاری دقیق با دقت بالا جهت تسویه‌حساب فروشگاه‌ها |
| **`imagick` & `gd`** | تغییر سایز، فشرده‌سازی با کیفیت و تبدیل خودکار به فرمت نسل جدید WebP |
| **`exif` & `fileinfo`** | شناسایی ایمن نوع فایل‌ها و چرخش خودکار متادیتای عکس‌های بارگذاری‌شده |

---

## 🤖 سازگاری با هوش مصنوعی و پروتکل MCP

این استک به طور پیش‌فرض دارای بازنویسی هدرهای احراز هویت (`HTTP_AUTHORIZATION`) و رول‌های Rewrite برای آدرس‌های REST API (`/wp-json/*`) و کشف اوت (`/.well-known/oauth-*`) است. بنابراین کلاینت‌های هوش مصنوعی و اکستنشن‌های MCP (مانند Gemini Desktop، Claude Code و Cursor) می‌توانند بدون خطای ۴۰۴ یا مسدودسازی هدرهای احراز هویت مستقیماً به سرور متصل شوند.

---

## 📦 نحوه بازگردانی بکاپ با Duplicator یا Backupino

1. از منوی اسکریپت گزینه `1` سپس `2` (حالت Migration / Restore) را انتخاب کنید.
2. نسخه PHP دلخواه خود (مثلاً 8.3 یا 8.2) را انتخاب کنید.
3. پس از پایان عملیات، مشخصات دیتابیس نمایش داده شده را یادداشت کنید:
   * **Database Host:** `db`
   * **Database Name:** *(نام انتخابی شما)*
   * **Database User:** *(کاربر انتخابی شما)*
   * **Database Password:** *(رمز عبور انتخابی شما)*
4. فایل‌های `installer.php` و آرشیو بکاپ (فایل ZIP) را داخل پوشه میانبر زیر قرار دهید:
   👉 **`/opt/wp-docker/html`** *(این پوشه توسط اسکریپت ایجاد شده و در نرم‌افزارهای WinSCP یا FileZilla مستقیماً در دسترس است)*
5. آدرس نصاب را در مرورگر باز کنید (مثال: `https://yourdomain.com/installer.php`).
6. مراحل بازگردانی را طی کرده و برای هاست دیتابیس کلمه **`db`** را وارد نمایید.

---

## 🌐 راهنمای اتصال با Cloudflare و پورت‌های جایگزین (اختیاری)

اگر پورت ۴۴۳ سرور شما توسط سرویس دیگری اشغال شده باشد، اسکریپت پورت‌های استاندارد کلودفلر (مانند `2087` یا `8443`) را پیشنهاد می‌دهد. برای هدایت تمیز دامنه بدون نیاز به وارد کردن شماره پورت در مرورگر:

1. **تنظیم SSL/TLS روی حالت Full:**  
   در پنل کلودفلر وارد دامنه شده و از بخش **SSL/TLS** وضعیت را روی **Full** یا **Full (strict)** قرار دهید.
2. **پنهان‌سازی پورت با Origin Rules:**  
   در داشبورد کلودفلر به مسیر **Rules** > **Overview** رفته و از قالب **Change port** استفاده کنید:
   * فیلد **Hostname** را برابر نام دامنه قرار دهید.
   * در بخش **Destination Port** گزینه **Rewrite to...** را انتخاب کرده و پورت فعال وردپرس خود (مثلاً `2087`) را وارد کنید.

---

## 📁 ساختار فایل‌های پروژه (Directory Structure)

```text
/opt/wp-docker/
├── setup.sh                 # اسکریپت اصلی مدیریت و منوی ترمینال
├── html/                    # پوشه میانبر مستقیم به فایل‌های سایت
├── docker-compose.yml       # پیکربندی کانتینرهای داکر (پروفایل‌های OLS و Nginx)
├── .env.example             # نمونه متغیرهای محیطی
├── ols/                     # پیکربندی وب‌سرور پرسرعت OpenLiteSpeed و کش LSCache
│   ├── httpd_config.conf.template
│   └── vhconf.conf.template
├── php/
│   └── custom.ini           # کانفیگ بهینه‌شده PHP جهت آپلود فایل‌های سنگین
├── nginx/
│   ├── nginx.conf           # کانفیگ اصلی Nginx با هدرهای امنیتی
│   └── conf.d/
│       ├── http.conf.template # کانفیگ موقت جهت تاییدیه Let's Encrypt
│       └── ssl.conf.template  # کانفیگ نهایی HTTPS با پشتیبانی از HTTP/2 و OAuth
├── scripts/
│   ├── ssl-init.sh          # اسکریپت صدور دو مرحله‌ای SSL
│   └── db-create.sh         # اسکریپت ایجاد دیتابیس و یوزر جدید
└── certbot/                 # محل نگهداری گواهی‌های SSL
```

---

## 🔒 نکات کلیدی امنیت (Security Highlights)

* **ایزولاسیون کامل دیتابیس:** پورت ۳۳۰۶ تنها در شبکه داخلی داکر قابل دسترسی است و به اینترنت متصل نمی‌شود.
* **رمزگذاری‌های تصادفی و پیچیده:** تولید رمزهای عبور ۳۲ کاراکتری خودکار و منحصربه‌فرد برای پایگاه‌داده.
* **تمدید خودکار و بی‌صدای SSL:** چرخه خودکار بررسی هر ۱۲ ساعت با گواهی رسمی Let's Encrypt.
* **جلوگیری از اجرای اسکریپت‌های مخرب:** مسدودسازی اجرای فایل‌های PHP در پوشه آپلودها.
* **حفاظت از فایل‌های حساس:** مسدودسازی سراسری دسترسی خارجی به فایل‌های `.env` و `.git`.

---

## 📄 لایسنس

این پروژه تحت مجوز **[MIT License](LICENSE)** به صورت متن‌باز منتشر شده است.
