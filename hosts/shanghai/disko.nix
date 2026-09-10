# hosts/shanghai/disko.nix — declarative partitioning.
#
# The device below is REAL, not a placeholder. The two-step install
# (`disko --mode destroy,format,mount` then `nixos-install`) uses exactly
# this path — there is no `--disk` override in that path.
#
# By-id, not /dev/sdX: this box has no NVMe. Both M.2 slots are empty and the
# only disk is SATA, so the installer USB and the target enumerate in the
# same namespace and /dev/sda is not stable between boots.
#
# THIS DESTROYS THE TARGET DISK.
{ lib, ... }:

{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/disk/by-id/ata-KINGSTON_SA400S37120G_50026B7380C6D368";
    content = {
      type = "gpt";
      partitions = {
        # 1 GB rather than the usual 512 MB: each NixOS generation keeps a
        # kernel and initrd here, and a full ESP breaks the bootloader
        # install, which breaks gate 3. Cheap insurance on a 112 GB disk.
        ESP = {
          priority = 1;
          name = "ESP";
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };

        swap = {
          priority = 2;
          size = "8G";
          content = {
            type = "swap";
            discardPolicy = "both";
          };
        };

        root = {
          priority = 3;
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
