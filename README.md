# chitanka.koplugin

A [KOReader](https://koreader.rocks/) plugin for searching and downloading books from [chitanka.info](https://chitanka.info) -- the largest free Bulgarian-language digital library.

No account or login is required. The plugin uses only chitanka.info's public XML API and direct download links.

## Features

- Search across four scopes: everything, books only, individual texts (stories, poems, essays), or authors
- Results list showing title, author, year, and content type
- Book detail view with full metadata and cover image on request
- Format picker before every download: EPUB, FB2, MOBI, PDF, TXT
- Browse the latest additions: new books and new texts
- Tapping an author in results loads all their works directly
- Assignable to a gesture or quick-action shortcut (three actions available)
- Configurable default format, download folder, and per-download format confirmation

## Prerequisites

- KOReader installed on your device
- An active internet connection when searching or downloading

## Installation

### Manual

1. Download or clone this repository.
2. Copy the entire folder (or rename the cloned folder) to `chitanka.koplugin`.
3. Place it inside the `koreader/plugins/` directory on your device.
4. Restart KOReader.

The plugin appears under the **Search** menu as **Читанка**.

### Via git (recommended for updates)

```sh
cd /path/to/koreader/plugins
git clone https://github.com/stanevt/chitanka.koplugin
```

To update later:

```sh
cd /path/to/koreader/plugins/chitanka.koplugin
git pull
```

## Usage

1. Open the KOReader file browser.
2. Open the **Search** menu (magnifier icon).
3. Select **Читанка**.
4. Choose **Търсене** (Search) and type a title, author name, or keyword in Cyrillic.
5. Select a result to open the detail view, then tap **Свали** (Download) to choose a format and save the file.

To browse recent additions, choose **Нови книги** (New Books) or **Нови творби** (New Texts) from the same menu.

> **Note:** The search API returns results for Cyrillic queries only. Latin input will return no results.

## Setting up a gesture (optional)

Three actions can be assigned to any gesture, hardware key, or quick-action slot:

1. Open the top menu and tap the **Cog** icon.
2. Go to **Taps and gestures** > **Gesture manager**.
3. Select a gesture zone.
4. Under **General**, look for:
   - **Читанка: Търсене**
   - **Читанка: Нови книги**
   - **Читанка: Нови творби**

## Settings

Open **Читанка** > **Настройки** (Settings) to configure:

| Setting | Default | Description |
|---|---|---|
| Default format | EPUB | Format used when per-download confirmation is off |
| Ask for format each time | On | Show a format picker before every download |
| Download folder | KOReader downloads dir | Where saved files are placed |

## Supported formats

| Format | Extension |
|---|---|
| EPUB | `.epub` |
| FictionBook 2 | `.fb2.zip` |
| MOBI | `.mobi` |
| PDF | `.pdf` |
| Plain text | `.txt.zip` |

## About chitanka.info

[chitanka.info](https://chitanka.info) is a free, community-maintained digital library of Bulgarian literature and translations. It provides a public XML search API and direct download links with no authentication required. All content is made available under licenses that permit free distribution.

## License

AGPL-3.0, matching KOReader's own license.

## Keywords

KOReader, chitanka, chitanka.info, Bulgarian, e-reader, plugin, ebook, download, Моята библиотека, KOReader plugin, digital library, e-ink, EPUB, open source
