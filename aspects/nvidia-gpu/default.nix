{ ... }:
{ config, ... }:
{
  # Load NVIDIA proprietary driver (kernel modules + userspace)
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    # Open kernel modules required for Blackwell architecture (RTX 50-series)
    open = true;
    modesetting.enable = true;
    package = config.boot.kernelPackages.nvidiaPackages.beta;
  };

  hardware.graphics.enable = true;

  # CDI specs for podman container GPU passthrough
  hardware.nvidia-container-toolkit.enable = true;
}
