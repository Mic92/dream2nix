{
  # from dream2nix
  configFile,
  dream2nixWithExternals,
  fetchers,
  nix,
  translators,
  utils,

  # from nixpkgs
  gitMinimal,
  lib,
  python3,
  ...
}:

let

  b = builtins;

  cliPython = python3.withPackages (ps: [ ps.networkx ps.cleo ps.jsonschema ]);

in
{
  program = 
    let
      script = utils.writePureShellScript
        [
          gitMinimal
          nix
        ]
        ''
          # escape the temp dir created by writePureShellScript
          cd - > /dev/null

          # run the cli
          dream2nixConfig=${configFile} \
          dream2nixSrc=${dream2nixWithExternals} \
          fetcherNames="${b.toString (lib.attrNames fetchers.fetchers)}" \
            ${cliPython}/bin/python ${./.}/cli.py "$@"
        '';
    in
      "${script}/bin/run";

  templateDefaultNix =
    {
      dream2nixLocationRelative,
      dreamLock,
      sourcePathRelative,
    }:
    let
      mainPackageName = dreamLock._generic.mainPackageName;
      mainPackageVersion = dreamLock._generic.mainPackageVersion;
    in
    ''
      {
        dream2nix ? import (
          let
            dream2nixWithExternals = (builtins.getEnv "dream2nixWithExternals");
          in
            if dream2nixWithExternals != "" then dream2nixWithExternals else
              throw '''
                This default.nix is for debugging purposes and can only be evaluated within the dream2nix devShell env.
              ''') {},
      }:

      dream2nix.riseAndShine {
        dreamLock = ./dream-lock.json;
        ${lib.optionalString (dreamLock.sources."${mainPackageName}"."${mainPackageVersion}".type == "unknown") ''
          sourceOverrides = oldSources: {
              "${mainPackageName}#${mainPackageVersion}" = ./${sourcePathRelative};
            };
        ''}
      }
  '';
}
