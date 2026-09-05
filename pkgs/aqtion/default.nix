# Marvell (Aquantia) out-of-tree "AQtion" driver -- the vendor version of the
# in-kernel `atlantic` module.
#
# Why: on AQC113CS the mainline driver wedges the NIC firmware every few hours
# ("atlantic: Boot code hanged", hw_atl2_utils_fw.c, aq_a2_fw_deinit) and the
# link never renegotiates; the vendor driver does not.
# See https://github.com/Aquantia/AQtion/issues/49.
#
# Source: Aquantia/AQtion master stopped at v2.5.5 (2022, kernels <= 5.19).
# FlorianFranzen/atlantic carries the later vendor drops verbatim; v2.5.16
# (tag on 97b6229, CHANGELOG dated 2026-01-27) is the newest and is the first
# release that claims >= 6.6 / 6.15 kernel API support. It builds against 6.19
# unpatched.
{
  pkgs,
  kernel ? pkgs.linuxPackages.kernel,
}:

pkgs.stdenv.mkDerivation {
  pname = "aqtion";
  version = "2.5.16-${kernel.version}";

  src = pkgs.fetchFromGitHub {
    owner = "FlorianFranzen";
    repo = "atlantic";
    rev = "97b6229c66f4ce5d90f9afccd46425793059ca25"; # tag v2.5.16
    hash = "sha256-Fnd3JPvIHAellV0yntRt8TZuPEJSDFVWWbx5p0RP4Nw=";
  };

  nativeBuildInputs = [ pkgs.nukeReferences ] ++ kernel.moduleBuildDependencies;

  hardeningDisable = [
    "pic"
    "format"
  ];

  # The upstream Makefile's `all` target recurses into KDIR itself, but leans
  # on /lib/modules/$(uname -r) unless KDIR is set; invoke kbuild directly
  # instead. KERNELRELEASE must not be set for the top-level Makefile (it
  # switches to the in-kbuild include path), only for the recursive call.
  buildPhase = ''
    runHook preBuild
    make -j$NIX_BUILD_CORES \
      -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
      M=$PWD ARCH=${pkgs.stdenv.hostPlatform.linuxArch} \
      KERNELRELEASE=${kernel.modDirVersion} modules
    runHook postBuild
  '';

  # `extra/` is ahead of `kernel/` in depmod's default search order, so this
  # atlantic.ko shadows the in-tree one without blacklisting the module name.
  installPhase = ''
    runHook preInstall
    install -D -m 0444 atlantic.ko \
      $out/lib/modules/${kernel.modDirVersion}/extra/atlantic.ko
    nuke-refs $out/lib/modules/${kernel.modDirVersion}/extra/atlantic.ko
    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "Marvell AQtion (atlantic) out-of-tree NIC driver";
    homepage = "https://github.com/Aquantia/AQtion";
    license = licenses.gpl2Only;
    platforms = platforms.linux;
  };
}
