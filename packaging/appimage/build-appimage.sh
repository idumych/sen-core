#!/bin/sh
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 SEN Labs e.U.
#
# The SEN server for any x86_64 or aarch64 Linux desktop, as an AppImage, with Hokku (https://github.com/idumych/hokku, a fork of
# Cosmoe), the Haiku API as a library on X11 and Wayland.
#
#   sh packaging/appimage/build-appimage.sh
#
# Run it in CI (.github/workflows/appimage.yml, Ubuntu 24.04), not on a rolling-release host: the AppImage needs the oldest glibc
# it should run on. It builds Hokku into .cosmoe/, unless COSMOE_STAGE points at a DESTDIR install of it made with --prefix=/usr
# --libdir=lib. Based on the beos-app-platforms template, which packages one program: this one packages the server, its settings,
# the ontology installer with the core ontology, and the tools that the installer calls.
set -eu
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
. ./haiku-app.env

COSMOE_REPO=${COSMOE_REPO:-idumych/hokku}
COSMOE_TAG=${COSMOE_TAG:-hokku}
LINUXDEPLOY_TAG=1-alpha-20251107-1
APPIMAGETOOL_TAG=1.9.1
case "$(uname -m)" in
	x86_64) ARCH=x86_64 ;;
	aarch64|arm64) ARCH=aarch64 ;;
	*) echo "build-appimage: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

WORK="$ROOT/.cosmoe"
OUT="$ROOT/${APP_NAME}-${VERSION}-${ARCH}.AppImage"
mkdir -p "$WORK/tools"

# 1. Hokku
if [ -z "${COSMOE_STAGE:-}" ]; then
	COSMOE_STAGE="$WORK/stage"
	if [ ! -f "$COSMOE_STAGE/usr/lib/libbe.so" ]; then
		[ -d "$WORK/src" ] || git clone --depth 1 --branch "$COSMOE_TAG" \
			"https://github.com/$COSMOE_REPO.git" "$WORK/src"
		# enable_apps=false leaves out its apps and their catalogs: only the libraries, add-ons, data and tools are needed.
		meson setup "$WORK/build" "$WORK/src" --prefix=/usr --libdir=lib \
			--buildtype=release -Denable_unit_test_compile=false -Denable_apps=false
		ninja -C "$WORK/build"
		DESTDIR="$COSMOE_STAGE" meson install -C "$WORK/build" --no-rebuild
	fi
fi
CROOT="$COSMOE_STAGE/usr"

# 2. The programs. Strip at link time; resources live in an allocated .cosmoe_rsrc section, which stripping keeps.
sh packaging/appimage/fetch-deps.sh
make -f Makefile.cosmoe COSMOE_ROOT="$CROOT" clean >/dev/null
make -f Makefile.cosmoe -j"$(nproc)" COSMOE_ROOT="$CROOT" LDFLAGS="${LDFLAGS:-} -s"

# 3. AppDir
APPDIR="$ROOT/obj-cosmoe/AppDir"
DOC="$APPDIR/usr/share/doc/$APP_CMD"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/share/cosmoe/sen/ontologies" \
	"$APPDIR/usr/share/fonts/noto" "$APPDIR/etc/fonts" "$DOC"

install -m 0755 bin/sen_server bin/sen_settings bin/sen_mime "$APPDIR/usr/bin/"
# (oni.sh takes bin/mime for a source tree; in the AppImage it finds sen_mime on the PATH, as in its package)
install -m 0755 .deps/sen-oni/scripts/oni.sh "$APPDIR/usr/bin/sen_oni"
# (where sen_oni --update finds the ontologies of packages: the system's data folder is next to libbe.so)
cp -a .deps/sen-oni/ontologies/core "$APPDIR/usr/share/cosmoe/sen/ontologies/"

