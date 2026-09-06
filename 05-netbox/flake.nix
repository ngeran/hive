# =========================================================================
# HIVE Phase 05 — NetBox (Final Hardened Production Version)
# =========================================================================
{
  description = "HIVE NetBox — IPAM/DCIM Service";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-24.11"; 
    pyproject-nix.url = "github:pyproject-nix/pyproject.nix";
    pyproject-nix.inputs.nixpkgs.follows = "nixpkgs";
    uv2nix.url = "github:pyproject-nix/uv2nix";
    uv2nix.inputs.pyproject-nix.follows = "pyproject-nix";
    uv2nix.inputs.nixpkgs.follows = "nixpkgs";
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, uv2nix, pyproject-nix, pyproject-build-systems }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      imageName = "localhost:5000/hive-netbox";
      imageTag  = "latest";

      perSystem = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib  = nixpkgs.lib;
          workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };
          overlay   = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };
          pythonSet = (pkgs.callPackage pyproject-nix.build.packages {
            python = pkgs.python311; 
          }).overrideScope (lib.composeManyExtensions [
            pyproject-build-systems.overlays.default
            overlay
          ]);
          venv = pythonSet.mkVirtualEnv "netbox-env" workspace.deps.default;
        in { inherit pkgs venv; };
    in {
      packages = forAllSystems (system:
        let
          ps   = perSystem system;
          pkgs = ps.pkgs;
          venv = ps.venv;
          appSource = pkgs.runCommand "app-src" { } ''
            mkdir -p $out/app
            cp -r ${./app}/. $out/app/
          '';
          nonRootUser = pkgs.runCommand "non-root-user" { } ''
            mkdir -p $out/etc
            printf 'root:x:0:0::/root:/bin/sh\nappuser:x:1000:1000::/app:/bin/sh\n' > $out/etc/passwd
            printf 'root:x:0:\nappuser:x:1000:\n'                                 > $out/etc/group
          '';
        in {
          default = self.packages.${system}.image;
          image = pkgs.dockerTools.buildImage {
            name = imageName;
            tag  = imageTag;
            copyToRoot = [ venv appSource nonRootUser pkgs.coreutils pkgs.bash ];
            config = {
              User       = "1000:1000";
              WorkingDir = "/app/netbox"; 
              Env = [
                "PYTHONPATH=/app/netbox"
                "DJANGO_SETTINGS_MODULE=netbox.settings"
                "NETBOX_CONFIGURATION=netbox.configuration"
                "HOME=/tmp"
                "NB_STATIC_ROOT=/tmp/static"
                "NB_MEDIA_ROOT=/tmp/media"
              ];
              Cmd = [ 
                "${venv}/bin/gunicorn" 
                "--bind" "0.0.0.0:8001" 
                "--workers" "3"
                "--worker-tmp-dir" "/tmp"
                "--pid" "/tmp/gunicorn.pid"
                "netbox.wsgi" 
              ];
            } // { ExposedPorts = { "8001/tcp" = { }; }; };
          };
        });
    };
}
