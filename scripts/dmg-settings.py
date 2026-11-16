# dmgbuild settings for make-dmg.sh. dmgbuild writes the Finder layout itself,
# so the result doesn't depend on Finder preferences such as "Prefer tabs".
app = defines["app"]  # staged "Immich Viewer.app"

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = ["Immich Viewer.app"]

background = "scripts/dmg-background.tiff"  # 660×400 pt, 1x and 2x
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {"Immich Viewer.app": (170, 180), "Applications": (490, 180)}
