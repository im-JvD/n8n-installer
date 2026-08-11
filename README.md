<div align="center">

# 🚀 n8n Auto-Installer (PostgreSQL Edition)

**اسکریپت نصب، مدیریت، بکاپ و ریستور خودکار n8n روی Ubuntu**

![Version](https://img.shields.io/badge/Version-v1.0.0-blue.svg)
![Total Release Downloads](https://img.shields.io/github/downloads/im-JvD/n8n-installer/total?style=flat&label=total%20downloads)
![Platform](https://img.shields.io/badge/Ubuntu-20.04%2B-orange.svg)
![Stack](https://img.shields.io/badge/Docker%20%2B%20PostgreSQL%20%2B%20Nginx-brightgreen.svg)
![License](https://img.shields.io/badge/License-GPLv3-green.svg)
<br><br>
<a href="https://github.com/im-JvD/n8n-installer/blob/main/README_EN.md">Study in English</a>

</div>


<div align="center"><br>

## 📌 معرفی پروژه

</div>

<div dir="rtl" align="right">

**n8n Auto-Installer** یک اسکریپت Bash برای نصب و مدیریت خودکار n8n روی Ubuntu است.  
این نسخه به‌جای SQLite از **PostgreSQL 16** استفاده می‌کند تا پایداری، مقیاس‌پذیری و امنیت داده‌ها در محیط Production بهتر باشد.

این پروژه برای ساده‌سازی این موارد طراحی شده است:

- نصب کامل و خودکار n8n
- راه‌اندازی PostgreSQL
- تنظیم Nginx به‌عنوان Reverse Proxy
- دریافت SSL رایگان با Let's Encrypt
- مدیریت سرویس‌ها با یک منوی ساده
- بکاپ و ریستور امن بر پایه SQL Dump

</div>

<div align="center"><br>

## 📥 دستور نصب

</div>

<div dir="rtl" align="right">

برای نصب، این دستور را اجرا کنید:

</div>

<pre><code>curl -fsSL https://github.com/im-JvD/n8n-installer/releases/download/v1.0.0/installer.sh | bash</code></pre>


<div align="center"><br>

## ✨ قابلیت‌های کلیدی

</div>

<div dir="rtl" align="right">

- نصب تمام‌خودکار n8n روی Ubuntu
- استفاده از PostgreSQL 16 به‌جای SQLite
- راه‌اندازی Docker و Docker Compose
- تنظیم Nginx به‌عنوان Reverse Proxy
- دریافت و تمدید خودکار SSL
- تولید خودکار اطلاعات دیتابیس
- ذخیره تنظیمات در فایل `.env`
- منوی مدیریتی با دستور `n8n`
- بکاپ‌گیری هوشمند با `pg_dump`
- ریستور استاندارد و امن از روی SQL Dump
- نمایش لاگ‌ها و وضعیت سرویس‌ها
- مناسب برای استفاده شخصی و Production

</div>

<div align="center"><br>

## 🧠 منطق بکاپ و ریستور

</div>

<div dir="rtl" align="right">

این پروژه برای جلوگیری از آسیب به دیتابیس، از **کپی مستقیم فایل‌های خام PostgreSQL** استفاده نمی‌کند.  
به‌جای آن، از روش استاندارد **SQL Dump** بهره می‌برد.

### Backup
- گرفتن خروجی دیتابیس با `pg_dump`
- ذخیره فایل‌های تنظیمات
- فشرده‌سازی همه چیز در یک فایل ZIP

### Restore
- توقف سرویس‌ها
- بازسازی دیتابیس
- وارد کردن داده‌ها با `psql`
- بازیابی تنظیمات و راه‌اندازی مجدد سرویس

این روش از خطاهای Permission، ناسازگاری داده و خرابی دیتابیس جلوگیری می‌کند.

</div>

<div align="center"><br>

## 🧭 نحوه مدیریت

</div>

<div dir="rtl" align="right">

بعد از نصب، برای مدیریت سرویس کافی است این دستور را اجرا کنید:

</div>

<pre><code>n8n</code></pre>

<div dir="rtl" align="right">

از داخل منو می‌توانی این کارها را انجام بدهی:

- نصب و راه‌اندازی
- مشاهده وضعیت و لاگ ها
- دریافت و بازگردانی نسخه پشتیبان یا Backup
- بروزرسانی 
- حذف 

</div>

<div align="center"><br>

## 🛠️ مشخصات فنی

</div>

<div dir="rtl" align="right">

| مورد | مقدار |
|---|---|
| نسخه اسکریپت | `v1.0.0` |
| سیستم‌عامل | Ubuntu 20.04+ |
| اجرا | Docker |
| دیتابیس | PostgreSQL 16 |
| وب‌سرور | Nginx |
| SSL | Let's Encrypt / Certbot |
| پورت n8n | `5678` |
| مسیر نصب | `/opt/n8n` |
| مسیر داده‌ها | `/var/lib/n8n/data` |
| دستور مدیریت | `n8n` |

</div>

<div align="center"><br>

## 🔐 نکات امنیتی

</div>

<div dir="rtl" align="right">

- فایل `.env` شامل اطلاعات حساس است
- بکاپ‌ها را در محل امن نگهداری کنید
- دسترسی فایل‌های تنظیمات را محدود کنید
- در محیط Production فایروال را فعال نگه دارید
- رمزها را بعد از نصب در صورت نیاز تغییر دهید

</div>

<div align="center"><br>

## 📂 ساختار کلی پروژه

</div>

<div dir="rtl" align="right">

- `install.sh` — اسکریپت نصب و راه‌اندازی
- `.env` — تنظیمات محیطی و اطلاعات دیتابیس
- `docker-compose.yml` — تعریف سرویس‌ها
- `/opt/n8n` — مسیر اصلی پروژه
- `/var/lib/n8n/backups` — محل ذخیره بکاپ‌ها

</div>

<div align="center"><br>

## 📄 مجوز

</div>

<div dir="rtl" align="center">

این پروژه تحت مجوز **GNU General Public License v3.0** منتشر شده است.

اگر این پروژه برایت مفید بود، با دادن ستاره ⭐ از آن حمایت کن.

</div>
