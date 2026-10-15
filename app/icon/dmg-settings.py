# dmgbuild settings for the Samsung SpliX Installer DMG.
# Writes the .DS_Store itself, so no Finder / Apple Events permission is needed.
import os

app_path = defines.get('app')            # noqa: F821
bg_path  = defines.get('background')     # noqa: F821

files = [app_path]
symlinks = {'Applications': '/Applications'}

icon_locations = {
    os.path.basename(app_path): (140, 190),
    'Applications': (400, 190),
}

background = bg_path
window_rect = ((320, 200), (540, 380))
default_view = 'icon-view'

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

format = 'UDZO'
