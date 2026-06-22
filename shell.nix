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

  shellHook = ''
    # UCM loads SQLite via dlopen at runtime — point it at the Nix store copy.
    export SQLITE_LIB_PATH="${pkgs.sqlite.out}/lib/libsqlite3.so"

    # The Restate SDK Unison library wraps a Rust cdylib that must be on
    # LD_LIBRARY_PATH.  Build it once with:
    #   cargo build --release --manifest-path \
    #     ../restatedev-sdk-unison/crates/restate-sdk-unison-native/Cargo.toml
    RESTATE_NATIVE_DIR="$(dirname "$PWD")/restatedev-sdk-unison/target/release"
    if [ -f "$RESTATE_NATIVE_DIR/librestate_sdk_unison_native.so" ]; then
      export LD_LIBRARY_PATH="$RESTATE_NATIVE_DIR''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    else
      echo "warning: librestate_sdk_unison_native.so not found — Restate mode will fail"
      echo "  build it with: cargo build --release --manifest-path ../restatedev-sdk-unison/crates/restate-sdk-unison-native/Cargo.toml"
    fi
  '';
}
