{ pkgs ? import <nixpkgs> {
    config.allowUnfreePredicate = pkg:
      builtins.elem (pkgs.lib.getName pkg) [ "restate" ];
  }
}:

pkgs.mkShell {
  buildInputs = [
    pkgs.unison-ucm
    pkgs.sqlite
    pkgs.restate
    pkgs.curl
    pkgs.jq
  ];
}
