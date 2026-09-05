{
  description = "Venus GPU passthrough VM. virtio-gpu Venus to Metal on Apple Silicon";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/master";
    # host packages override upstream srcs with UTM forks and so inherit
    # version coupled recipes, hence their own pin. the guest tracks nixpkgs.
    nixpkgs-venus.url = "github:NixOS/nixpkgs/cd648d6ea62bc0ffba91e61fcfe5e33c1e2004b1";
  };

  outputs = { self, nixpkgs, ... }: let
    sources = import ./sources.nix;
  in {
    nixosModules.venus-guest = import ./guest.nix;
    nixosModules.default = self.nixosModules.venus-guest;

    overlays.venus-host = import ./host-overlay.nix { inherit sources; lib = nixpkgs.lib; };
    overlays.default = self.overlays.venus-host;

    lib.mkVenus = import ./venus.nix;
  };
}
