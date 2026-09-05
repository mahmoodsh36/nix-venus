# Darwin host overlay. Overrides upstream recipes with UTM forks.
# Takes sources and lib as arguments so the flake can expose the overlay
# on its own next to the mkVenus entry point.
{ sources, lib }:

final: prev: let
  # UTM release tarball with all meson subprojects vendored. We borrow
  # subprojects from it to avoid wrap-git fetches in the sandbox. Both
  # qemu branches consume the same wrap files.
  qemuSubprojectsBlob = final.fetchurl {
    name = "qemu-10.0.2-utm.tar.xz";
    url  = "https://github.com/utmapp/qemu/releases/download/v10.0.2-utm/qemu-10.0.2-utm.tar.xz";
    hash = "sha256-8dc1dUenGuMzmhFdXI8rcuOwCJUx1nwqykMybTIKxso=";
  };

  mkQemuVenus = {
    pname,
    rev,
    srcHash,
    versionSuffix,
    extraPatches ? [],
  }: (prev.qemu.override {
    # openGLSupport=false avoids libgbm and libdrm (broken on darwin).
    # We re-add libepoxy through the overlay and --enable-opengl below.
    hostCpuTargets = [ "aarch64-softmmu" ];
    virglSupport   = true;
    openGLSupport  = false;
  }).overrideAttrs (old: {
    inherit pname;
    version = "${versionSuffix}-${builtins.substring 0 7 rev}";

    src = final.fetchFromGitHub {
      owner           = "utmapp";
      repo            = "qemu";
      inherit rev;
      hash            = srcHash;
      fetchSubmodules = true;
    };

    postPatch = ''
      ${old.postPatch or ""}
      # Git source has empty meson-subproject dirs; overlay the
      # populated ones from UTM's release tarball before meson runs.
      tmpdir=$(mktemp -d)
      ${final.gnutar}/bin/tar -xJf ${qemuSubprojectsBlob} -C "$tmpdir"
      for d in "$tmpdir"/qemu-10.0.2-utm/subprojects/*/; do
        name=$(basename "$d")
        rm -rf "subprojects/$name"
        cp -R "$d" "subprojects/$name"
      done
      rm -rf "$tmpdir"

      # nixpkgs apple-sdk_26 ships older headers without
      # HV_SYS_REG_ACTLR_EL1; substitute the literal MRS encoding.
      substituteInPlace target/arm/hvf/hvf.c \
        --replace-quiet HV_SYS_REG_ACTLR_EL1 '((hv_sys_reg_t)0xc081)'

      # Rez/SetFile (Finder icon) were removed from Xcode 14+; only
      # the codesign below them matters for HVF. Neutralise them.
      substituteInPlace scripts/entitlement.sh \
        --replace-quiet 'Rez -append' ': skip-Rez' \
        --replace-quiet 'SetFile -a C' ': skip-SetFile'
    '';

    # The UTM tree already carries the intent of the nixpkgs vendored
    # patches, so drop them. extraPatches carries the spice EGL thread fix.
    patches = extraPatches;

    buildInputs = (old.buildInputs or []) ++ [
      final.virglrenderer
      final.libepoxy
      final.angle
      final.moltenvk
    ];

    configureFlags = (old.configureFlags or []) ++ [
      "--enable-opengl"
    ];
  });
in {
  libepoxy = prev.libepoxy.overrideAttrs (old: {
    pname   = "libepoxy-utm";
    version = "macos-venus-${builtins.substring 0 7 sources.libepoxy.rev}";
    src = final.fetchFromGitHub {
      owner = "utmapp";
      repo  = "libepoxy";
      rev   = sources.libepoxy.rev;
      hash  = sources.libepoxy.hash;
    };
    # No system EGL on darwin. ANGLE supplies EGL/eglplatform.h and libEGL.
    buildInputs = (old.buildInputs or []) ++ [ final.angle ];
    mesonFlags = (lib.filter
      (f: !(lib.hasPrefix "-Dglx=" f || lib.hasPrefix "-Degl=" f
          || lib.hasPrefix "-Dtests=" f))
      (old.mesonFlags or [])) ++ [
      "-Dtests=false"
      "-Dglx=no"
      "-Degl=yes"
    ];
    # Resolve EGL and GLES to the absolute ANGLE store paths instead of
    # the Apple frameworks that only exist inside a .app bundle.
    postPatch = ''
      ${old.postPatch or ""}
      substituteInPlace src/dispatch_common.c \
        --replace-quiet 'EGL.framework/Versions/Current/EGL' \
                        '${final.angle}/lib/libEGL.dylib' \
        --replace-quiet 'GLESv1_CM.framework/Versions/Current/GLESv1_CM' \
                        '${final.angle}/lib/libGLESv1_CM.dylib' \
        --replace-quiet 'GLESv2.framework/Versions/Current/GLESv2' \
                        '${final.angle}/lib/libGLESv2.dylib'
    '';
  });

  vulkan-headers = prev.vulkan-headers.overrideAttrs (_: rec {
    version = sources.vulkanSdk.version;
    src = final.fetchFromGitHub {
      owner = "KhronosGroup";
      repo  = "Vulkan-Headers";
      rev   = "vulkan-sdk-${version}";
      hash  = sources.vulkanSdk.headersHash;
    };
  });

  vulkan-loader = prev.vulkan-loader.overrideAttrs (_: rec {
    version = sources.vulkanSdk.version;
    src = final.fetchFromGitHub {
      owner = "KhronosGroup";
      repo  = "Vulkan-Loader";
      rev   = "vulkan-sdk-${version}";
      hash  = sources.vulkanSdk.loaderHash;
    };
  });

  moltenvk = prev.moltenvk.overrideAttrs (old: {
    pname   = "moltenvk-utm";
    version = "macos-${builtins.substring 0 7 sources.moltenvk.rev}";
    src = final.fetchFromGitHub {
      owner = "utmapp";
      repo  = "MoltenVK";
      rev   = sources.moltenvk.rev;
      hash  = sources.moltenvk.hash;
    };
    # The fork pbxprojs carry various deployment targets, so the nixpkgs
    # replace of 10.15 matches nothing. Normalize to what it expects first.
    postPatch = ''
      find . -name project.pbxproj -exec sed -i \
        's/MACOSX_DEPLOYMENT_TARGET = [0-9.]*;/MACOSX_DEPLOYMENT_TARGET = 10.15;/' {} +
      ${old.postPatch or ""}
    '';
  });

  virglrenderer = prev.virglrenderer.overrideAttrs (old: {
    pname   = "virglrenderer-utm";
    version = "macos-${builtins.substring 0 7 sources.virglrenderer.rev}";
    src = final.fetchFromGitHub {
      owner = "utmapp";
      repo  = "virglrenderer";
      rev   = sources.virglrenderer.rev;
      hash  = sources.virglrenderer.hash;
    };
    buildInputs = (old.buildInputs or []) ++ [
      final.libepoxy
      final.angle
      final.moltenvk
      final.vulkan-headers
      final.vulkan-loader
    ];
    mesonFlags = (old.mesonFlags or []) ++ [
      "-Dtests=false"
      "-Dcheck-gl-errors=false"
      "-Dvenus=true"
      "-Dvulkan-dload=false"
      "-Drender-server-worker=thread"
      "-Dplatforms=egl"
    ];
  });

  # Windowed launcher (cocoa GL). Tracks the utmapp qemu macos-venus branch.
  qemu-venus = mkQemuVenus {
    pname         = "qemu-utm-venus";
    rev           = "f714f0e3370e8b4858a249ebaf6522f19b2fd97f";
    srcHash       = "sha256-6SYMl/5K4WweAAkIvoUB+DVdFpq7r+2CR1LzbDXLMDo=";
    versionSuffix = "10.0.2-utm";
  };

  # Console launcher (spice IOSurface, no NSWindow). Tracks the utmapp
  # qemu utm-edition-venus branch.
  #
  # The spice EGL context is created and bound on the main
  # thread during init, but spice_gl_refresh runs on a separate pthread,
  # where ANGLE Metal returns EGL_BAD_ACCESS for an eglMakeCurrent on a
  # context that is still current elsewhere. The patch releases the context
  # on the main thread so the worker can claim it.
  qemu-venus-spice = mkQemuVenus {
    pname         = "qemu-utm-venus-spice";
    rev           = "9f81c6232fbb3ea1d9e43cb67fe5e029723d2ed5";
    srcHash       = "sha256-pRyx6v1Ult0XptyLXh4sgCGnC5EM3HGhotsyI9W0bMo=";
    versionSuffix = "10.0.2-utm-edition";
    extraPatches  = [ ./spice-thread-fix.patch ];
  };
}
