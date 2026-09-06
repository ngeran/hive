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
        #
        # Heads up: this is a big list now (metasploit + wireshark-cli +
        # hashcat + samba pull a lot of deps). First `just build` is slow
        # and the image is ~2GB+. Comment out metasploit below to slim it.
        securityTools = with pkgs; [
          # --- Shell & core (Nix Images ship ONLY what you list here) ---
          bashInteractive     # real shell for `just shell` to exec into
          coreutils           # ls/cat/grep/etc — nothing extra by default
          file                # file-type detection
          vim
          tmux
          screen
          tree
          htop
          jq
          yq                  # YAML processor (Python impl)
          zip
          unzip
          lsof
          strace              # system-call tracer

          # --- Network fundamentals & inspection ---
          curl
          socat
          netcat-gnu          # raw TCP/UDP probing, banner grabbing
          iputils             # ping
          mtr                 # combined traceroute + ping
          traceroute          # ICMP traceroute
          tcptraceroute       # TCP traceroute — bypasses ICMP filters
          fping               # fast ICMP ping sweep
          arping              # ARP ping
          arp-scan            # ARP scanning for local-network discovery
          netdiscover         # active/passive ARP reconnaissance
          nbtscan             # NetBIOS name scanner
          tcpdump             # packet capture
          ngrep               # grep for network packets
          tcpflow             # TCP flow reconstruction
          wireshark-cli       # tshark — CLI analyzer (NOT the GUI pkg)
          iproute2            # ip, ss, tc
          iptables            # firewall utilities
          bridge-utils        # network bridge utilities
          net-tools           # ifconfig, route, netstat
          whois
          dnsutils            # dig, nslookup, host (was "bind-tools")

          # --- Port / host scanning ---
          nmap                # port + service + OS scanning
          masscan             # very fast port scanner
          rustscan            # fast port scanner (Rust)
          hping               # attr is `hping`; binary is hping3 — packet crafting (needs NET_RAW, already granted)

          # --- DNS enumeration ---
          dnsenum
          dnsrecon
          fierce              # DNS brute-force

          # --- Web application testing ---
          gobuster            # directory / DNS brute-forcing
          ffuf                # fast web fuzzer (Go)
          wfuzz               # web fuzzer
          dirb                # web content scanner
          whatweb             # web technology fingerprinting
          wapiti              # web vulnerability scanner
          wpscan              # WordPress vulnerability scanner
          nikto               # web server vulnerability scanner
          sqlmap              # SQL-injection testing

          # --- SSL/TLS ---
          openssl
          sslscan
          testssl             # attr is `testssl` (not testssl-sh)

          # --- SMB / SNMP / RPC enumeration ---
          samba               # provides BOTH smbclient and rpcclient
          enum4linux          # SMB enumeration
          net-snmp            # provides snmpwalk
          onesixtyone         # SNMP brute-force

          # --- Password / credential cracking ---
          hydra               # online credential brute-forcing
          john                # John the Ripper
          fcrackzip           # ZIP password cracking
          hashcat             # CPU-only here (no GPU in pod) — slow but works
          aircrack-ng         # offline .cap cracking works; live capture needs host WiFi radio

          # --- OSINT / recon ---
          theharvester        # attr is lowercase `theharvester`
          recon-ng            # web reconnaissance framework

          # --- Exploitation ---
          exploitdb           # provides `searchsploit` — covers both in one pkg
          metasploit          # ~500MB+, biggest single image/build cost — comment out to slim

          # --- Scripting ---
          # junos-eznc = PyEZ — NETCONF automation against the cRPD routers (Phase 4).
          # JSNAPy is NOT packaged in nixpkgs; `pip install jsnapy` at runtime in the pod
          # (it depends on junos-eznc, which is provided here).
          (python3.withPackages (ps: [ ps.scapy ps.requests ps.junos-eznc ]))

          # --- Intentionally EXCLUDED (verify before adding back) ---
          # maltego            # Java GUI — no display in a headless pod
          # dirbuster          # Java GUI — use ffuf/gobuster/wfuzz/dirb instead
          # ophcrack           # GUI + needs rainbow tables shipped separately
          # kismet             # needs a host WiFi radio (daemon + GUI)
          # reaver             # WPS — needs host radio AND not in nixpkgs
          # knock              # NOT in nixpkgs
          # dnswalk            # NOT in nixpkgs
          # sslyze             # NOT in nixpkgs
          # linpeas / pspy     # NOT in nixpkgs — these are standalone release
          #                    # artifacts; fetch from GitHub at runtime or wire
          #                    # up a fetchurl derivation if you want them baked in
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
