# Guest side NixOS profile for the Venus VM.
#
# qemu-vm.nix is Linux host only and tightly coupled to the vmVariant
# runner, so we lift only the patterns we need. Overlayfs /nix/store on a
# 9p read only lower plus tmpfs upper, ext4 scratch root with autoResize,
# /tmp on tmpfs, legacy initrd, aarch64 ttyAMA0 console, regInfo driven nix
# db registration. See ./venus.nix for the launcher.

{ config, lib, pkgs, modulesPath, ... }:

let
  inherit (lib) mkEnableOption mkOption mkIf mkForce mkDefault types;

  cfg = config.venus.guest;

  guestOverlay = final: prev: {
    # Mesa with the osy 16 KiB blob alignment patch (guest 4K against host
    # 16K Apple Silicon page size), rebased onto current mesa. Obsolete once
    # F_BLOB_ALIGNMENT lands.
    mesa = prev.mesa.overrideAttrs (old: {
      patches = (old.patches or []) ++ [ ./mesa-venus-16k-blob-align.patch ];
    });

    # Compute-only Vulkan benchmark; real hardware reports TFLOPS, llvmpipe MFLOPS.
    vkpeak = prev.stdenv.mkDerivation {
      pname = "vkpeak";
      version = "20260112";
      src = final.fetchFromGitHub {
        owner = "nihui";
        repo  = "vkpeak";
        rev   = "1c5c383c79cb0ff2485ac453f3ddd25535f41ca5";
        hash  = "sha256-PoZ6p0XGt5NZ5sH/171IKK5n8lYHSqYfox36QPWLIvw=";
        fetchSubmodules = true;
      };
      nativeBuildInputs = [ final.cmake ];
      buildInputs       = [ final.vulkan-loader final.vulkan-headers ];
      installPhase = ''
        runHook preInstall
        install -Dm755 vkpeak "$out/bin/vkpeak"
        runHook postInstall
      '';
    };
  };
