Debian 13 / Raspberry Pi OS Post-Installation & Server Hardening Scripts

Automate the setup of Debian 13 and Raspberry Pi OS servers into a secure, production-ready environment with modern security tooling and reverse proxy support.

***
Overview
***

This repository contains scripts for:

Debian 13 (amd64) & Raspberry Pi OS (Debian 13 based, arm64)

The scripts transform a minimal installation into a hardened, secure server, including:

Nginx reverse proxy with HTTPS

Fail2Ban and CrowdSec integration

Docker & Dokploy support

Let’s Encrypt certificate automation

Designed to be re-runnable, non-intrusive, and safe for production.


***
Features
***

1. System Preparation
---
Update & upgrade the system
Install essential packages
Basic cleanup of unused files

2. Security Hardening
---
Hardened Nginx configuration
Strict TLS (1.2 / 1.3)
Security headers for HTTP responses
Per-application server isolation

3. Fail2Ban Integration
---
Detects and configures app-specific jails if missing
Preserves existing jails (e.g., SSH)
Automatically blocks repeated login failures
Re-runnable safely

4. CrowdSec Integration
---
Verifies Nginx bouncer registration
Installs missing Nginx collection if necessary
Assumes CrowdSec & NFTables bouncer are already installed
Non-destructive to existing configuration

5. Docker & Application Deployment
---
Optional Docker installation
Dokploy setup support
Supports applications on any local port
Works with Docker containers, Python apps, or other services

6. Generic Nginx Reverse Proxy
---
Reverse proxy for any local app (APP_PORT)
HTTP → HTTPS redirection
Automatic Let’s Encrypt certificate issuance (webroot method)
Auto-renewal & dry-run verification
Email notifications on success/failure using msmtp



Disclaimer
***
These scripts are intended for system administrators familiar with Linux.
Always review and understand the scripts before running them on production servers.
