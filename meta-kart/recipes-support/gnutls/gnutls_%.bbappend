# poky distro は既定で DISTRO_FEATURES に ptest を含む。gnutls 3.8.x の ptest
# スイートは fips-test のリンクで壊れる (utils.c が各テストの定義する `doit`
# を要求するが fips-test が与えず undefined reference → do_install_ptest_base
# 失敗)。ptest パッケージは kart-image に一切入らないので、qtwayland と同じく
# ビルドだけ無効化する (qtwayland_%.bbappend と同方針)。
PTEST_ENABLED = "0"
