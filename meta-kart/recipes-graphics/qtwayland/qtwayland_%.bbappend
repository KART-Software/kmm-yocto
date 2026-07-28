# kmm is a Widgets-only wayland client: keep the client integration, drop the
# compositor half and the QtQuick/Qml integration so libQt6Quick/Qml/
# QuickControls2 (~20MB) stay out of the image. qtdeclarative remains a
# build-time DEPENDS of qtwayland but nothing links it anymore.
PACKAGECONFIG = "wayland-client"
EXTRA_OECMAKE += " \
    -DCMAKE_DISABLE_FIND_PACKAGE_Qt6Quick=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_Qt6Qml=ON \
"

# The ptest suite needs the server-side scanner macros we just disabled and
# ptest packages are not installed in kart-image anyway.
PTEST_ENABLED = "0"
