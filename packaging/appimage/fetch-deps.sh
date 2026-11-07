#!/bin/sh
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 SEN Labs e.U.
#
# What the server is built from besides this repository, in .deps/: the API headers of sento, with what Linux needs of them
# (sento-linux.patch), and the ontology installer and the generated ontology headers of sen-oni. The versions are in haiku-app.env.
set -eu
cd "$(dirname "$0")/../.."
. ./haiku-app.env

DEPS=.deps
if [ ! -d "$DEPS/sento" ]; then
	mkdir -p "$DEPS"
	git clone -q --depth 1 --branch "$SENTO_TAG" https://github.com/sen-laboratories/sento.git "$DEPS/sento"
	( cd "$DEPS/sento" && patch -p1 --no-backup-if-mismatch < ../../packaging/appimage/sento-linux.patch )
fi
[ -d "$DEPS/sen-oni" ] || git clone -q --depth 1 --branch "$ONI_TAG" https://github.com/sen-laboratories/sen-oni.git "$DEPS/sen-oni"

mkdir -p "$DEPS/include/sen"
cp "$DEPS"/sento/src/cpp/include/*.h "$DEPS"/sen-oni/include/*.h "$DEPS/include/sen/"
