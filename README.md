# Dock Folders

Turn any folder into a **clickable Dock icon** that shows its contents as a popup menu — like macOS Dock stacks, but with custom icons.

> [!WARNING]
> This automation is provided **as-is** for personal use. The repository is public for anyone who wants to fork and adapt it.
> Please do not open issues for support or feature requests.

## Features

📂 **Native popup menus** — Shows folder contents in a clean list

🎨 **Custom icons** — Preserves folder icons (including Emoji) in the Dock

🕵️ **Clean experience** — Hidden from CMD+Tab and Dock recent apps

⚡ **Fast** — Uses native macOS APIs and AppleScript

🖱️ **Click-to-open** — Opens selected items or the folder itself

## Usage

### Quick Start

Generate a Dock app for a single folder:

```bash
./dock-folders.sh ~/Documents/dock-folders/coding
```

Or build apps for **all** folders in a directory:

```bash
./dock-folders.sh --all ~/Documents/dock-folders
```

Then drag the generated `.app` files from `./build/` into your Dock.

> [!NOTE]
> **First launch:** If the folder is in `~/Documents`, `~/Desktop`, or `~/Downloads`, macOS will ask for permission to access it. Click **Allow**.

### Setup

1. **Create a folder** to hold your dock shortcuts:

   ```bash
   mkdir -p ~/Documents/dock-folders
   ```

2. **Create sub-folders** for each Dock group:

   ```bash
   mkdir ~/Documents/dock-folders/coding
   mkdir ~/Documents/dock-folders/music
   ```

3. **Add items**: Drag apps, aliases, files, or folders into these directories.

4. **Add icons**: Use [Customize Folder](https://support.apple.com/guide/mac-help/customize-folders-files-mac-mchlp2313/mac) or Finder's _Get Info_ panel to set custom icons. The script will automatically use them.

### Options

| Option               | Description                                                  |
| -------------------- | ------------------------------------------------------------ |
| `--all <dir>`        | Build apps for all sub-folders in `<dir>`                    |
| `<folder>`           | Build an app for a single folder                             |
| `--output-dir <dir>` | Change the output directory (default: `./build/`)            |
| `--bg <mode>`        | Background colour behind emoji icons (see below)             |
| `--gradient`         | Draw the background as a light-to-dark gradient              |

### Background colours

Folders with a **Customize Folder** emoji get the emoji drawn on a coloured square. `--bg` picks the colour:

| Mode          | Background                                                                 |
| ------------- | -------------------------------------------------------------------------- |
| `tag`         | The folder's Finder tag colour (default). Grey if the folder has no tag.  |
| `grey`        | Plain grey, as in earlier versions                                         |
| `emoji`       | The emoji's own main colour, shifted so the emoji stands out               |
| `interactive` | Asks for a hex colour and gradient per folder, saves the answers, builds   |
| `saved`       | Uses the saved answers without asking; unsaved folders use their tag colour |

Add `--gradient` to any mode for a gradient. In interactive mode it sets the default answer instead.

```bash
./dock-folders.sh --bg tag --gradient --all ~/Documents/dock-folders
./dock-folders.sh --bg interactive --all ~/Documents/dock-folders
```

Interactive mode accepts `#RRGGBB`, `RRGGBB`, `#RGB`, or the words `tag`, `emoji` or `grey`. Press Enter to use the tag colour. Answers are saved to `dock-colours.conf` next to the script. On later runs it shows each saved value and asks whether to keep it. Use `--bg saved` in scripts so a rebuild keeps your colours.

Folders without an emoji keep Finder's own folder icon, which already shows the folder's colour.

## Installation

No dependencies required. The script uses only built-in macOS tools.

1. Download `dock-folders.sh`
2. Make it executable:
   ```bash
   chmod +x dock-folders.sh
   ```
3. Run it!

## Images

![macos-dock-folders-old](https://github.com/user-attachments/assets/723bb143-b7ac-4e77-ae9f-21b139148560)

![macos-dock-folders-new](https://github.com/user-attachments/assets/dfdf0579-0ea7-4bf2-98a7-114312f419ac)

## License

[MIT](LICENSE)
