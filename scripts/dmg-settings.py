# dmgbuild settings for Muster.dmg, read by scripts/dmg.sh. dmgbuild writes the Finder
# layout itself, so building needs neither Finder nor any scripting permission.
import os.path

app = defines["app"]
name = os.path.basename(app)

volume_name = "Muster"
format = "ULFO"            # LZFSE: smaller and faster to open than zlib, macOS 10.11+
filesystem = "HFS+"
size = None
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["volume_icon"]
hide_extensions = [name]

background = defines["background"]
window_rect = ((200, 140), (660, 432))   # 400 points of background under a 32-point title bar
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 128
text_size = 13
icon_locations = {name: (170, 208), "Applications": (490, 208)}
