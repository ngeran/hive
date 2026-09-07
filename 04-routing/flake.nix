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

        # jsnapy 1.3.8 pins icdiff==1.9.1 and imports get_options() from it —
        # an API that the 2.x line (what nixpkgs ships) removed. Ship the
        # exact version it was written against.
        icdiff191 = pkgs.python313Packages.buildPythonPackage rec {
          pname = "icdiff";
          version = "1.9.1";
          src = pkgs.fetchPypi {
            inherit pname version;
            hash = "sha256-Zpct0DMY2lUoCZHbN10+9rZtlIxnr5bB69shWH6GZV4=";
          };
          pyproject = true;
          build-system = with pkgs.python313Packages; [ setuptools ];
          doCheck = false;
        };

        # JSNAPy (Junos Snapshot Administrator in Python) is NOT packaged in
        # nixpkgs — build it from PyPI here. Everything it needs IS in
        # nixpkgs, including PyEZ (junos-eznc), which 01-workspace already
        # ships. Verified live against the phase-4 fabric (2026-09-06).
        #
        # Must be python313Packages (3.13), NOT python311Packages:
        # nixpkgs' python311 junos-eznc pulls sphinx 9.x, which refuses
        # interpreters < 3.12 and breaks evaluation outright.
        jsnapy = pkgs.python313Packages.buildPythonPackage rec {
          pname = "jsnapy";
          version = "1.3.8";
          src = pkgs.fetchPypi {
            inherit pname version;
            hash = "sha256-saTG8EivSwSP+ENUHalDhDIIdrgLCouXyZ+wC4YU5X0=";
          };
          # sdist predates pyproject.toml; build via the legacy setuptools path
          pyproject = true;
          build-system = with pkgs.python313Packages; [ setuptools ];
          doCheck = false; # upstream tests need nose — dead project, skip
          pythonRemoveDeps = [ "future" ]; # declared but never imported
          # setup.py installs default configs to /etc/jsnapy via data_files
          # plus a custom install cmdclass that pokes at that path — both
          # impossible in the sandbox and useless here: the wheel ships the
          # same files as package_data (jnpr/jsnapy/), which is what
          # `just verify` seeds ~/.jsnapy from.
          postPatch = ''
            substituteInPlace setup.py \
              --replace-fail 'data_files=os_data_file' 'data_files=[]' \
              --replace-fail 'cmdclass={"install": OverrideInstall},' 'cmdclass={},'
          '';
          propagatedBuildInputs = with pkgs.python313Packages; [
            junos-eznc
            colorama
            configparser
            pyparsing
            icdiff191
            lxml
            # upstream also lists `future` in install_requires, but nothing
            # imports it — and nixpkgs gates `future` off on python ≥ 3.13
          ];
        };

        # DevShell Python: PyEZ + JSNAPy, with the `jsnapy` CLI on PATH.
        pyTools = pkgs.python313.withPackages (ps: [ ps.junos-eznc jsnapy ]);
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
          buildInputs = with pkgs; [
            just kubectl skopeo kubernetes-helm jq pyTools
          ];
        };
      });
}
