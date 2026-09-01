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
    # Consumed by hosts/hong-kong/secrets.nix, not by modules/phase3.nix, which
    # remains only a sketch. flake.lock MUST be regenerated and committed
    # alongside any change here, or comin cannot deploy at all (rule 1) — and
    # there is no nix on the MacBook, so `nix flake lock` runs on hong-kong.
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
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

          # ---- PHASE 5: monitoring ----
          # On the spine, not on a host, so a machine is observable the moment
          # it exists — architecture.md:203 lists exporters as part of
          # shanghai's duty too. It opens a metrics port on the tailnet
          # interface and nothing else: no secret, no mount, no boot-time
          # dependency. The things that SCRAPE it are hong-kong's alone, in
          # hosts/hong-kong/metrics.nix.
          ./modules/observability-node.nix

          inputs.comin.nixosModules.comin
          ./modules/comin.nix

          # ---- PHASE 3b ----
          # Inert until a host declares sops.secrets: sops-nix's own config is
          # `mkIf (cfg.secrets != {})`, so importing this leaves shanghai — which
          # has no secrets file and must not move — building exactly as before.
          #
          # Only hong-kong declares any, in hosts/hong-kong/secrets.nix.
          # modules/phase3.nix stays out: its comin block describes an older
          # ssh-deploy-key design that conflicts with the live modules/comin.nix.
          inputs.sops-nix.nixosModules.sops

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
