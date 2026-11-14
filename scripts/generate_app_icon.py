#!/usr/bin/env python3
"""Render the code-defined companion app icon; no source imagery is used."""
from pathlib import Path
from PIL import Image, ImageDraw
root = Path(__file__).resolve().parents[1]
image = Image.new('RGB', (1024, 1024), '#0b252e')
draw = ImageDraw.Draw(image)
draw.rounded_rectangle((60, 60, 964, 964), radius=220, fill='#103a44')
draw.polygon([(512,174),(790,286),(754,586),(665,744),(512,854),(359,744),(270,586),(234,286)], fill='#36d6bb')
draw.polygon([(512,240),(721,326),(693,565),(615,701),(512,782),(409,701),(331,565),(303,326)], fill='#0b252e')
draw.line([(350,510),(430,510),(473,410),(540,615),(592,510),(678,510)], fill='#e6fffa', width=32, joint='curve')
image.save(root/'ios/RayGuardian/Resources/Assets.xcassets/AppIcon.appiconset/Icon.png')
