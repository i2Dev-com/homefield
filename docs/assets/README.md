# Assets

`homefield-banner.svg` is the source of `homefield-banner.png`, the image at
the top of the README and the repository's social preview (1280×640). The
PNG is committed so the text renders the same everywhere; after editing the
SVG, render it again with Chrome from this directory:

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
  --hide-scrollbars --force-device-scale-factor=1 --window-size=1280,640 \
  --screenshot="$PWD/homefield-banner.png" "file://$PWD/homefield-banner.svg"
```
