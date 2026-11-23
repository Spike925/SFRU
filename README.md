# sf-rom-upload

An arrow-key terminal menu for uploading ROM builds — or any release file — to
your own SourceForge project. Built for people who publish LineageOS/AOSP
builds, recovery images and kernels, and are tired of typing `sftp` commands
and `cd /home/frs/project/...` by hand.

Works on Linux, macOS, Windows (WSL or Git Bash) and **Termux on Android**.

```
  SourceForge ROM uploader  v1.2
  arrow keys + Enter to navigate

Project: myrom
/home/frs/project/myrom/Release-1
  [file] lineage-22.1-pixel-20261123.zip
--------------------------------------------------------------
  Upload a file (ROM) into this folder
    Create a new folder here
    Create an empty file here
    Open a folder
    Refresh listing
    Up one level
    Back to project list
    Exit
  UP/DOWN move - Enter select - q quit
```

---

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [The menus](#the-menus)
- [Logging in without a password](#logging-in-without-a-password)
- [Where your files end up](#where-your-files-end-up)
- [Settings](#settings)
- [Troubleshooting](#troubleshooting)
- [How it works](#how-it-works)
- [Limitations](#limitations)
- [License](#license)

---

## What it does

- **Signs you in** to SourceForge over SFTP — the password is asked **at most
  once per run**, because every action reuses a single connection.
- **Lists your real projects**, read from your SourceForge account, with each
  project's display name, UNIX name and description. No typing names by hand.
- **Walks your project's file space** like a file manager: open folders, create
  folders, go up a level.
- **Browses your local disk** to find the ROM — any folder, any depth, or type a
  path directly.
- **Uploads, then verifies** the file size the server reports before telling you
  it worked.
- **Asks what next**: upload another file to the same folder, pick a different
  local folder, go back, or exit.
- **Remembers** your username, project list and last folder. It never saves your
  password.

## Requirements

| Tool | Needed for | Install |
| --- | --- | --- |
| `sftp` | everything (OpenSSH client) | see below |
| `curl` or `wget` | reading your project list | usually already there |
| `sshpass` | filling the one password prompt silently | optional |
| `rsync` | resumable uploads with a progress bar (used automatically above 100 MB) | optional |

```bash
# Termux (Android)
pkg install openssh curl sshpass rsync

# Debian / Ubuntu / Kali
sudo apt install openssh-client curl sshpass rsync

# Fedora / RHEL
sudo dnf install openssh-clients curl sshpass rsync

# Arch / Manjaro
sudo pacman -S openssh curl sshpass rsync

# macOS (ssh and curl ship with the OS)
brew install hudochenkov/sshpass/sshpass rsync

# Windows
# Use WSL (then follow the Debian line) or Git Bash + an sshpass build.
```

Only `sftp` is strictly required. Without `curl`/`wget` you still get the
projects you have opened before; without `sshpass` you type your password once
per run; without `rsync` large files upload over plain sftp.

## Quick start

```bash
git clone https://github.com/<your-username>/<your-repo>.git
cd <your-repo>
chmod +x sf-rom-upload.sh
./sf-rom-upload.sh
```

If the script will not run at all, start it with `bash sf-rom-upload.sh`.

You need an existing SourceForge project that your account can write to (you
must be a project admin or have the *release technician* permission).

## The menus

**Keys everywhere:** `↑` `↓` to move, `Enter` to select, `q` to quit. If your
keyboard sends something odd, `k` / `j` move too. In Termux, use the arrow keys
on the extra keys row.

### 1. Project screen

```
SourceForge ROM uploader
Signed in as yourname on frs.sourceforge.net
Your projects on SourceForge (2):
--------------------------------------------------------------
  EN-OS  [en-os]  - UserFriendly arch-based distro
    My ROM Builds  [myrom]  - LineageOS builds, weekly
    Refresh the project list from SourceForge
    Add an existing project by name
    Create a new project on SourceForge
    Set up password-free login (SSH key)
    Change SourceForge account
    Exit
```

The entries above the line are your projects, newest state read from
SourceForge. Picking one opens its file space.

- **Refresh the project list** — re-read the list, e.g. after creating a project
  in your browser.
- **Add an existing project by name** — type a project's UNIX name (the
  lowercase name in its URL) when it is not in the list.
- **Create a new project on SourceForge** — SourceForge only creates projects
  through a web form, so this opens `https://sourceforge.net/create/` and
  reminds you to note the UNIX name.
- **Set up password-free login** — see below.

### 2. Folder screen

```
Project: myrom
/home/frs/project/myrom
  [dir ] Release-1/
  [file] README.md
--------------------------------------------------------------
  Upload a file (ROM) into this folder
    Create a new folder here
    Create an empty file here
    Open a folder
    Refresh listing
    Up one level
    Back to project list
    Exit
```

The listing above the line is the current folder on the server. `Up one level`
only appears once you are inside a sub-folder.

- **Upload a file (ROM) into this folder** — opens your local file browser.
- **Create a new folder here** — makes the folder and steps into it.
- **Create an empty file here** — useful for a `README.md`; SourceForge shows a
  readme file as release notes on the download page.
- **Open a folder** — lists only the sub-folders, and enters the one you pick.
- **Refresh listing** — re-read the folder after changing it elsewhere.

### 3. Local file browser

```
Choose the file to upload
/home/you/roms
--------------------------------------------------------------
  [ .. ]  go up one folder
    [ path ] type a folder or file path
    pixel/
    boot.img
```

Folders end with `/`. Enter one to look inside, `[ .. ]` goes up, or pick
`[ path ]` and type any path, e.g. `/storage/emulated/0/Download/rom.zip`.

### 4. After an upload

```
Upload finished
/home/frs/project/myrom/Release-1
--------------------------------------------------------------
  Upload another file to this folder
    Choose a different local folder and upload
    Back to the folder menu
    Exit
```

Each upload shows the local file, its size, the destination, and asks for the
remote filename first. If a file with that name already exists you are asked
before it is replaced. When the transfer ends, the script compares the size the
server reports with the size on disk and tells you if they differ.

## Logging in without a password

**One prompt per run is normal.** The script opens a single authenticated
connection when you sign in, and every listing, upload and folder action reuses
it. Install `sshpass` and that one prompt is filled in silently too.

**Zero prompts is better.** SourceForge accepts an SSH public key, so the script
can sign in without a password at all:

1. From the project screen, choose **Set up password-free login (SSH key)**.
2. It creates a dedicated key at `~/.ssh/id_ed25519_sf` — your existing keys are
   not touched — and prints the public key.
3. Copy that line and paste it at
   <https://sourceforge.net/auth/shell_services> under **SSH Public Keys**, then
   save.
4. Wait a minute or two, then choose **Try a key-only login now** on the same
   screen.

From then on the script shows `Using your SSH key` and never asks for a
password. The key path is remembered in the config file.

> The generated key has no passphrase, which is what lets the script use it
> unattended. Keep the private key private; only the `.pub` file goes to
> SourceForge.

## Where your files end up

Uploads go over SFTP to `frs.sourceforge.net` (port 22) into:

```
/home/frs/project/<project-unix-name>/
```

Anything you put there appears on your project's **Files** page, and
SourceForge mirrors it worldwide. Notes:

- Files usually show up on the site within a few minutes, not instantly.
- **Files over 10 GB are not mirrored** and cannot be downloaded by anyone. The
  script warns you before starting one.
- Download statistics are tracked per path and filename, so renaming a file
  resets its count.
- A `README` file in a folder is displayed as release notes on the download
  page.

## Settings

Environment variables:

| Variable | Effect |
| --- | --- |
| `SF_USERNAME` | skip the username prompt (`SF_USERNAME=yourname ./sf-rom-upload.sh`) |
| `SF_UPLOAD_METHOD` | force `sftp` or `rsync` instead of choosing automatically |
| `SF_NO_FETCH` | do not read the project list from sourceforge.net (offline use) |
| `NO_COLOR` | plain output, no colours |
| `TMPDIR` | where the temporary ssh control socket is created |

Files the script keeps, all under `${XDG_CONFIG_HOME:-~/.config}/sf-rom-uploader/`:

| File | Contents |
| --- | --- |
| `user` | last username used |
| `projects` | projects you have opened |
| `remote-projects` | cached project list, used when offline |
| `lastdir` | last local folder you uploaded from |
| `key` | path to your SSH key, if you set one up |

**Your password is never written to disk.** Delete the folder to reset
everything.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `Could not open project 'x'` | Use the project's **UNIX name** (lowercase, from its URL), not its display name. A project created minutes ago may not have its file space yet — try again shortly. You also need admin or *release technician* rights. |
| `Login failed` | SourceForge wants your **login name**, not your email. If you use two-factor auth, password login over SSH is blocked — set up an SSH key instead. |
| Password asked every time | `sshpass` is not installed and the shared connection could not be held. Install `sshpass`, or use **Set up password-free login (SSH key)**. |
| `sftp is not installed` | Install the OpenSSH client (`pkg install openssh` on Termux, `openssh-client` on Debian). |
| A folder looks empty but has files | Choose **Refresh listing**. |
| `Upload failed` | Check the file is under 10 GB, that you have write permission on the project, and that the connection stayed up. `rsync` (installed) resumes interrupted transfers. |
| Uploads work but nothing on the website | Wait a few minutes for the mirrors to pick the file up. |
| Terminal shows garbage after a crash | Run `stty sane` (or just close the window). The script restores the terminal on exit, including Ctrl-C. |

## How it works

- **Transfers** use the SFTP client that ships with OpenSSH, driven in batch
  mode: `mkdir`, `put` and `ls` against `/home/frs/project/<project>/`.
- **One connection**: a master SSH connection is opened once
  (`ssh -M -N -f` with `ControlPersist`) and reused through a control socket, so
  authentication happens a single time. Optional `rsync` shares the same socket.
- **Project list**: read from SourceForge's public profile endpoint
  (`https://sourceforge.net/rest/u/<username>/profile`), which returns your
  projects as JSON. It is parsed with `sed`/`grep`, so `jq` and Python are not
  needed, and cached on disk for offline use.
- **The interface** is plain bash: no dialog, no ncurses, no extra runtime. It
  puts the terminal in raw mode for the session and reads keys itself, which is
  why the same arrow keys work on a laptop and in Termux.

## Limitations

- **Projects cannot be created by the script.** SourceForge only creates them
  through a web form with a review step, so the menu opens that page instead.
- **One release file per folder is the convention.** SourceForge expects each
  release to be a single file; bundle multiple artefacts with `zip`/`tar`.
- **No delete or rename.** Deliberately: deleting release files is not something
  a slip of an arrow key should be able to do. Use SourceForge's web File
  Manager for that.
- **Not a general SFTP client.** It is built around the SourceForge file-release
  layout and will not manage project web content (`/home/project-web/...`).

## License

Pick a license for your repository — MIT or GPL-3.0 are both common for a script
like this — and add a matching `LICENSE` file. Replace this section with your
choice.
