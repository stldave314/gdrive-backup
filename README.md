# gdrive-backup

Encrypted, incremental backup of your home directory and system state to Google Drive. Built for Ubuntu/Debian Linux (Pop!_OS, Ubuntu, Linux Mint, etc.).

Wipe your OS, pull this repo, run `setup`, run `restore` — you're back.

## Features

- **Encrypted at rest** — rclone crypt encrypts both file contents and filenames before anything touches Google Drive. Google cannot read your files.
- **Three backup methods** — rclone sync (recommended), rsync hardlink snapshots, or tar archives. Explained interactively during setup.
- **Incremental uploads** — only changed files are transferred after the first run.
- **Profiles** — identified by name, not hostname. Survives OS reinstalls and machine renames.
- **Package lists** — saves manually-installed `apt` packages, apt sources, apt signing keys, and Flatpak apps. Restores them in one step.
- **Large directory handling** — `Downloads`, `.cache`, Steam, Videos, etc. are asked about individually and can be backed up in a separate, independently-restorable set.
- **Optional system state** — `/etc`, user crontab, and `/usr/local/bin` scripts.
- **Version retention** — keeps N versions; automatically prunes older ones from Drive.

## Requirements

- Ubuntu, Debian, Pop!_OS, Linux Mint, or any compatible derivative
- `bash` 4.x or later
- `rsync`, `tar`, `curl` (installed automatically if missing)
- [`rclone`](https://rclone.org) (installed automatically if missing)
- A Google account with Google Drive

## Installation

```bash
git clone https://github.com/stldave314/gdrive-backup.git
cd gdrive-backup
chmod +x gdrive-backup.sh
```

## Usage

### First-time setup

```bash
./gdrive-backup.sh setup
```

The setup wizard will:

1. Install any missing dependencies
2. Walk you through Google Drive OAuth — opens a browser; shows a URL on headless systems
3. Configure rclone crypt encryption (two passwords — **write them down**)
4. Ask you to choose a backup method (see below)
5. Ask how many versions to retain
6. Walk through large directories one by one (size shown)
7. Optionally enable system state backup (`/etc`, crontabs, `/usr/local/bin`)

### Run a backup

```bash
./gdrive-backup.sh backup
```

Backs up home directory, package lists, and (if enabled) system state and large directories.

### Restore

```bash
./gdrive-backup.sh restore
```

Interactive menu — choose what to restore: home directory, packages, system state, large directories, or everything at once.

### After an OS reinstall

```bash
# 1. Clone this repo and run setup — use the SAME crypt passwords as before
./gdrive-backup.sh setup

# 2. Restore everything
./gdrive-backup.sh restore
```

Your profile is identified by the name you gave it (e.g. `work-laptop`), not your hostname, so it will be found on Drive even after a fresh install.

### Other commands

```bash
./gdrive-backup.sh status   # show config and last log entries
./gdrive-backup.sh help     # show all commands
```

## Backup Methods

Explained interactively during setup. Here's the short version:

| | Method A | Method B ⭐ | Method C |
|---|---|---|---|
| **How it works** | rsync hardlink snapshots uploaded to Drive | rclone sync — Drive mirrors current state; changed/deleted files moved to versioned folder | Full + incremental tar.gz archives |
| **Drive storage** | Full copy per version | Efficient — only changed files | Full archive per backup cycle |
| **Restore** | Any full snapshot | Current state + per-file history | Must replay full + incrementals |
| **Best for** | Local-primary, Drive-offsite | Most people | Long-term archival |

**Method B is recommended** for most users.

## Encryption

rclone crypt is applied transparently before upload. Both file contents and filenames are encrypted — the directory structure visible on Google Drive is unreadable without your passwords.

> **Your crypt passwords cannot be recovered.** If you lose them, your backup cannot be decrypted. Store them in a password manager.

## Configuration

All configuration lives in `~/.config/gdrive-backup/`:

```
~/.config/gdrive-backup/
├── config                        # main config (mode 600)
├── exclude.conf                  # rclone exclude patterns
├── backup.log                    # backup log
└── profiles/
    └── <profile-name>/
        ├── config                # per-profile settings
        └── large-dirs-separate.conf
```

rclone remotes are stored in `~/.config/rclone/rclone.conf` (managed by rclone).

## Google Drive Layout

All data is stored under a single encrypted folder on Drive:

```
Google Drive/
└── gdrive-backup/                # encrypted — unreadable without passwords
    └── profiles/
        └── <profile-name>/
            ├── home/             # home directory backup
            ├── packages/         # apt + Flatpak package lists
            ├── system/           # /etc, crontabs, /usr/local/bin
            └── large-dirs/       # separately-backed-up large directories
```

## License

MIT
