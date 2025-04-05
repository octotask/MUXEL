#!/bin/bash
set -x
set -e

TARGET_DIR=${1:-target}

TAG_NAME=${TAG_NAME:-$(git -c "core.abbrev=8" show -s "--format=%cd-%h" "--date=format:%Y%m%d-%H%M%S")}

HERE=$(pwd)

if test -z "${SUDO+x}" && hash sudo 2>/dev/null; then
  SUDO="sudo"
fi

if test -e /etc/os-release; then
  . /etc/os-release
fi


case $OSTYPE in
  darwin*)
    zipdir=Muxel-macos-$TAG_NAME
    if [[ "$BUILD_REASON" == "Schedule" ]] ; then
      zipname=Muxel-macos-nightly.zip
    else
      zipname=$zipdir.zip
    fi
    rm -rf $zipdir $zipname
    mkdir $zipdir
    cp -r assets/macos/Muxel.app $zipdir/
    # Omit MetalANGLE for now; it's a bit laggy compared to CGL,
    # and on M1/Big Sur, CGL is implemented in terms of Metal anyway
    rm $zipdir/Muxel.app/*.dylib
    mkdir -p $zipdir/Muxel.app/Contents/MacOS
    mkdir -p $zipdir/Muxel.app/Contents/Resources
    cp -r assets/shell-integration/* $zipdir/Muxel.app/Contents/Resources
    cp -r assets/shell-completion $zipdir/Muxel.app/Contents/Resources
    tic -xe muxel -o $zipdir/Muxel.app/Contents/Resources/terminfo termwiz/data/muxel.terminfo

    for bin in muxel muxel-mux-server muxel-gui strip-ansi-escapes ; do
      # If the user ran a simple `cargo build --release`, then we want to allow
      # a single-arch package to be built
      if [[ -f target/release/$bin ]] ; then
        cp target/release/$bin $zipdir/Muxel.app/Contents/MacOS/$bin
      else
        # The CI runs `cargo build --target XXX --release` which means that
        # the binaries will be deployed in `target/XXX/release` instead of
        # the plain path above.
        # In that situation, we have two architectures to assemble into a
        # Universal ("fat") binary, so we use the `lipo` tool for that.
        lipo target/*/release/$bin -output $zipdir/Muxel.app/Contents/MacOS/$bin -create
      fi
    done

    set +x
    if [ -n "$MACOS_TEAM_ID" ] ; then
      MACOS_PW=$(echo $MACOS_CERT_PW | base64 --decode)
      echo "pw sha"
      echo $MACOS_PW | shasum

      # Remove pesky additional quotes from default-keychain output
      def_keychain=$(eval echo $(security default-keychain -d user))
      echo "Default keychain is $def_keychain"
      echo "Speculative delete of build.keychain"
      security delete-keychain build.keychain || true
      echo "Create build.keychain"
      security create-keychain -p "$MACOS_PW" build.keychain
      echo "Make build.keychain the default"
      security default-keychain -d user -s build.keychain
      echo "Unlock build.keychain"
      security unlock-keychain -p "$MACOS_PW" build.keychain
      echo "Import .p12 data"
      echo $MACOS_CERT | base64 --decode > /tmp/certificate.p12
      echo "decoded sha"
      shasum /tmp/certificate.p12
      security import /tmp/certificate.p12 -k build.keychain -P "$MACOS_PW" -T /usr/bin/codesign
      rm /tmp/certificate.p12
      echo "Grant apple tools access to build.keychain"
      security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$MACOS_PW" build.keychain
      echo "Codesign"
      /usr/bin/codesign --keychain build.keychain --force --options runtime \
        --entitlements ci/macos-entitlement.plist --deep --sign "$MACOS_TEAM_ID" $zipdir/Muxel.app/
      echo "Restore default keychain"
      security default-keychain -d user -s $def_keychain
      echo "Remove build.keychain"
      security delete-keychain build.keychain || true
    fi

    set -x
    zip -r $zipname $zipdir
    set +x

    if [ -n "$MACOS_TEAM_ID" ] ; then
      echo "Notarize"
      xcrun notarytool submit $zipname --wait --team-id "$MACOS_TEAM_ID" --apple-id "$MACOS_APPLEID" --password "$MACOS_APP_PW"
    fi
    set -x

    SHA256=$(shasum -a 256 $zipname | cut -d' ' -f1)
    sed -e "s/@TAG@/$TAG_NAME/g" -e "s/@SHA256@/$SHA256/g" < ci/muxel-homebrew-macos.rb.template > muxel.rb

    ;;
  msys)
    zipdir=Muxel-windows-$TAG_NAME
    if [[ "$BUILD_REASON" == "Schedule" ]] ; then
      zipname=Muxel-windows-nightly.zip
      instname=Muxel-nightly-setup
    else
      zipname=$zipdir.zip
      instname=Muxel-${TAG_NAME}-setup
    fi
    rm -rf $zipdir $zipname
    mkdir $zipdir
    cp $TARGET_DIR/release/muxel.exe \
      $TARGET_DIR/release/muxel-mux-server.exe \
      $TARGET_DIR/release/muxel-gui.exe \
      $TARGET_DIR/release/strip-ansi-escapes.exe \
      $TARGET_DIR/release/muxel.pdb \
      assets/windows/conhost/conpty.dll \
      assets/windows/conhost/OpenConsole.exe \
      assets/windows/angle/libEGL.dll \
      assets/windows/angle/libGLESv2.dll \
      $zipdir
    mkdir $zipdir/mesa
    cp $TARGET_DIR/release/mesa/opengl32.dll \
        $zipdir/mesa
    7z a -tzip $zipname $zipdir
    iscc.exe -DMyAppVersion=${TAG_NAME#nightly} -F${instname} ci/windows-installer.iss
    ;;
  linux-gnu|linux)
    distro=$(lsb_release -is 2>/dev/null || sh -c "source /etc/os-release && echo \$NAME")
    distver=$(lsb_release -rs 2>/dev/null || sh -c "source /etc/os-release && echo \$VERSION_ID")
    case "$distro" in
      *Fedora*|*CentOS*|*SUSE*)
        MUXEL_RPM_VERSION=$(echo ${TAG_NAME#nightly-} | tr - _)
        distroid=$(sh -c "source /etc/os-release && echo \$ID" | tr - _)
        distver=$(sh -c "source /etc/os-release && echo \$VERSION_ID" | tr - _)

        SPEC_RELEASE="1.${distroid}${distver}"
        if test -n "${COPR_SRPM}" ; then
          SPEC_RELEASE=0
        fi

        cat > muxel.spec <<EOF
Name: muxel
Version: ${MUXEL_RPM_VERSION}
Release: ${SPEC_RELEASE}
Packager: Wez Furlong <wez@wezfurlong.org>
License: MIT
URL: https://octotask.github.io/muxel/
Summary: Wez's Terminal Emulator.
%if 0%{?suse_version}
Requires: dbus-1, fontconfig, openssl, libxcb1, libxkbcommon0, libxkbcommon-x11-0, libwayland-client0, libwayland-egl1, libwayland-cursor0, Mesa-libEGL1, libxcb-keysyms1, libxcb-ewmh2, libxcb-icccm4
%else
Requires: dbus, fontconfig, openssl, libxcb, libxkbcommon, libxkbcommon-x11, libwayland-client, libwayland-egl, libwayland-cursor, mesa-libEGL, xcb-util-keysyms, xcb-util-wm
%endif
EOF

        BUILD_COMMAND=<<EOF
%build
echo build
EOF

        if test -n "${COPR_SRPM}" ; then

          TAR_NAME=$(git -c "core.abbrev=8" show -s "--format=%cd_%h" "--date=format:%Y%m%d_%H%M%S")

          cat >> muxel.spec <<EOF
BuildRequires: gcc, gcc-c++, make, curl, fontconfig-devel, openssl-devel, libxcb-devel, libxkbcommon-devel, libxkbcommon-x11-devel, wayland-devel, xcb-util-devel, xcb-util-keysyms-devel, xcb-util-image-devel, xcb-util-wm-devel, git
%if 0%{?suse_version}
BuildRequires: Mesa-libEGL-devel
%else
BuildRequires: mesa-libEGL-devel
%endif
%if 0%{?fedora} >= 41
BuildRequires: openssl-devel-engine
%endif
Source0: muxel-${TAR_NAME}.tar.gz

%global debug_package %{nil}

%changelog
* Mon Oct 2 2023 Wez Furlong
- See git for full changelog

EOF
          HERE="."
          BUILD_COMMAND=$(cat <<EOF
%prep
%autosetup
%build

echo Here I am

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source ~/.cargo/env

cargo build --release \
      -p muxel-gui -p muxel -p muxel-mux-server \
      -p strip-ansi-escapes

EOF
)

        fi

        cat >> muxel.spec <<EOF
%description
muxel is a terminal emulator with support for modern features
such as fonts with ligatures, hyperlinks, tabs and multiple
windows.

${BUILD_COMMAND}

%install
set -x
cd ${HERE}
mkdir -p %{buildroot}/usr/bin %{buildroot}/etc/profile.d
install -Dm755 assets/open-muxel-here -t %{buildroot}/usr/bin
install -Dsm755 target/release/muxel -t %{buildroot}/usr/bin
install -Dsm755 target/release/muxel-mux-server -t %{buildroot}/usr/bin
install -Dsm755 target/release/muxel-gui -t %{buildroot}/usr/bin
install -Dsm755 target/release/strip-ansi-escapes -t %{buildroot}/usr/bin
install -Dm644 assets/shell-integration/* -t %{buildroot}/etc/profile.d
install -Dm644 assets/shell-completion/zsh %{buildroot}/usr/share/zsh/site-functions/_muxel
install -Dm644 assets/shell-completion/bash %{buildroot}/etc/bash_completion.d/muxel
install -Dm644 assets/icon/terminal.png %{buildroot}/usr/share/icons/hicolor/128x128/apps/org.wezfurlong.muxel.png
install -Dm644 assets/muxel.desktop %{buildroot}/usr/share/applications/org.wezfurlong.muxel.desktop
install -Dm644 assets/muxel.appdata.xml %{buildroot}/usr/share/metainfo/org.wezfurlong.muxel.appdata.xml
install -Dm644 assets/muxel-nautilus.py %{buildroot}/usr/share/nautilus-python/extensions/muxel-nautilus.py

%files
/usr/bin/open-muxel-here
/usr/bin/muxel
/usr/bin/muxel-gui
/usr/bin/muxel-mux-server
/usr/bin/strip-ansi-escapes
/usr/share/zsh/site-functions/_muxel
/etc/bash_completion.d/muxel
/usr/share/icons/hicolor/128x128/apps/org.wezfurlong.muxel.png
/usr/share/applications/org.wezfurlong.muxel.desktop
/usr/share/metainfo/org.wezfurlong.muxel.appdata.xml
/usr/share/nautilus-python/extensions/muxel-nautilus.py*
/etc/profile.d/*
EOF

        if test -n "${COPR_SRPM}" ; then
          /usr/bin/rpmbuild -bs --rmspec muxel.spec --verbose
          mv $(rpm --eval '%{_srcrpmdir}')/muxel-${TAR_NAME}*.src.rpm "${COPR_SRPM}"/
        else
          /usr/bin/rpmbuild -bb --rmspec muxel.spec --verbose
        fi

        ;;
      Ubuntu*|Debian*|Pop)
        rm -rf pkg
        mkdir -p pkg/debian/usr/bin pkg/debian/DEBIAN pkg/debian/usr/share/{applications,muxel}

        if [[ "$BUILD_REASON" == "Schedule" ]] ; then
          pkgname=muxel-nightly
          conflicts=muxel
        else
          pkgname=muxel
          conflicts=muxel-nightly
        fi

        cat > pkg/debian/control <<EOF
Package: $pkgname
Version: ${TAG_NAME#nightly-}
Conflicts: $conflicts
Architecture: $(dpkg-architecture -q DEB_BUILD_ARCH_CPU)
Maintainer: Wez Furlong <wez@wezfurlong.org>
Section: utils
Priority: optional
Homepage: https://octotask.github.io/muxel/
Description: Wez's Terminal Emulator.
 muxel is a terminal emulator with support for modern features
 such as fonts with ligatures, hyperlinks, tabs and multiple
 windows.
Provides: x-terminal-emulator
Source: https://octotask.github.io/muxel/
EOF

        cat > pkg/debian/postinst <<EOF
#!/bin/sh
set -e
if [ "\$1" = "configure" ] ; then
        update-alternatives --install /usr/bin/x-terminal-emulator x-terminal-emulator /usr/bin/open-muxel-here 20
fi
EOF

        cat > pkg/debian/prerm <<EOF
#!/bin/sh
set -e
if [ "\$1" = "remove" ]; then
	update-alternatives --remove x-terminal-emulator /usr/bin/open-muxel-here
fi
EOF

        install -Dsm755 -t pkg/debian/usr/bin target/release/muxel-mux-server
        install -Dsm755 -t pkg/debian/usr/bin target/release/muxel-gui
        install -Dsm755 -t pkg/debian/usr/bin target/release/muxel
        install -Dm755 -t pkg/debian/usr/bin assets/open-muxel-here
        install -Dsm755 -t pkg/debian/usr/bin target/release/strip-ansi-escapes

        deps=$(cd pkg && dpkg-shlibdeps -O -e debian/usr/bin/*)
        mv pkg/debian/postinst pkg/debian/DEBIAN/postinst
        chmod 0755 pkg/debian/DEBIAN/postinst
        mv pkg/debian/prerm pkg/debian/DEBIAN/prerm
        chmod 0755 pkg/debian/DEBIAN/prerm
        mv pkg/debian/control pkg/debian/DEBIAN/control
        sed -i '/^Source:/d' pkg/debian/DEBIAN/control  # The `Source:` field needs to be valid in a binary package
        echo $deps | sed -e 's/shlibs:Depends=/Depends: /' >> pkg/debian/DEBIAN/control
        cat pkg/debian/DEBIAN/control

        install -Dm644 assets/icon/terminal.png pkg/debian/usr/share/icons/hicolor/128x128/apps/org.wezfurlong.muxel.png
        install -Dm644 assets/muxel.desktop pkg/debian/usr/share/applications/org.wezfurlong.muxel.desktop
        install -Dm644 assets/muxel.appdata.xml pkg/debian/usr/share/metainfo/org.wezfurlong.muxel.appdata.xml
        install -Dm644 assets/muxel-nautilus.py pkg/debian/usr/share/nautilus-python/extensions/muxel-nautilus.py
        install -Dm644 assets/shell-completion/bash pkg/debian/usr/share/bash-completion/completions/muxel
        install -Dm644 assets/shell-completion/zsh pkg/debian/usr/share/zsh/functions/Completion/Unix/_muxel
        install -Dm644 assets/shell-integration/* -t pkg/debian/etc/profile.d

        if [[ "$BUILD_REASON" == "Schedule" ]] ; then
          debname=muxel-nightly.$distro$distver
        else
          debname=muxel-$TAG_NAME.$distro$distver
        fi
        arch=$(dpkg-architecture -q DEB_BUILD_ARCH_CPU)
        case $arch in
          amd64)
            ;;
          *)
            debname="${debname}.${arch}"
            ;;
        esac

        fakeroot dpkg-deb --build pkg/debian $debname.deb

        if [[ "$BUILD_REASON" != '' ]] ; then
          $SUDO apt-get install ./$debname.deb
        fi

        mv pkg/debian pkg/muxel
        tar cJf $debname.tar.xz -C pkg muxel
        rm -rf pkg
      ;;
    esac
    ;;
  linux-musl)
    case $ID in
      alpine)
        export SUDO=''
        abuild-keygen -a -n -b 8192
        pkgver="${TAG_NAME#nightly-}"
        cat > APKBUILD <<EOF
# Maintainer: Wez Furlong <wez@wezfurlong.org>
pkgname=muxel
pkgver=$(echo "$pkgver" | cut -d'-' -f1-2 | tr - .)
_pkgver=$pkgver
pkgrel=0
pkgdesc="A GPU-accelerated cross-platform terminal emulator and multiplexer written in Rust"
license="MIT"
arch="all"
options="!check"
url="https://octotask.github.io/muxel/"
makedepends="cmd:tic"
source="
  target/release/muxel
  target/release/muxel-gui
  target/release/muxel-mux-server
  assets/open-muxel-here
  assets/muxel.desktop
  assets/muxel.appdata.xml
  assets/icon/terminal.png
  assets/icon/muxel-icon.svg
  termwiz/data/muxel.terminfo
"
builddir="\$srcdir"

build() {
  tic -x -o "\$builddir"/muxel.terminfo "\$srcdir"/muxel.terminfo
}

package() {
  install -Dm755 -t "\$pkgdir"/usr/bin "\$srcdir"/open-muxel-here
  install -Dm755 -t "\$pkgdir"/usr/bin "\$srcdir"/muxel
  install -Dm755 -t "\$pkgdir"/usr/bin "\$srcdir"/muxel-gui
  install -Dm755 -t "\$pkgdir"/usr/bin "\$srcdir"/muxel-mux-server

  install -Dm644 -t "\$pkgdir"/usr/share/applications "\$srcdir"/muxel.desktop
  install -Dm644 -t "\$pkgdir"/usr/share/metainfo "\$srcdir"/muxel.appdata.xml
  install -Dm644 "\$srcdir"/terminal.png "\$pkgdir"/usr/share/pixmaps/muxel.png
  install -Dm644 "\$srcdir"/muxel-icon.svg "\$pkgdir"/usr/share/pixmaps/muxel.svg
  install -Dm644 "\$srcdir"/terminal.png "\$pkgdir"/usr/share/icons/hicolor/128x128/apps/muxel.png
  install -Dm644 "\$srcdir"/muxel-icon.svg "\$pkgdir"/usr/share/icons/hicolor/scalable/apps/muxel.svg
  install -Dm644 "\$builddir"/muxel.terminfo "\$pkgdir"/usr/share/terminfo/w/muxel
}
EOF
        abuild -F checksum
        abuild -Fr
      ;;
    esac
    ;;
  *)
    ;;
esac