# What oni.sh calls. (rmattr is optional for it, and Hokku doesn't build it.)
PROGRAMS="sen_server sen_settings sen_mime"
for tool in rc resattr addattr catattr listattr finddir rmattr TrayExport; do
	[ -x "$CROOT/bin/$tool" ] || continue
	install -m 0755 "$CROOT/bin/$tool" "$APPDIR/usr/bin/$tool"
	PROGRAMS="$PROGRAMS $tool"
done

# The Hokku libraries that the programs link, and the catalogs of those.
LIBS="libbe.so libcosmoe-x11.so libcosmoe-wayland.so"
CATALOGS="x-vnd.Haiku-libbe x-vnd.Haiku-libtextencoding"
for program in $PROGRAMS; do
	for lib in $(readelf -d "$APPDIR/usr/bin/$program" | sed -n 's/.*NEEDED.*\[\(lib[^]]*\)\]/\1/p'); do
		case " $LIBS " in *" $lib "*) continue ;; esac
		[ -e "$CROOT/lib/$lib" ] || continue	# not Hokku's: linuxdeploy bundles it
		LIBS="$LIBS $lib"
		[ "$lib" != libtracker.so ] || CATALOGS="$CATALOGS x-vnd.Haiku-libtracker"
	done
done
for lib in $LIBS; do
	# under the name the binary asks for, not a symlink
	install -m 0755 "$(readlink -f "$CROOT/lib/$lib")" "$APPDIR/usr/lib/$lib"
done

mkdir -p "$APPDIR/usr/lib/addons/Translators"
cp -a "$CROOT/lib/addons/control_look" "$APPDIR/usr/lib/addons/"
for t in $APPIMAGE_TRANSLATORS; do
	[ -f "$CROOT/lib/addons/Translators/${t}Translator.so" ] \
		|| { echo "build-appimage: no ${t}Translator.so in Hokku" >&2; exit 1; }
	cp "$CROOT/lib/addons/Translators/${t}Translator.so" "$APPDIR/usr/lib/addons/Translators/"
	CATALOGS="$CATALOGS x-vnd.Haiku-${t}Translator"
done
for d in mime_db artwork; do
	cp -a "$CROOT/share/cosmoe/$d" "$APPDIR/usr/share/cosmoe/"
done
CATDIR="$APPDIR/usr/share/cosmoe/locale/catalogs"
mkdir -p "$CATDIR"
for c in $CATALOGS; do
	[ ! -d "$CROOT/share/cosmoe/locale/catalogs/$c" ] || cp -a "$CROOT/share/cosmoe/locale/catalogs/$c" "$CATDIR/"
