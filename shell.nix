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
    pkgs.cargo
    pkgs.rustc
  ];

  shellHook = ''
    # UCM loads SQLite via dlopen at runtime — point it at the Nix store copy.
    export SQLITE_LIB_PATH="${pkgs.sqlite.out}/lib/libsqlite3.so"

    # The Restate SDK wraps a Rust cdylib.  Build it once (first nix-shell entry
    # after cloning ../restatedev-sdk-unison takes ~2 min; subsequent entries are instant).
    SDK_DIR="$(dirname "$PWD")/restatedev-sdk-unison"
    RESTATE_NATIVE_DIR="$SDK_DIR/target/release"
    if [ -f "$RESTATE_NATIVE_DIR/librestate_sdk_unison_native.so" ]; then
      export LD_LIBRARY_PATH="$RESTATE_NATIVE_DIR''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    elif [ -d "$SDK_DIR" ]; then
      echo "Building Restate native library (first time only, ~2 min)..."
      cargo build --release -q \
        --manifest-path "$SDK_DIR/crates/restate-sdk-unison-native/Cargo.toml"
      export LD_LIBRARY_PATH="$RESTATE_NATIVE_DIR''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      echo "Restate native library ready."
    else
      echo "warning: ../restatedev-sdk-unison not found — Restate mode will fail"
      echo "  git clone https://github.com/GuillaumeDesforges/restate-sdk-unison ../restatedev-sdk-unison"
      echo "  then re-enter nix-shell"
    fi
  '';
}
