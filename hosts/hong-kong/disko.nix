# hosts/hong-kong/disko.nix — declarative partitioning.
#
# The device below is a placeholder: `disko-install --disk main /dev/nvme0n1`
# overrides it at install time, which is why the same layout works on both
# machines regardless of what the disk is called.
#
# THIS DESTROYS THE TARGET DISK. hong-kong's NVMe currently holds an old Linux
# install (237.5 GB partition + swap). Confirm you want none of it.
{ lib, ... }:

{
  disko.devices.disk.main = {
    type = "disk";
    device = lib.mkDefault "/dev/nvme0n1";
    content = {
      type = "gpt";
      partitions = {
        # 1 GB rather than the usual 512 MB: each NixOS generation keeps a
        # kernel and initrd here, and a full ESP breaks the bootloader
        # install, which breaks gate 3. Cheap insurance on a 238 GB disk.
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
