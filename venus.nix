# Venus GPU passthrough. An aarch64-linux NixOS guest with Venus to Metal
# on aarch64-darwin, built from the UTM macOS Venus tree.
#
# This replaces qemu-vm.nix and vmVariant (which are Linux host only). The
# launcher is a darwin writeShellApplication wrapping the UTM fork qemu.
# The guest filesystem and init bits live in ./guest.nix.
# Guest derivations (kernel and initrd) need a linux builder.

{ nixpkgs
# Host packages override srcs with UTM forks, so they pin their own
# nixpkgs. The guest tracks nixpkgs.
, hostNixpkgs ? nixpkgs
, hostSystem ? "aarch64-darwin"
, guestSystem ? "aarch64-linux"
, lib ? nixpkgs.lib
# An externally built nixosSystem to boot as the guest (mahmooz1 extended
# with the venus guest module, for example). When null, build the stub
# guest in ./guest.nix.
, customGuest ? null
# Absolute path on the host to share into the guest at /data over 9p.
# When null, /data is left unmounted.
, hostVoldir ? null
# Default network backend. Either "user" (slirp NAT, unprivileged), "vmnet"
# (Apple vmnet shared NAT, needs root) or "none". Overridable per run
# with VENUS_NET without rebuilding the launcher.
, defaultNetwork ? "user"
# Host side port forwarded to the guest sshd under the "user" backend.
, sshHostPort ? 2222
# Null packs the store image uncompressed (around 2.5x the size, with no
# per read decompression). A string goes to sqfstar -comp, for example
# "zstd -Xcompression-level 3".
, storeImageCompression ? null
}:

