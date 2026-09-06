{
  description = "clabernetes + cRPD MPLS topology — Phase 4 of the HIVE lab";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        # `nix develop` / `direnv allow` here gets the tools this phase needs on
        # your NixOS host — most importantly `helm`, the one base-system tool
        # that's missing, because clabernetes ships as a Helm OCI chart.
        #
        # No image is *built* in this phase (unlike 01-workspace): the cRPD image
        # is already pushed to localhost:5000, and the clabernetes operator +
        # launcher images are pulled from ghcr.io at install time.
        devShells.default = pkgs.mkShell {
          # NOTE: the Kubernetes Helm CLI is `kubernetes-helm` in nixpkgs, NOT
          # `helm` (which is an unrelated Haskell package). clabernetes ships as
          # a Helm OCI chart, so this is the one base-system tool this phase adds.
          buildInputs = with pkgs; [ just kubectl skopeo kubernetes-helm jq ];
        };
      });
}