in {
  imports = [
    "${modulesPath}/profiles/qemu-guest.nix"
    "${modulesPath}/profiles/minimal.nix"
  ];

  options.venus.guest = {
    enable = mkEnableOption "Venus (virtio-gpu) GPU-passthrough guest profile";

    rootInitialPassword = mkOption {
      type        = types.str;
      default     = "venus";
      description = "Initial root password for the Venus guest (change after first boot).";
    };

    hostName = mkOption {
      type        = types.str;
      default     = "venus-guest";
      description = "Guest hostname.";
    };

    stateVersion = mkOption {
      type        = types.str;
      default     = "25.05";
      description = "system.stateVersion for the Venus guest.";
    };
  };

  config = mkIf cfg.enable {
    nixpkgs.overlays = [ guestOverlay ];

    # Legacy initrd. systemd in initrd plus make-disk-image emit a
    # duplicate sysroot.mount and drop to emergency mode. Bootloaders stay
    # off since the launcher boots through qemu -kernel and -initrd directly.
    boot.loader.grub.enable         = mkForce false;
    boot.loader.systemd-boot.enable = mkForce false;
    boot.initrd.systemd.enable      = false;
    boot.initrd.availableKernelModules = [
      "virtio_pci" "virtio_blk" "virtio_net" "virtio_gpu"
      "drm" "drm_kms_helper"
      # 9p (for the /data share) is built into the aarch64 kernel. Do not
      # add fscache or netfs (unpackaged, breaks modprobe -S).
      "9p" "9pnet" "9pnet_virtio"
      "squashfs"
      "overlay"
    ];
    boot.kernelModules = [ "virtio_gpu" ];
    # aarch64 virt is ttyAMA0 (the qemu-guest.nix ttyS0 default is x86).
    boot.kernelParams = mkForce [ "console=ttyAMA0,115200" "console=tty0" ];

    # mkForce overrides the parent hardware-configuration.nix.
    fileSystems."/" = mkForce {
      device     = "/dev/disk/by-label/nixos";
      fsType     = "ext4";
      autoResize = true;
    };

    fileSystems."/tmp" = {
      device  = "tmpfs";
      fsType  = "tmpfs";
      options = [ "mode=1777" ];
    };

    # Host voldir shared as 9p. mkForce because disko declares /data as
    # btrfs; host UIDs pass through, so write as root. nofail keeps boot
    # working without the matching -virtfs.
    fileSystems."/data" = mkForce {
      device  = "host-data";
      fsType  = "9p";
      options = [ "trans=virtio" "version=9p2000.L" "msize=1048576" "rw" "nofail" ];
    };

    # Link host data into the guest home.
    systemd.tmpfiles.rules = [
      "L+ /home/${config.machine.user}/work - - - - /data/work"
      "L+ /home/${config.machine.user}/brain - - - - /data/brain"
    ];

    # Overlayfs over the squashfs lower: nix-daemon dies on a read only
    # store. Upper is tmpfs, so new store paths are lost on reboot.
    # neededForBoot because init lives under /nix/store.
    fileSystems."/nix/.ro-store" = mkForce {
      device        = "/dev/vdb";
      fsType        = "squashfs";
      options       = [ "ro" ];
      neededForBoot = true;
    };
    fileSystems."/nix/.rw-store" = {
      fsType        = "tmpfs";
      options       = [ "mode=0755" ];
      neededForBoot = true;
    };
    fileSystems."/nix/store" = mkForce {
      overlay = {
        lowerdir = [ "/nix/.ro-store" ];
        upperdir = "/nix/.rw-store/upper";
        workdir  = "/nix/.rw-store/work";
      };
      neededForBoot = true;
    };

    # Lifted from qemu-vm.nix. Loads the regInfo file (passed on the kernel
    # cmdline by the launcher) into the local nix db before nix-daemon
    # starts, so realise resolves closure paths locally instead of falling
    # back to substituters.
    # NIX_REMOTE=local: lix --load-db needs a LocalStore, the wrapper default (daemon) fails.
    systemd.services.register-nix-paths = {
      description = "Load regInfo into nix store db";
      unitConfig.DefaultDependencies = false;
      wantedBy   = [ "sysinit.target" ];
      before     = [ "sysinit.target" "shutdown.target"
                     "nix-daemon.socket" "nix-daemon.service" ];
      after      = [ "local-fs.target" ];
      environment.NIX_REMOTE = "local";
      conflicts  = [ "shutdown.target" ];
      restartIfChanged = false;
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        if [[ "$(cat /proc/cmdline)" =~ regInfo=([^ ]*) ]]; then
          ${lib.getExe' config.nix.package.out "nix-store"} --load-db < "''${BASH_REMATCH[1]}"
        fi
      '';
    };

    # regInfo covers the boot closure locally. The short connect timeout
    # keeps nix failing fast under VENUS_NET=none.
    nix.settings.connect-timeout = lib.mkDefault 5;

    services.openssh.enable = true;
    services.openssh.settings.PermitRootLogin = "yes";
    users.users.root.initialPassword = cfg.rootInitialPassword;

    hardware.graphics.enable = true;

    # Hyprland never rescans outputs, so poll the drm modes and set each
    # explicitly (an explicit WxH@rate is the only thing it follows).
    systemd.user.services.venus-follow-host-resize =
      mkIf config.programs.hyprland.enable {
        description = "match the wayland output to the qemu window size";
        wantedBy      = [ "graphical-session.target" ];
        partOf        = [ "graphical-session.target" ];
        after         = [ "graphical-session.target" ];
        serviceConfig.Restart = "always";
        script = ''
          prev=
          while :; do
            for dir in /sys/class/drm/card*-Virtual-*; do
              [ -r "$dir/modes" ] || continue
              mode=$(head -1 "$dir/modes")
              name=''${dir##*/}; name=''${name#card*-}
              if [ -n "$mode" ] && [ "$name=$mode" != "$prev" ]; then
                ${config.programs.hyprland.package}/bin/hyprctl eval \
                  "hl.monitor({ output = \"$name\", mode = \"$mode@60\", position = \"auto\", scale = \"auto\" })" > /dev/null \
                  && prev="$name=$mode"
              fi
            done
            sleep 2
          done
        '';
      };

    # Pin the venus ICD so the loader skips probing other drivers.
    environment.sessionVariables.VK_DRIVER_FILES =
      "/run/opengl-driver/share/vulkan/icd.d/virtio_icd.aarch64.json";
    environment.sessionVariables.VK_ICD_FILENAMES =
      "/run/opengl-driver/share/vulkan/icd.d/virtio_icd.aarch64.json";

    environment.systemPackages = with pkgs; [
      vulkan-tools
      vulkan-loader
      vulkan-validation-layers
      mesa-demos
      glmark2
      vkmark
      vkpeak
      kmscube
      weston
    ];

    # mkDefault so the parent config wins.
    networking.hostName        = mkDefault cfg.hostName;
    networking.firewall.enable = mkDefault false;

    system.stateVersion = mkDefault cfg.stateVersion;
  };
}
