{
  description = "redcell-range: reproducible security-tooling workspace for the k3s lab";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Every tool here comes straight from nixpkgs — no apt, no pulled
        # base image, no digest to babysit. Want another tool later?
        # Add a line, `direnv allow`, `just deploy`. Nothing else changes.
        securityTools = with pkgs; [
          bashInteractive     # gives `just shell` a real shell to exec into
          coreutils           # ls/cat/grep/etc — Nix images ship *only* what
                               # you list here, nothing extra by default
          nmap                # port + service + OS scanning
          tcpdump              # packet capture
          netcat-gnu           # raw TCP/UDP probing, banner grabbing
          dnsutils              # dig, nslookup
          whois
          mtr                  # combined traceroute + ping
          iputils               # ping
          curl
          socat
          hydra                 # online credential brute-forcing
          sqlmap                # SQL-injection testing
          gobuster               # directory / DNS brute-forcing
          nikto                  # web server vulnerability scanner
          masscan                 # very fast port scanner
          (python3.withPackages (ps: [ ps.scapy ps.requests ]))
        ];
      in
      {
        packages.image = pkgs.dockerTools.buildImage {
          name = "localhost:5000/redcell-range";
          tag = "latest";

          copyToRoot = pkgs.buildEnv {
            name = "redcell-range-tools";
            paths = securityTools;
            pathsToLink = [ "/bin" ];
          };

          config = {
            # "sleep infinity" means this container never has a job to
            # finish — it just stays alive so you can `kubectl exec` into
            # it on demand. This is a workspace pod, not a service pod.
            Cmd = [ "sleep" "infinity" ];
            Env = [ "PATH=/bin" ];
          };
        };

        # `nix develop` here gets you the CLI tools needed to build/push/deploy
        # from your NixOS host — same devShell shape as your other projects.
        devShells.default = pkgs.mkShell {
          buildInputs = [ pkgs.just pkgs.kubectl pkgs.skopeo ];
        };
      });
}
