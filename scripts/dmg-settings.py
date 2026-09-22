# dmgbuild settings for the MacUtil disk image; scripts/release.sh passes -D app=… -D root=….
# Icon positions must match appCenter and applicationsCenter in scripts/make-dmg-background.swift.
import os.path

app = defines["app"]
root = defines["root"]
app_name = os.path.basename(app)

format = "ULFO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")

background = os.path.join(root, "Resources/DMG/background.tiff")
# Height adds the Finder title bar to the 450-point background.
window_rect = ((200, 120), (660, 478))
default_view = "icon-view"
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_pathbar = False
show_tab_view = False
show_icon_preview = False
icon_size = 112
text_size = 13
arrange_by = None
icon_locations = {
    app_name: (170, 150),
    "Applications": (490, 150),
    # Out of sight for people who show hidden files in Finder.
    ".background.tiff": (1000, 1000),
    ".VolumeIcon.icns": (1000, 1000),
}
hide_extensions = [app_name]
