#!/usr/bin/env python3
"""keyboard_pdf.py - the PC keys drawn on the БК-0011М's keyboard, with a legend.

    python3 tools/keyboard_pdf.py [--lang ru|en] [--out FILE.pdf] [--png preview.png]

The picture is prompts/bk-keyboard.png (the БК-0011М keyboard, 573x229);
every key whose PC key is not simply the same letter gets a red label
with the PC key that types it, and under the picture the rest is
written out: the modes, the six Cyrillic letters on symbol keys, the
symbols, the function keys, the controller's hotkeys, the menu.  The
mapping is mnano/bk.c's (the tables) and .claude/docs/mcu.md's.  Pillow
only, one raster page, the way mc0511-elite's tools/control_pdf.py does
it; the fonts are DejaVu's.  `make keyboard` writes keyboard-ru.pdf and
keyboard-en.pdf at the root.
"""

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
PICTURE = ROOT / "prompts" / "bk-keyboard.png"
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FONT_B = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
S = 3                                   # the picture's scale on the page
RED = (200, 16, 16)
INK = (20, 20, 20)
GREY = (90, 90, 90)

# (x0, y0, x1, y1) in the picture's own pixels, and the label: the PC key
KEYS = [
    # the top row
    ((15, 8, 62, 40), "F1"), ((67, 8, 113, 40), "Esc"), ((120, 8, 166, 40), "F5"),
    ((172, 8, 218, 40), "Delete"), ((226, 8, 272, 40), "Insert"), ((280, 8, 327, 40), "F6"),
    ((331, 8, 380, 40), "F7"), ((384, 8, 432, 40), "F8"), ((436, 8, 483, 40), "F9"),
    ((488, 8, 555, 40), "F10 / Pause"),
    # the digits
    # (the label is the PC key of the key's UPPER symbol; the digit is its own key)
    ((14, 44, 45, 75), "F3"), ((47, 44, 81, 75), "Shift+="), ((119, 44, 151, 75), "Shift+'"),
    ((189, 44, 221, 75), "Shift+4"), ((259, 44, 291, 75), "Shift+7"), ((294, 44, 326, 75), "'"),
    ((329, 44, 361, 75), "Shift+9"), ((364, 44, 396, 75), "Shift+0"), ((399, 44, 431, 75), "Shift+["),
    ((434, 44, 466, 75), "="), ((507, 44, 553, 75), "Backspace"),
    # ЙЦУКЕН
    ((15, 79, 62, 111), "Tab"), ((310, 79, 342, 111), "["), ((345, 79, 377, 111), "]"),
    ((450, 79, 482, 111), "Shift+;\nShift+8"), ((485, 79, 517, 111), "Shift+]"), ((522, 79, 556, 111), "F2"),
    ((22, 115, 70, 147), "Right Ctrl"), ((423, 115, 455, 147), "\\"), ((497, 115, 545, 147), "Enter"),
    ((22, 151, 55, 183), "Caps Lock"), ((57, 151, 90, 183), "Shift"), ((127, 151, 159, 183), "Shift+6"),
    ((372, 151, 404, 183), "Shift+2"),
    ((22, 187, 70, 218), "Left Ctrl"), ((73, 187, 105, 218), "Alt"), ((393, 187, 440, 218), "Win"),
]

