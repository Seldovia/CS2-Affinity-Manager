# Toothpaste — the exact recipe

**Reference implementation: Backtrack Brainiac** (`My Software\Backing Track Maker\stem_gui.py`).
When this document and an app disagree, the app is wrong. When this document is silent,
do what Brainiac does.

Colors come **only** from `theme.py` (`THEME[...]` keys, or `$t.<Key>` in PowerShell).
No hex literal ever appears in an app file. Use every color exactly as authored — never
lighten, darken or contrast-walk a Toothpaste color in app code.

---

## 1. The palette (roles, not decoration)

| Key | Hex | Its one job |
|---|---|---|
| `Panel` | `#379B95` light cyan | Window/page background. The Windows title bar (`Band`). |
| `Chrome` (= `PanelHi`, `ButtonBg`, `ButtonHover`, `LogBg`) | `#007474` dark cyan | **Every box on the page**: fields, dropdowns, secondary buttons, the log, list boxes, collapsible-panel fill, progress-bar trough. **Also every section border.** |
| `Accent` (= `AccentHover`, `Header`, `Drop`) | `#BF1363` bright wine | The header band. The drop-area fill. Every **primary/filled** control: the main action button, progress-bar fill, selected-item highlight, checked indicators. |
| `DropLine` (= `Heading`) | `#910E4B` dark wine | **Every accent line and heading**: section titles, the header trim, the drop-area dashed outline, the native window border, collapsible-panel toggles, status notices on the page. |
| `Text` | `#0B2E2C` | Body text on the light page. |
| `TextOnChrome` / `LogText` | derived | Text on any dark-cyan box. |
| `OnAccent` / `TextOnHeader` / `TextOnDrop` | derived | Text on wine. |
| `MutedOnPanel` | derived | Secondary text on the page. |
| `readable(Muted, PanelHi, 3.5)` | derived | Secondary text on a box. |
| `MutedOnHeader` | derived | The subtitle under the app title. |
| `DropHint` | `#F0C9D8` | The faint hint text inside an empty drop area. |
| `Good` / `Warn` / `Bad` / `MutedOnLog` | derived | **Only** on dark-cyan surfaces (the log, a box). They are derived to read on `#007474` and are unreadable on the light page. |

There are exactly two cyans and two wines. If you reach for a fifth surface color, stop.

## 2. Fonts

| Use | Tkinter | WPF |
|---|---|---|
| Body | `("Segoe UI", 9)` | `Segoe UI`, 12 |
| Headings, primary button, bold labels | `("Segoe UI Semibold", 10)` | `Segoe UI Semibold`, 13 |
| Log / monospace | `("Consolas", 9)` | `Consolas`, 12 |
| App title | gradient image, 26px, `seguisb.ttf` | `Segoe UI Semibold`, 26, gradient brush |

## 3. Window

1. Background = `Panel`.
2. Windows 11 title bar (DWM attributes on the top-level HWND):
   `20` dark mode = 1 · `34` border = **`DropLine`** · `35` caption = `Band` · `36` caption text = `OnBand`.
   Tkinter: `paint_titlebar(root)` **after** the UI is built. PowerShell: `Set-TitleBand`.
3. Fixed-size, compact windows. No scrollbars on the main page unless the content is a list.

## 4. Header band (top of every window)

```
┌ DropLine, 2px on all four sides ────────────────────────┐
│ Header (#BF1363), padding 16 horizontal / 10 vertical     │
│   App Name            ← gradient title                   │
│   One-line blurb      ← MutedOnHeader, body font          │
└──────────────────────────────────────────────────────────┘
```

- Tkinter: an outer `tk.Frame(bg=DropLine)` packed `fill="x"`; inside it `tk.Frame(bg=Header, padx=16, pady=10)` packed `padx=2, pady=2`. Title from `title_widget(header, APP_NAME, Header)` using `theme.gradient_text_image(text, font, 26, Header)`; subtitle `tk.Label(bg=Header, fg=MutedOnHeader)`. Both `anchor="w"`.
- WPF: `<Border Background="{Header}" BorderBrush="{DropLine}" BorderThickness="2" Padding="16,10">` holding a `StackPanel` with the title `TextBlock` (`Foreground` = the title gradient brush) and the subtitle.
- The title gradient is `GRADIENT_STOPS` in `theme.py` (8 stops, `#612F3B` → `#007474`), horizontal, left to right. It is decorative and exempt from the role table.
- The header band sits flush against the window edges — no margin above or beside it.

## 5. Page body

- Padding **12** on all sides, background `Panel`.
- Content is a vertical stack of **sections**. Gap between sections: **8**.
- The main action row sits **10** below the section above it.

## 6. Sections

A titled, bordered group — Brainiac's "Song", "Remove", "Progress", "Finished backing tracks".

