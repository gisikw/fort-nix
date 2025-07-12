{ config, lib, pkgs, ... }:

{
  environment.systemPackages = [ pkgs.neofetch ];
}
