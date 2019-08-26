let pkgs =  import <nixpkgs> {};
in with pkgs;
let

  mkGhc = (import /home/matt/old-ghc-nix { pkgs = pkgs; }).mkGhc;
  # Import the Haskell.nix library,
  ghc = mkGhc
        { url = "https://downloads.haskell.org/~ghc/8.6.5/ghc-8.6.5-x86_64-deb9-linux-dwarf.tar.xz";
        hash = "0sd4ib7rvi04pxbm3wdml4b8yvnhm8ik0p7pafll6s7wyyw1769i";
        ncursesVersion = "5"; };
in

stdenv.mkDerivation {
  name = "haskell-ide-engine";
  buildInputs = [
    gmp
    zlib
    ncurses5
    elfutils
    haskellPackages.cabal-install
    ghc
    haskellPackages.stack
    gdb
  ];
  src = null;
  shellHook = ''
    export LD_LIBRARY_PATH=${gmp}/lib:${zlib}/lib:${ncurses5}/lib:${elfutils}/lib
    export PATH=$PATH:$HOME/.local/bin
  '';
}