let
  sources = import ./sources.nix;

  hostOverlay = import ./host-overlay.nix { inherit sources lib; };

  hostPkgs = import hostNixpkgs {
    system   = hostSystem;
    overlays = [ hostOverlay ];
    config.allowUnfree = true;
  };

  nixosGuest =
    if customGuest != null then customGuest
    else nixpkgs.lib.nixosSystem {
      system = guestSystem;
      modules = [
        (import ./guest.nix)
        ({ ... }: { venus.guest.enable = true; })
      ];
    };

  # Build guest-side derivations with the guest pkgs so they inherit its nixpkgs config.
  guestPkgs      = nixosGuest.pkgs;
  guestKernel    = nixosGuest.config.system.build.kernel;
  # kernelFile is the NixOS image name (aarch64 gives "Image").
  guestKernelImg = "${guestKernel}/${nixosGuest.config.system.boot.loader.kernelFile}";
  guestInitrd    = nixosGuest.config.system.build.initialRamdisk;
  guestToplevel  = nixosGuest.config.system.build.toplevel;

  # regInfo rides the kernel cmdline; kept at the launcher layer because
  # referencing it from the guest kernelParams would cycle through toplevel.
  guestClosureInfo = guestPkgs.closureInfo { rootPaths = [ guestToplevel ]; };

  # regInfo included so register-nix-paths can read it off the image.
  guestStorePaths = guestPkgs.closureInfo {
    rootPaths = [ guestToplevel guestClosureInfo ];
  };

  # Like qemu-vm.nix useNixStoreImage, but stripping the ~nix~case~hack~
  # infix for case insensitive host volumes, and packed with sqfstar (plain
  # mkfs.erofs ignores -z in --tar=f mode). A 9p shared store instead wedges
  # virtio under GL rendering.
  mkStoreImage = ''
    ${hostPkgs.gnutar}/bin/tar --create \
      --absolute-names \
      --verbatim-files-from \
      --transform 'flags=rSh;s|/nix/store/||' \
      --transform 'flags=rSh;s|~nix~case~hack~[[:digit:]]\+||g' \
      --files-from ${guestStorePaths}/store-paths \
      | ${hostPkgs.squashfsTools}/bin/sqfstar \
        -quiet -no-progress -all-root -b 1048576 \
        ${if storeImageCompression == null
          then "-no-compression"
          else "-comp ${storeImageCompression}"} \
        "$STORE_IMG.tmp"
  '';

  storeImageStamp = "${guestStorePaths} comp=${
    if storeImageCompression == null then "none" else storeImageCompression
  }";

  # /nix/store rides on the store image above, so this seed only holds
  # /etc, /var, /home and friends.
  guestImage = guestPkgs.runCommand "venus-guest-scratch" {
    nativeBuildInputs = [ guestPkgs.qemu-utils guestPkgs.e2fsprogs ];
  } ''
    mkdir -p "$out"
    truncate -s 1G raw.img
    mkfs.ext4 -F -L nixos -U random raw.img
    qemu-img convert -f raw -O qcow2 raw.img "$out/nixos.qcow2"
  '';

  # Binary name derives from the wrapped guest hostname. mahmooz1 becomes
  # run-mahmooz1-vm (matches the convention NixOS uses for system.build.vm,
  # so this drops in as a replacement).
  launcherBaseName = "run-${nixosGuest.config.networking.hostName}-vm";

  # launcher holds the foreground Cocoa window (cocoa GL qemu).
  # launcher-console holds the serial console on the calling terminal with
  # no NSWindow (spice IOSurface qemu). Ctrl-A X quits.
  mkLauncher = {
    name,
    qemu        ? hostPkgs.qemu-venus,
    consoleMode ? false,
  }: hostPkgs.writeShellApplication {
    inherit name;
    runtimeInputs = [ qemu hostPkgs.coreutils ];
    # gl=es args fool shellcheck into seeing comma array separators.
    excludeShellChecks = [ "SC2054" ];
    text = ''
      set -euo pipefail
      # VENUS_STATE_DIR gives a run its own disk/socket.
      CACHE="''${VENUS_STATE_DIR:-''${XDG_CACHE_HOME:-$HOME/.cache}/venus-guest}"
      mkdir -p "$CACHE"
      # One launcher per CACHE; packing is rm/mv and does not interleave.
      # Remove the dir by hand if a launcher is SIGKILLed.
      LOCKDIR="$CACHE/.launcher.lock"
      if ! mkdir "$LOCKDIR" 2>/dev/null; then
        echo "venus-guest: $CACHE is owned by another launcher (rmdir $LOCKDIR if stale)" >&2
        exit 1
      fi
      trap 'rmdir "$LOCKDIR"' EXIT
      DISK="$CACHE/disk.qcow2"

      if [ ! -f "$DISK" ]; then
        echo "venus-guest: materialising writeable disk at $DISK"
        install -m 0644 "${guestImage}/nixos.qcow2" "$DISK"
        chmod u+w "$DISK"
        qemu-img resize "$DISK" 32G
      fi

      STORE_IMG="$CACHE/store.img"
      if [ "$(cat "$STORE_IMG.stamp" 2>/dev/null)" != "${storeImageStamp}" ]; then
        echo "venus-guest: packing nix store image (several minutes on a first run)"
        rm -f "$STORE_IMG" "$STORE_IMG.stamp" "$STORE_IMG.tmp"
        ${mkStoreImage}
        mv "$STORE_IMG.tmp" "$STORE_IMG"
        echo "${storeImageStamp}" > "$STORE_IMG.stamp"
      fi

      # MoltenVK ICD for virglrenderer's Vulkan loader; ANGLE on Metal
      # for IOSurface interop; DYLD_FALLBACK catches indirect dlopens
      # of ANGLE/MoltenVK by leaf name.
      export VK_DRIVER_FILES="${hostPkgs.moltenvk}/share/vulkan/icd.d/MoltenVK_icd.json"
      export VK_ICD_FILENAMES="$VK_DRIVER_FILES"
      export ANGLE_DEFAULT_PLATFORM=metal
      export DYLD_FALLBACK_LIBRARY_PATH="${hostPkgs.moltenvk}/lib:${hostPkgs.angle}/lib:''${DYLD_FALLBACK_LIBRARY_PATH:-/usr/local/lib:/usr/lib}"

      ${lib.optionalString consoleMode ''
        SPICE_SOCK="$CACHE/qemu.sock"
        rm -f "$SPICE_SOCK"
      ''}

      # VENUS_NET picks the backend per run, no rebuild needed:
      #   user  - slirp NAT, ssh on localhost:${toString sshHostPort}, unprivileged
      #   vmnet - Apple vmnet shared NAT, guest gets its own IP, needs root
      #   none  - no NIC at all
      NET="''${VENUS_NET:-${defaultNetwork}}"
      case "$NET" in
        user)
          NET_ARGS=(
            -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${toString sshHostPort}-:22"
            -device virtio-net-pci,netdev=net0
          )
          ;;
        vmnet)
          if [ "$(id -u)" -ne 0 ]; then
            echo "venus-guest: VENUS_NET=vmnet needs root (vmnet has no unprivileged path); re-run under sudo." >&2
            exit 1
          fi
          NET_ARGS=(
            -netdev vmnet-shared,id=net0
            -device virtio-net-pci,netdev=net0
          )
          ;;
        none)
          # Omitting -netdev entirely still gets a default slirp nic.
          NET_ARGS=( -nic none )
          ;;
        *)
          echo "venus-guest: unknown VENUS_NET=$NET (want user|vmnet|none)" >&2
          exit 1
          ;;
      esac

      QEMU_ARGS=(
        -name venus-guest
        -machine virt,gic-version=max,accel=hvf
        -cpu host -smp 4 -m 8G
        -kernel ${guestKernelImg}
        -initrd ${guestInitrd}/initrd
        -append "console=ttyAMA0,115200 root=/dev/vda init=${guestToplevel}/init regInfo=${guestClosureInfo}/registration loglevel=4"
        # Keeps block I/O off the main loop, which also serves 9p and net.
        -object iothread,id=iothread0
        -blockdev driver=file,node-name=disk-file,filename="$DISK"
        -blockdev driver=qcow2,node-name=disk,file=disk-file
        -device virtio-blk-pci,drive=disk,iothread=iothread0
        # must stay after the root disk above so the guest sees it as vdb.
        -blockdev driver=file,node-name=store-file,filename="$STORE_IMG",read-only=on
        -blockdev driver=raw,node-name=store,file=store-file,read-only=on
        -device virtio-blk-pci,drive=store
        ${lib.optionalString (hostVoldir != null)
          "-virtfs local,path=${hostVoldir},security_model=none,mount_tag=host-data"}
        ${if consoleMode
          then ''-spice unix=on,addr="$SPICE_SOCK",disable-ticketing=on,gl=es''
          else ''-display cocoa,gl=es,zoom-to-fit=on,swap-opt-cmd=on''}
        -device virtio-gpu-gl-pci,hostmem=8G,blob=true,venus=true
        -device virtio-keyboard-pci
        -device virtio-tablet-pci
        "''${NET_ARGS[@]}"
        # Cocoa shows only the GPU framebuffer; keep the kernel log in a file.
        ${if consoleMode
          then ''-serial mon:stdio''
          else ''-serial file:"''$CACHE/serial.log"''}
      )

      ${lib.optionalString consoleMode ''
        echo "venus-guest: serial console attached.  Ctrl-A X to quit, Ctrl-A C for monitor."
      ''}
      # exec replaces the shell, so drop the lock here or it leaks.
      rmdir "$LOCKDIR"; trap - EXIT
      exec qemu-system-aarch64 "''${QEMU_ARGS[@]}" "$@"
    '';
  };

  launcher = mkLauncher {
    name = launcherBaseName;
  };
  launcherConsole = mkLauncher {
    name        = "${launcherBaseName}-console";
    qemu        = hostPkgs.qemu-venus-spice;
    consoleMode = true;
  };

in {
  inherit hostPkgs nixosGuest;
  inherit guestImage guestKernel guestKernelImg guestInitrd guestToplevel;

  launchers = {
    launcher         = launcher;
    launcher-console = launcherConsole;
  };

  qemu-venus       = hostPkgs.qemu-venus;
  qemu-venus-spice = hostPkgs.qemu-venus-spice;
  virglrenderer    = hostPkgs.virglrenderer;
  libepoxy         = hostPkgs.libepoxy;
  moltenvk         = hostPkgs.moltenvk;
  vulkan-loader    = hostPkgs.vulkan-loader;
}