done
cp -a "$CROOT"/share/cosmoe/*.png "$APPDIR/usr/share/cosmoe/" 2>/dev/null || :
for f in NotoSans-Regular NotoSans-Bold NotoSans-Italic NotoSans-BoldItalic NotoSansMono-Regular NotoSansMono-Bold; do
	find "$CROOT/share/fonts" -name "$f.ttf" -exec cp {} "$APPDIR/usr/share/fonts/noto/" \;
done
cp packaging/appimage/fonts.conf "$APPDIR/etc/fonts/fonts.conf"
cp LICENSE "$DOC/LICENSE"
cp .deps/sento/LICENSE "$DOC/SENTO-LICENSE"
cp .deps/sen-oni/LICENSE "$DOC/SEN-ONI-LICENSE"
[ ! -f "$WORK/src/License.md" ] && [ -n "${COSMOE_LICENSE:-}" ] && cp "$COSMOE_LICENSE" "$DOC/COSMOE-LICENSE.md"
[ -f "$DOC/COSMOE-LICENSE.md" ] || cp "$WORK/src/License.md" "$DOC/COSMOE-LICENSE.md" 2>/dev/null \
	|| curl -fsSL "https://raw.githubusercontent.com/$COSMOE_REPO/$COSMOE_TAG/License.md" -o "$DOC/COSMOE-LICENSE.md"
find "$APPDIR/usr/lib" -name '*.so' -exec strip --strip-unneeded {} \;

# desktop entry, icon and AppRun
GEN="$ROOT/obj-cosmoe/appimage-gen"
rm -rf "$GEN" && mkdir -p "$GEN"
cat > "$GEN/$APP_CMD.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=$SUMMARY
Exec=$APP_NAME
Icon=$APP_CMD
Terminal=false
Categories=$DESKTOP_CATEGORIES
EOF
convert images/sen-server_icon.png -background none -resize 256x256 -gravity center -extent 256x256 "$GEN/$APP_CMD.png" 2>/dev/null \
	|| magick images/sen-server_icon.png -background none -resize 256x256 -gravity center -extent 256x256 "$GEN/$APP_CMD.png"
cp packaging/appimage/AppRun.in "$GEN/AppRun"
chmod +x "$GEN/AppRun"

# 4. Bundle what the programs and Hokku need (ICU, pango, cairo, spdlog, fmt...), leaving out what every desktop has. NO_STRIP:
#    linuxdeploy's strip is older than some distros' libraries.
fetch() {
	[ -x "$WORK/tools/$1" ] || { curl -fsSL "$2" -o "$WORK/tools/$1"; chmod +x "$WORK/tools/$1"; }
}
fetch linuxdeploy "https://github.com/linuxdeploy/linuxdeploy/releases/download/$LINUXDEPLOY_TAG/linuxdeploy-$ARCH.AppImage"
fetch appimagetool "https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_TAG/appimagetool-$ARCH.AppImage"
export APPIMAGE_EXTRACT_AND_RUN=1	# no FUSE needed (CI containers)

# linuxdeploy appends $ORIGIN to a RUNPATH but keeps what is there: reset them first, so that the host's libraries don't win.
LDROOT="$WORK/tools/linuxdeploy-root"
if [ ! -x "$LDROOT/AppRun" ]; then
	( cd "$WORK/tools" && rm -rf squashfs-root && ./linuxdeploy --appimage-extract >/dev/null \
		&& mv squashfs-root linuxdeploy-root )
fi
PATCHELF=$(find "$LDROOT" -name patchelf -type f | head -1)
for so in "$APPDIR"/usr/lib/*.so "$APPDIR"/usr/lib/*.so.*; do
	[ ! -e "$so" ] || "$PATCHELF" --set-rpath '$ORIGIN' "$so"
done
for so in $(find "$APPDIR/usr/lib/addons" -name '*.so'); do
	"$PATCHELF" --set-rpath '$ORIGIN/../..' "$so"
done
EXECUTABLES=""
for program in $PROGRAMS; do
	"$PATCHELF" --set-rpath '$ORIGIN/../lib' "$APPDIR/usr/bin/$program"
	EXECUTABLES="$EXECUTABLES --executable $APPDIR/usr/bin/$program"
done
DEPS_ONLY=""
for so in $(find "$APPDIR/usr/lib/addons" -name '*.so') \
		"$APPDIR/usr/lib/libcosmoe-x11.so" "$APPDIR/usr/lib/libcosmoe-wayland.so"; do
	DEPS_ONLY="$DEPS_ONLY --deploy-deps-only=$so"
done
# shellcheck disable=SC2086
NO_STRIP=1 LD_LIBRARY_PATH="$APPDIR/usr/lib" "$LDROOT/AppRun" --appdir "$APPDIR" \
	$EXECUTABLES $DEPS_ONLY \
	--desktop-file "$GEN/$APP_CMD.desktop" \
	--icon-file "$GEN/$APP_CMD.png" \
	--custom-apprun "$GEN/AppRun"

# The libraries that have to be in it.
for lib in $APPIMAGE_MUST_BUNDLE; do
	ls "$APPDIR/usr/lib/$lib".so* >/dev/null 2>&1 || { echo "build-appimage: $lib is not bundled" >&2; exit 1; }
done

# 5. Pack
rm -f "$OUT"
ARCH=$ARCH "$WORK/tools/appimagetool" --no-appstream "$APPDIR" "$OUT"
echo "Built $OUT"
