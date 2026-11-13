import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter
out = sys.argv[1]
S = 1600                                   # drawn large, scaled down for smooth edges
BG, BG2 = (19, 19, 22), (30, 30, 35)
COPPER, DARK, LIGHT, EDGE = (219, 143, 69), (150, 90, 40), (242, 186, 118), (104, 60, 26)
FONT = "/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf"

img = Image.new("RGB", (S, S), BG)
d = ImageDraw.Draw(img)
# soft lighter disc behind the coin so it does not float on flat black
glow = Image.new("L", (S, S), 0)
ImageDraw.Draw(glow).ellipse((300, 130, 1300, 1130), fill=70)
glow = glow.filter(ImageFilter.GaussianBlur(160))
img.paste(Image.new("RGB", (S, S), BG2), (0, 0), glow)
d = ImageDraw.Draw(img)

cx, cy, r = 800, 610, 370
# coin drawn on its own layer so a bite can be cut out of it
coin = Image.new("RGBA", (S, S), (0, 0, 0, 0))
c = ImageDraw.Draw(coin)
c.ellipse((cx - r, cy - r + 26, cx + r, cy + r + 26), fill=EDGE)          # thickness, seen from slightly above
c.ellipse((cx - r, cy - r, cx + r, cy + r), fill=DARK)                     # rim
c.ellipse((cx - r + 34, cy - r + 34, cx + r - 34, cy + r - 34), fill=COPPER)
c.ellipse((cx - r + 78, cy - r + 78, cx + r - 78, cy + r - 78), outline=DARK, width=12)
# highlight arc on the upper left of the rim
c.arc((cx - r + 14, cy - r + 14, cx + r - 14, cy + r - 14), start=190, end=262, fill=LIGHT, width=14)
# the letter, struck into the coin: dark face with a light lower edge
f = ImageFont.truetype(FONT, 470)
box = c.textbbox((0, 0), "p", font=f)
tx, ty = cx - (box[0] + box[2]) / 2, cy - (box[1] + box[3]) / 2 - 6
c.text((tx + 7, ty + 9), "p", font=f, fill=LIGHT)
c.text((tx, ty), "p", font=f, fill=DARK)
# a bite out of the coin: this guild cannot even afford a whole one
bite = Image.new("L", (S, S), 255)
b = ImageDraw.Draw(bite)
b.ellipse((1010, 215, 1250, 455), fill=0)
b.ellipse((1150, 380, 1300, 530), fill=0)
coin.putalpha(Image.composite(coin.getchannel("A"), Image.new("L", (S, S), 0), bite))
img.paste(coin, (0, 0), coin)
d = ImageDraw.Draw(img)

# the name, letter-spaced
f2 = ImageFont.truetype(FONT, 250)
text, gap = "poor", 26
widths = [d.textbbox((0, 0), ch, font=f2)[2] - d.textbbox((0, 0), ch, font=f2)[0] for ch in text]
total = sum(widths) + gap * (len(text) - 1)
x = (S - total) / 2
for ch, w in zip(text, widths):
    bx = d.textbbox((0, 0), ch, font=f2)
    d.text((x - bx[0], 1110), ch, font=f2, fill=(236, 236, 238))
    x += w + gap
d.rectangle(((S - 200) / 2, 1452, (S + 200) / 2, 1464), fill=COPPER)      # small copper rule under the name

for size in (512, 400):
    img.resize((size, size), Image.LANCZOS).save(f"{out}/logo-{size}.png")
print("written")