- Border: **1px solid `Chrome`**. Square corners. Background `Panel`.
- Title: ` Name ` (one space either side), `Heading` color, bold font, sitting on the top border.
- Inner padding: **8**.
- Tkinter: `ttk.LabelFrame(text=" Name ", padding=8)` with the style
  `TLabelframe: background=Panel, bordercolor=Chrome, relief="solid", borderwidth=1` and
  `TLabelframe.Label: background=Panel, foreground=Heading, font=bold`.
  **`relief="solid"` is mandatory** — clam's default groove paints a white highlight on some edges.
- WPF: `<GroupBox>` (or `HeaderedContentControl`) templated to a 1px `Chrome` border, `Padding="8"`, header `TextBlock` in `Heading`, bold.

## 7. Controls

Everything interactive is **flat**: no bevels, no 3D, no borders on boxes (`relief="flat"`, `bd=0`, `highlightthickness=0`; WPF `BorderThickness="0"`).

| Control | Look |
|---|---|
| **Primary button** (one per screen: the main action) | bg `Accent`, fg `OnAccent`, active/hover `AccentHover`, bold font, padding 12×5, hand cursor. Disabled keeps the same fill with `OnAccentDisabled` text. |
| **Secondary button** | bg `ButtonBg` (`Chrome`), fg `TextOnChrome`, hover `ButtonHover`, body font, padding 12×5. |
| **Text field / path field** | bg `Chrome`, fg `TextOnChrome`, padding 8×4, insert cursor `Accent`. |
| **Dropdown** | A `Chrome` bar showing `"  <current choice>   ▾"` in `TextOnChrome`, padding 8×5, full section width. Its menu: bg `PanelHi`, fg `TextOnChrome`, hover bg `Accent` / fg `OnAccent`. Tkinter: `tk.Menubutton(indicatoron=False)` + `tk.Menu(tearoff=0)`. **Not `ttk.Combobox`** — clam paints it grey and white. For multiple choices, use checkbutton entries in that menu (Brainiac's "Remove"). |
| **Progress bar** | fill `Accent`, trough `ButtonBg`. Percentage label to its right, body font. |
| **Log** | bg `LogBg`, fg `LogText`, Consolas 9, flat, word wrap. Tags: error `Bad`, ok `Good`, info `MutedOnLog`. Fills its section. |
| **List** | bg `LogBg`, fg `LogText`, selection `Accent` / `OnAccent`, flat. |
| **Radio choice** (choose one of a few modes) | A card per choice: bg `PanelHi`, 2px highlight border (`Border`; the selected card `Accent`), a **hand-drawn** 14px dot (outline `Accent` width 2, filled `Accent` when on, `PanelHi` when off), label in `HeadingOnChrome` bold, blurb in the on-box muted color. **Never `ttk.Radiobutton`** — its indicator ignores colors. |
| **Checkbox** | Avoid on the main page — put options in the dropdown menu or a collapsible panel. Where one is unavoidable: `tk.Checkbutton(bg=<surface>, activebackground=<surface>, selectcolor=ButtonBg, highlightthickness=0, bd=0)`. |

## 8. Drop area (any app that takes files)

- Canvas bg `Drop`, height **78**, full width, hand cursor, inside its section.
- 1px-inset rectangle, outline `DropLine`, `dash=(4, 3)`.
- Empty: `↑` in `DropLine` (Segoe UI 14) at center −11, hint text in `DropHint` body font at center +12, lowercase: *"click to add a song, or drag and drop"*.
- Filled: the file name(s) in `TextOnDrop`, bold, centered, wrapped to width −24.
- Click opens the file picker; real OS drag-and-drop via `tkinterdnd2` (window base class `TkinterDnD.Tk`).

## 9. Text on the page

- Headings and anything drawing attention (e.g. a first-run notice): `Heading`.
- Ordinary text: `Text`. Secondary: `MutedOnPanel`.
- Never `Good`/`Warn`/`Bad` directly on `Panel` (see §1).

## 10. Collapsible panel (advanced/rarely used settings)

- Toggle: a label `"▸ Name (summary)"` / `"▾ Name (summary)"`, `Heading` color, bold, hand cursor.
- Panel: bg `PanelHi`, 1px `Chrome` border, inner padding 10×3. Text inside uses the on-box colors.
- Collapsed by default. Keep the main page to the core flow.

## 11. Layout philosophy

The main page is the core flow only, top to bottom: **input → choice → action → progress → results**.
Options go in a dropdown menu or a collapsed panel, not as rows of checkboxes. Buttons say
what they do ("Make Backing Track"), not "Run".

## 12. Implementation — use these, don't re-derive them

### Python / Tkinter: the kit in `theme.py`

Every Python app builds its window from these. Never restyle a widget by hand.

| Recipe | Call |
|---|---|
| §3 window | `theme.apply_style(root)` before building, `theme.paint_titlebar(root)` after |
| §4 header | `theme.header(root, APP_NAME, blurb)` |
| §5 body | `body = theme.body(root)` |
| §6 section | `theme.section(body, "Name", first=True)` for the first, `expand=True` for the log |
| §7 buttons | `theme.button(parent, "Text", cmd, primary=True/False)` |
| §7 fields | `theme.field(parent, var)`, or `theme.field_row(grid, row, "Label", var, [("Browse", cmd)])` |
| §7 dropdowns | `theme.dropdown(parent, var, choices)`, `theme.dropdown_multi(parent, [(label, BoolVar)], placeholder, extras=[...])` |
| §7 log / list | `theme.log_view(section, scrollbar=True)` · `theme.list_view(parent)` |
| §7 checkbox | `theme.check(parent, "Text", var, bg=surface)` |
| §7 radio cards | `theme.ChoiceCards(frame, [(key, label, blurb)], on_select)` then `.show(key)` |
| §8 drop area | `theme.DropArea(section, "click to …, or drag and drop", on_click, on_files).pack(fill="x")` — window base class `TkinterDnD.Tk` |
| §10 collapsible | `theme.Collapsible(body, "Title", "summary")` — content goes in `.panel` |

`theme.py` must be byte-identical in every Python app; the source of truth is `mix-master\app\theme.py`.

### PowerShell / WPF

`Resolve-Theme` exposes the same roles as `theme.py`. The keys added for this recipe:

| Key | Toothpaste value | Other themes |
|---|---|---|
| `Page` | `Panel` (light) | `Chrome` |
| `SectionLine` | `Chrome` (dark) | `Border` |
| `DropLine` / `Heading` | `#910E4B` | `AccentOnPanel` |
| `TextOnBox` / `MutedOnBox` | readable on `ButtonBg` | same rule |
| `TextOnHeader` | walked from white on `Header` | same rule |
| `MutedOnPanel` | readable `Muted` on `Panel` | same rule |

`Get-ReadableColor`'s fallback picks whichever of `#FFFFFF`/`#101010` actually contrasts more — identical to `theme.py`'s `readable()`. `Set-TitleBand $window $t.Band $t.DropLine` paints DWM border = `DropLine`.

**Template apps (Debloatimizer, CS2 Affinity Manager)** — `Build-StyleXaml` styles:

| Recipe | Style / brush |
|---|---|
| §3 window | `Background="$($t.Page)"` |
| §4 header | `<Border Style="{StaticResource HeaderBand}">` (flush: negative margin inside a padded grid), `<TextBlock Style="{StaticResource AppTitle}"/>`, `<TextBlock Style="{StaticResource AppBlurb}"/>`; anything else on the band uses `TextOnHeaderBrush` / `MutedOnHeaderBrush` |
| §6 section | `<Border Style="{StaticResource Card}">` + `<TextBlock Style="{StaticResource CardHeader}"/>` |
| §7 buttons | `FlatButton` (secondary), `AccentButton` (primary), `MiniButton` |
| §7 boxes | implicit `TextBox`, `ListBox`, `ListBoxItem` styles; `DarkCombo` + `ComboBoxItem`; implicit `CheckBox`, `RadioButton` |

**Resource-dictionary apps (Firewall Manager, Super Simple Security)** — `Get-ThemeResourceDictionary` brushes, used as `{DynamicResource …}`:

| Recipe | Brush / style |
|---|---|
| §3 window | root `Grid Background="{DynamicResource BrushPage}"` |
| §4 header | `Border Background=BrushHeader BorderBrush=BrushDropLine BorderThickness=2 Padding=16,10`; title `FontFamily="Segoe UI Semibold" FontSize="26" Foreground=BrushTitleGradient`; other header text `BrushTextOnHeader` / `BrushMutedOnHeader` |
| §6 section | `CardBorder` style / `GroupBox` style; label `SectionLabel` (`BrushHeading`) |
| §7 | `ThemedButton` (primary), `SecondaryButton`, `DangerButton`, `ThemedTextBox`, `ThemedComboBox`, `ThemedCheckBox`, `ThemedRadio`, `TabHeaderStyle`, `ConsoleScrollViewer` |
| §9 page text | `BrushTextOnPage` / `BrushMutedOnPage` — never `BrushTextOnChrome` for text on the window |

## 13. Checklist before calling an app "on Toothpaste"

- [ ] `theme.py` is byte-identical to `mix-master\app\theme.py` (Python apps), or the PowerShell catalog matches it
- [ ] No hex literal in the app file
- [ ] Header: `DropLine` 2px trim, `Header` fill, gradient title, `MutedOnHeader` blurb
- [ ] DWM border `DropLine`, caption `Band`
- [ ] Every section: 1px `Chrome` border, `Heading` title, padding 8, gap 8
- [ ] Buttons flat; exactly one primary per screen
- [ ] No `ttk.Radiobutton`, no `ttk.Combobox`, no default-styled checkboxes on the main page
- [ ] Log/lists on `LogBg`; status colors only on dark surfaces
