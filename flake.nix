{
  description = "Home CI lab NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs =
    { nixpkgs, ... }:
    {
      nixosConfigurations.beelink = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./machines/beelink/hardware-configuration.nix
          (
            { pkgs, ... }:
            {
              boot.loader.systemd-boot.enable = true;
              boot.loader.efi.canTouchEfiVariables = true;

              networking.hostName = "beelink";
              networking.networkmanager.enable = true;

              time.timeZone = "Europe/London";
              i18n.defaultLocale = "en_GB.UTF-8";

              services.openssh.enable = true;

              users.users.root.openssh.authorizedKeys.keys = [
                "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH988C5DbEPHfoCphoW23MWq9M6fmA4UTXREiZU0J7n0 will.hetzner@temp.com"
              ];

              users.users.will = {
                isNormalUser = true;
                extraGroups = [
                  "networkmanager"
                  "wheel"
                ];
                openssh.authorizedKeys.keys = [
                  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH988C5DbEPHfoCphoW23MWq9M6fmA4UTXREiZU0J7n0 will.hetzner@temp.com"
                ];
              };

              security.sudo.wheelNeedsPassword = false;

              nix.settings = {
                experimental-features = [
                  "nix-command"
                  "flakes"
                ];
                trusted-users = [
                  "root"
                  "will"
                ];
              };

              hardware.enableRedistributableFirmware = true;

              environment.systemPackages = with pkgs; [
                git
                vim
              ];

              system.stateVersion = "25.11";
            }
          )
        ];
      };
    };
}
