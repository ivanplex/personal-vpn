{
  description = "personal-vpn — declarative fleet (hong-kong, shanghai)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    # ---- PHASE 3 ----------------------------------------------------------
    # Uncomment these together with the matching imports in modules/phase3.nix
    # and the module list below. Not before: sops needs a host key that does
    # not exist until the machine has been installed once.
    #
    # sops-nix.url = "github:Mic92/sops-nix";
    # sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    #
    # comin.url = "github:nlewo/comin";
    # comin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, disko, ... }@inputs:
    let
      system = "x86_64-linux";

      # Every host gets the same spine. Anything host-specific lives in
      # hosts/<name>/default.nix.
      mkHost = name: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          disko.nixosModules.disko

          ./modules/base.nix
          ./modules/tailscale-node.nix
          ./modules/boot-verdict.nix      # gates 3 and 4

          # ---- PHASE 3 ----
          # inputs.sops-nix.nixosModules.sops
          # inputs.comin.nixosModules.comin
          # ./modules/phase3.nix

          (./hosts + "/${name}")
        ];
      };
    in
    {
      nixosConfigurations = {
        hong-kong = mkHost "hong-kong";
        shanghai  = mkHost "shanghai";
      };

      # Convenience: `nix flake check` builds both.
      checks.${system} = {
        hong-kong = self.nixosConfigurations.hong-kong.config.system.build.toplevel;
        shanghai  = self.nixosConfigurations.shanghai.config.system.build.toplevel;
      };
    };
}
