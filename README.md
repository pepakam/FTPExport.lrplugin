# FTP Export Plugin for Lightroom Classic

Upload your photos directly to an FTP / FTPS / SFTP server from Lightroom Classic via **File → Export**.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Sponsor](https://img.shields.io/badge/Sponsor-GitHub-ea4aaa?logo=github-sponsors)](https://github.com/sponsors/pepakam)
[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-FFDD00?logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/penka.kamenova)
[![PayPal](https://img.shields.io/badge/PayPal-Donate-00457C?logo=paypal)](https://paypal.me/SmartechEOOD)

---

## Features

- Upload **JPEG / PNG / TIFF** via FTP, FTPS or SFTP
- **Multiple server profiles** with one-click multi-upload
- **Passive mode** (PASV) support for FTP behind NAT
- **Automatic subfolder by date** (YYYY-MM-DD) or custom name
- **Test Connection** button per profile
- **Overwrite** option for existing files
- Optional **CSV report** of uploaded files
- FTPS support via external **WinSCP** (free, GPL — [winscp.net](https://winscp.net/))

---

## Installation (Windows)

1. Download or clone this repository.
2. Copy the `FTPExport.lrplugin` folder to:
   ```
   C:\Users\<YourUser>\AppData\Roaming\Adobe\Lightroom\Modules\
   ```
3. Open **Lightroom Classic**.
4. Go to **File → Plug-in Manager**.
5. Click **Add** and select the `FTPExport.lrplugin` folder.
6. The plugin should appear as **Installed and running**.

> **For FTPS:** install [WinSCP](https://winscp.net/) (free). The plugin auto-detects standard install paths.

---

## Installation (macOS)

1. Copy the `FTPExport.lrplugin` folder to:
   ```
   ~/Library/Application Support/Adobe/Lightroom/Modules/
   ```
2. Follow steps 3–6 from the Windows installation.

> Note: FTPS via WinSCP is Windows-only. On macOS, plain FTP and SFTP work via the built-in Lightroom FTP module.

---

## Usage

1. Select the photos in Lightroom.
2. **File → Export** (or `Shift+Ctrl+E` / `Shift+Cmd+E`).
3. In the left column, choose **FTP Upload**.
4. Create a profile in the **Profiles** section:
   - **Protocol** — FTP / FTPS / SFTP
   - **FTP Host** — server address (e.g. `ftp.mysite.com`)
   - **Port** — default 21 (FTP/FTPS) or 22 (SFTP)
   - **Username / Password** — login credentials
   - **Remote Folder** — path on the server (e.g. `/public_html/uploads`)
   - **Subfolder** — by date, custom, or none
5. Click **Test Connection** to verify.
6. Tick one or more profiles in the multi-upload list.
7. Click **Export**.

---

## File Structure

```
FTPExport.lrplugin/
├── Info.lua                        ← Plugin metadata
├── FTPExportServiceProvider.lua    ← Main logic & UI
├── ProfileManager.lua              ← Multi-profile storage
├── WinScpHelper.lua                ← FTPS support via WinSCP CLI
├── LICENSE                         ← MIT License
└── README.md                       ← This file
```

---

## Notes

- Profiles (including passwords) are stored in **Lightroom's plugin preferences** on your local machine. They are **not** stored inside the plugin folder, so sharing the plugin folder is safe.
- Passwords are stored **unencrypted** in Lightroom preferences — the same way other Lightroom plugins handle FTP credentials. Avoid sharing your Lightroom preferences file.
- Tested with **Lightroom Classic 10+**.

---

## Support / Donate ☕

This plugin is **free and open source**. If it saves you time, please consider supporting development:

| Platform | Link |
|----------|------|
| ❤️ **GitHub Sponsors** | https://github.com/sponsors/pepakam |
| ☕ **Buy Me a Coffee** | https://buymeacoffee.com/penka.kamenova |
| 💳 **PayPal** | https://paypal.me/SmartechEOOD |

Every coffee helps maintain and improve the plugin. Thank you! 🙏

---

## Contributing

Pull requests, bug reports and feature suggestions are welcome!
Please open an [issue](https://github.com/pepakam/FTPExport.lrplugin/issues) first to discuss larger changes.

---

## License

[MIT](LICENSE) © 2026 Penka Kamenova

Free to use, modify and distribute. See [LICENSE](LICENSE) for details.
