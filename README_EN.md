<div align="center">

# 🚀 n8n Auto Installer (PostgreSQL Version)

**n8n Auto Install, Manage, Backup and Restore Script on Ubuntu**

![Version](https://img.shields.io/badge/Version-v1.0.1-blue.svg)
![Total Release Downloads](https://img.shields.io/github/downloads/im-JvD/n8n-installer/total?style=flat&label=total%20downloads)
![Platform](https://img.shields.io/badge/Ubuntu-22.04%2B-orange.svg)
![Stack](https://img.shields.io/badge/Docker%20%2B%20PostgreSQL%20%2B%20Nginx-brightgreen.svg)
![License](https://img.shields.io/badge/License-GPLv3-green.svg)
<br><br>
<a href="https://github.com/im-JvD/n8n-installer/blob/main/README.md">Study in Persian</a>

</div>

<div align="center"><br>

## 📌 Project Introduction

</div>

<div dir="ltr" align="left">

**n8n Auto-Installer** is a Bash script for automated installation and management of n8n on Ubuntu.
This version uses **PostgreSQL 16** instead of SQLite for better stability, security and data security in Production environments.

This project is designed to simplify:

- Full and automated installation of n8n
- PostgreSQL setup
- Nginx setup as a reverse proxy
- Get free SSL with Let's Encrypt
- Manage services with a simple menu
- Secure backup and restore based on SQL Dump

</div>

<div align="center"><br>

## 📥 Installation command

</div>

<div dir="ltr" align="left">

To install, run this command:

</div>

<pre><code>curl -fsSL https://github.com/im-JvD/n8n-installer/releases/latest/download/installer.sh | bash</code></pre>

<div align="center"><br>

## ✨ Key Features

</div>

<div dir="ltr" align="left">

- Fully automated installation of n8n on Ubuntu
- Using PostgreSQL 16 instead of SQLite
- Setting up Docker and Docker Compose
- Setting up Nginx as a Reverse Proxy
- Automatic SSL acquisition and renewal
- Automatic database information generation
- Stored in `.env` file
- Management menu with `n8n` command
- Smart backup with `pg_dump`
- Standard and secure restore from SQL Dump
- View logs and service status
- Suitable for personal and production use

</div>

<div align="center"><br>

## 🧠 Backup and restore logic

</div>

<div dir="ltr" align="left">

To prevent raw damage to the database, this project uses **Direct file copy PostgreSQL** does not use it.
Instead, it uses the standard **SQL Dump** method.

### Backup
- Get database output with `pg_dump`
- Save files
- Compress everything into a ZIP file

### Recovery
- Stop services
- Rebuild database
- Import data with `psql`
- Restore system and start service

This method protects against permission errors, data inconsistencies, and database corruption.

</div>

<div align="center"><br>

## 🧭 How to manage

</div>

<div dir="ltr" align="left">

After installation, to manage the service, just run this command:

</div>

<pre><code>n8n</code></pre>

<div dir="ltr" align="left">

From the menu inside, you can do the following:

- Installation and Setup
- View Status and Login
- Retrieve and Restore Backup or Backup
- Update
- Uninstall

</div>

<div align="center"><br>

## 🛠️ Technical Specifications

</div>

<div dir="ltr" align="left">

| Item | Value |
|---|---|
| Script Version | `v1.0.1` |
| Operating System | Ubuntu 22.04+ |
| Run | Docker |
| Database | PostgreSQL 16 |
| Webserver | Nginx |
| SSL | Let's Encrypt / Certbot |
| n8n port | `5678` |
| Installation path | `/opt/n8n` |
| Data path | `/var/lib/n8n/data` |
| Admin command | `n8n` |

</div>

<div align="center"><br>

## 🔐 Security Tips

</div>

<div dir="ltr" align="left">

- The `.env` file contains sensitive information
- Keep backups in a safe place
- Restrict access to configuration files
- Keep the firewall enabled in the Production environment
- Change passwords after installation if necessary

</div>

<div align="center"><br>

## 📂 Overall project structure

</div>

<div dir="ltr" align="left">

- `install.sh` — installation and startup script
- `.env` — environment and database information
- `docker-compose.yml` — service definition
- `/opt/n8n` — main project path
- `/var/lib/n8n/backups` — backup storage location

</div>

<div align="center"><br>

## 📄 License

</div>

<div dir="rtl" align="center">

This project is released under the **GNU General Public License v3.0**.

If you found this project useful, please support it by giving it a ⭐ star.

</div>
