{ lib, stdenv, fetchFromGitHub, writeShellApplication }:

stdenv.mkDerivation rec {
  pname = "widget-tool";
  version = "1.0.0";

  src = fetchFromGitHub {
    owner = "example";
    repo = pname;
    rev = "v${version}";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };

  buildPhase = ''
    runHook preBuild
    echo "building ${pname}-${version}"
    runHook postBuild
  '';

  nativeBuildInputs = [
    (writeShellApplication {
      name = "render-widget";
      text = ''
        echo "widget:$1"
      '';
    })
  ];

  passthru.tests.smoke = stdenv.mkDerivation {
    name = "${pname}-smoke";
    buildCommand = ''
      mkdir -p $out
      touch $out/ok
    '';
  };

  meta = with lib; {
    description = "Example widget renderer";
    license = licenses.mit;
    platforms = platforms.linux;
    maintainers = with maintainers; [ example ];
  };
}
