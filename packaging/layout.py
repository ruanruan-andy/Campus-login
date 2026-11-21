"""Write Finder window layout into the mounted installer image."""
import pathlib
import sys
from ds_store import DSStore
from mac_alias import Alias, Bookmark

volume = pathlib.Path(sys.argv[1])
background = Alias.for_file(str(volume / ".background" / "background.png")).to_bytes()
with DSStore.open(str(volume / ".DS_Store"), "w+") as store:
    store["."]["bwsp"] = {
        "ShowStatusBar": False,
        "ShowPathbar": False,
        "ShowToolbar": False,
        "ShowSidebar": False,
        "ContainerShowSidebar": False,
        "WindowBounds": "{{100, 100}, {760, 508}}",
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundColorRed": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorBlue": 1.0,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
        "backgroundImageAlias": background,
        "iconSize": 128.0,
        "textSize": 15.0,
        "gridSpacing": 54.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "arrangeBy": "none",
        "labelOnBottom": True,
        "showIconPreview": True,
        "showItemInfo": False,
    }
    store["."]["vSrn"] = ("long", 1)
    store["."]["icvl"] = ("type", "icnv")
    store["."]["pBBk"] = Bookmark.from_bytes((volume / ".background" / "bookmark").read_bytes())
    store["Campus Login.app"]["Iloc"] = (190, 230)
    store["Applications"]["Iloc"] = (570, 230)