TEXT = {
    "ru": {
        "title": "БК-0011М на клавиатуре ПК — BK Nano",
        "sub": "красным — клавиша ПК, дающая клавишу БК (на цифровом ряду — её верхний знак); буквы — те же латинские буквы, что на них написаны",
        "items": [
            ("Режимы", "РУС — левый Ctrl, ЛАТ — Win, СТР (регистр букв) — Caps Lock, ЗАГЛ — Shift, "
                       "СУ — правый Ctrl, АР2 — Alt.  Буквы набираются клавишами с теми же латинскими "
                       "буквами (Й = J, Ц = C, У = U, К = K …): в РУС — русские, в ЛАТ — латинские."),
            ("Шесть букв на клавишах знаков", "в режиме РУС: Ш — [, Щ — ], Э — \\, Ч — Shift+6, "
                       "Ю — Shift+2, Ъ — Shift+].  В ЛАТ те же клавиши дают знаки [ ] \\ ^ @ }."),
            ("Знаки", "по клавишам ПК (раскладка US), а не по их месту на БК: & — Shift+7, ( — Shift+9, "
                      ") — Shift+0, \" — Shift+', ' — ', + — Shift+=, = — =, { — Shift+[, : — Shift+;, "
                      "* — Shift+8, ¤ — Shift+4 ($).  Остальные — там же, где на БК."),
            ("Функциональные", "F1 ПОВТ, F2 ВС, F3 ГРАФ, F5 -!->, F6 ИНД СУ, F7 БЛОК РЕД, F8 ШАГ, F9 СБР, "
                               "F10 или Pause — СТОП, F11 — сброс машины (холодный, через AZBOOT), F12 — меню."),
            ("Ещё", "Enter — ВВОД, Shift+Enter — УСТ ТАБ, Tab — ТАБ, Shift+Tab — СБР ТАБ, Backspace — ЗАБОЙ, "
                    "Esc — КТ, Insert — |-->, Delete — |<--, стрелки — стрелки, Home / PgUp / End / PgDn — "
                    "диагональные стрелки.  Цифровой блок — цифры и знаки."),
            ("Горячие клавиши контроллера AZBK", "Alt+Win (АР2+ЛАТ) — экран БК как с чёрно-белого выхода "
                    "(512 точек) или как с цветного (256); Alt+левый Ctrl (АР2+РУС) — вернуть палитры."),
            ("Меню (F12)", "стрелки — по пунктам, влево/вправо — значение, Space или Enter — выбрать, Esc — "
                           "закрыть.  В нём: образы дисков AZ0–AZ3, сброс, частота 4/8 МГц, джойстик, "
                           "громкость, отладка, сохранение настроек."),
        ],
    },
    "en": {
        "title": "The БК-0011М on a PC keyboard — BK Nano",
        "sub": "in red, the PC key that gives the БК key (on the digit row, its upper symbol); the letters are the Latin letters printed on them",
        "items": [
            ("Modes", "РУС (Cyrillic) — Left Ctrl, ЛАТ (Latin) — Win, СТР (letter case) — Caps Lock, "
                      "ЗАГЛ — Shift, СУ (control) — Right Ctrl, АР2 — Alt.  Letters are typed on the keys "
                      "with the same Latin letters (Й = J, Ц = C, У = U, К = K …): Cyrillic in РУС, Latin in ЛАТ."),
            ("Six letters on symbol keys", "in РУС: Ш — [, Щ — ], Э — \\, Ч — Shift+6, Ю — Shift+2, "
                       "Ъ — Shift+].  In ЛАТ the same keys give [ ] \\ ^ @ }."),
            ("Symbols", "by their PC keys (US layout), not by their place on the БК: & — Shift+7, ( — Shift+9, "
                        ") — Shift+0, \" — Shift+', ' — ', + — Shift+=, = — =, { — Shift+[, : — Shift+;, "
                        "* — Shift+8, ¤ — Shift+4 ($).  The rest are where the БК has them."),
            ("Function keys", "F1 ПОВТ (repeat), F2 ВС (line feed), F3 ГРАФ, F5 -!->, F6 ИНД СУ, F7 БЛОК РЕД, "
                              "F8 ШАГ (step), F9 СБР (clear), F10 or Pause — СТОП (halt), F11 — machine reset "
                              "(cold, through AZBOOT), F12 — the menu."),
            ("Also", "Enter — ВВОД, Shift+Enter — УСТ ТАБ, Tab — ТАБ, Shift+Tab — СБР ТАБ, Backspace — ЗАБОЙ, "
                     "Esc — КТ, Insert — |-->, Delete — |<--, the arrows — the arrows, Home / PgUp / End / PgDn "
                     "— the diagonal arrows.  The keypad — digits and symbols."),
            ("The AZBK controller's hotkeys", "Alt+Win (АР2+ЛАТ) — the БК's screen as its monochrome output "
                    "shows it (512 pixels) or as its colour one does (256); Alt+Left Ctrl (АР2+РУС) — the palettes back."),
            ("The menu (F12)", "arrows move, left/right step a value, Space or Enter selects, Esc closes.  "
                               "In it: the disk images AZ0–AZ3, reset, 4/8 MHz, joystick, volume, debug, save settings."),
        ],
    },
}


def wrap(draw, text, font, width):
    words, lines, cur = text.split(" "), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if draw.textlength(t, font=font) <= width:
            cur = t
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def render(lang):
    pic = Image.open(PICTURE).convert("RGB")
    pw, ph = pic.width * S, pic.height * S
    pic = pic.resize((pw, ph), Image.LANCZOS)
    margin = 60
    W = pw + 2 * margin
    f_title = ImageFont.truetype(FONT_B, 40)
    f_sub = ImageFont.truetype(FONT, 22)
    f_head = ImageFont.truetype(FONT_B, 24)
    f_body = ImageFont.truetype(FONT, 24)
    f_key = ImageFont.truetype(FONT_B, 15)
    t = TEXT[lang]

    # the legend's height first, then the page
    scratch = ImageDraw.Draw(Image.new("RGB", (W, 10)))
    blocks = []
    for head, body in t["items"]:
        lines = wrap(scratch, body, f_body, W - 2 * margin - 40)
        blocks.append((head, lines))
    legend_h = sum(34 + 30 * len(lines) + 14 for _, lines in blocks)
    H = margin + 50 + 36 + ph + 40 + legend_h + margin
    page = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(page)

    d.text((margin, margin), t["title"], font=f_title, fill=INK)
    d.text((margin, margin + 52), t["sub"], font=f_sub, fill=GREY)
    top = margin + 50 + 36
    page.paste(pic, (margin, top))

    # the labels: a white box with red text in the key's lower right
    for (x0, y0, x1, y1), label in KEYS:
        lines = label.split("\n")
        tw = max(d.textlength(l, font=f_key) for l in lines)
        th = 19 * len(lines)
        bx1 = margin + x1 * S - 3
        by1 = top + y1 * S - 3
        bx0 = bx1 - tw - 8
        by0 = by1 - th - 4
        d.rounded_rectangle((bx0, by0, bx1, by1), radius=4, fill="white", outline=RED, width=2)
        for i, l in enumerate(lines):
            d.text((bx0 + 4, by0 + 1 + 19 * i), l, font=f_key, fill=RED)

    y = top + ph + 40
    for head, lines in blocks:
        d.text((margin, y), head, font=f_head, fill=RED)
        y += 34
        for l in lines:
            d.text((margin + 40, y), l, font=f_body, fill=INK)
            y += 30
        y += 14
    return page


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--lang", choices=("ru", "en"), default="ru")
    ap.add_argument("--out", default=None)
    ap.add_argument("--png", default=None)
    a = ap.parse_args()
    out = a.out or str(ROOT / f"keyboard-{a.lang}.pdf")
    page = render(a.lang)
    page.save(out, "PDF", resolution=150.0)
    if a.png:
        page.save(a.png)
    print(f"{out}: {page.width}x{page.height} at 150 dpi")


if __name__ == "__main__":
    main()
