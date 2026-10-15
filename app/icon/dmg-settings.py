# dmgbuild settings for the Samsung SpliX Installer DMG.
#
# Note: since macOS 26 "Tahoe", Finder no longer accepts setting a DMG window
# background picture (neither via AppleScript nor via the .DS_Store alias), so
# this builds a clean image with large, well-placed icons and a custom volume
# icon instead.  No Finder / Apple Events permission is needed.
import os

app_path = defines.get('app')                 # noqa: F821
volicon  = defines.get('volicon', None)       # noqa: F821

files = [app_path]
symlinks = {'Applications': '/Applications'}

icon_locations = {
    os.path.basename(app_path): (140, 190),
    'Applications': (400, 190),
}

if volicon:
    icon = volicon

window_rect = ((320, 200), (540, 380))
default_view = 'icon-view'
icon_size = 128
text_size = 13

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

format = 'UDZO'
