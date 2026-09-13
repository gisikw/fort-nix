{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-forgejo.url = "github:NixOS/nixpkgs/nixos-25.11";
    disko.url = "github:nix-community/disko";
    impermanence.url = "github:nix-community/impermanence";
    nixos-anywhere.url = "github:nix-community/nixos-anywhere";
    deploy-rs.url = "github:serokell/deploy-rs";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-darwin = {
      url = "github:LnL7/nix-darwin/nix-darwin-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-anywhere,
      deploy-rs,
      ...
    }:
    {
      packages = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-darwin" ] (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          engramHaloSrc = pkgs.fetchFromGitHub {
            owner = "Aristo94";
            repo = "EngramHalo.cpp";
            rev = "15176583b358d791b7a73f210ef4ab9e167cfba7";
            hash = "sha256-vV6OYo8j6JeJn7c4ICCAmnDDkrqfhFv2F/4olW24k/g=";
          };
        in
        {
          nixos-anywhere = nixos-anywhere.packages.${system}.default;
          nixfmt = pkgs.nixfmt-rfc-style;
          deploy-rs = pkgs.deploy-rs;
          # Source/provenance check only. The ROCm 10 binary package lives at
          # pkgs/llama-cpp-engramhalo and intentionally needs a future pinned
          # ROCm 10 overlay; this flake's ROCm 6.4.3 is rejected by that package.
          engramhalo-source-check = pkgs.runCommand "engramhalo-source-check" { } ''
            test -f ${engramHaloSrc}/LICENSE
            test ! -s ${engramHaloSrc}/.gitmodules
            grep -q 'GGML_HIP_GDN_CHUNK' ${engramHaloSrc}/ggml/src/ggml-cuda/gated_delta_net.cu
            grep -q 'LLAMA_QSA_GATHER' ${engramHaloSrc}/src/models/qwen4exp.cpp
            grep -q 'prefetch_rows' ${engramHaloSrc}/src/llama-mmap.cpp
            mkdir -p $out
            printf '%s\n' 15176583b358d791b7a73f210ef4ab9e167cfba7 > $out/revision
          '';
        }
      );
    };
}
