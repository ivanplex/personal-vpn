{
  description = "personal-vpn — declarative fleet (hong-kong, shanghai)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    # GitOps agent. Neither the package nor the module is in nixpkgs 26.05,
    # so it has to come from its own flake.
    comin.url = "github:nlewo/comin";
    comin.inputs.nixpkgs.follows = "nixpkgs";

    # ---- PHASE 3b ---------------------------------------------------------
    # Uncomment with the matching imports in modules/phase3.nix. Not before:
    # sops needs a host key that does not exist until a machine has been
    # installed once.
    #
    # sops-nix.url = "github:Mic92/sops-nix";
    # sops-nix.inputs.nixpkgs.follows = "nixpkgs";
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

          inputs.comin.nixosModules.comin
          ./modules/comin.nix

          # ---- PHASE 3b ----
          # inputs.sops-nix.nixosModules.sops
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
