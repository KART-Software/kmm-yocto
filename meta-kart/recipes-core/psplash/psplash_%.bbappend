FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SPLASH_IMAGES = "file://psplash-kart-img.png;outsuffix=kart"

# Use fullscreen image, no progress bar
PACKAGECONFIG:append = " fullscreen"
PACKAGECONFIG:remove = "startup-msg"
