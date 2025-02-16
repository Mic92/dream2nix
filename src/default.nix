# This is the system specific api for dream2nix.
# It requires passing one specific pkgs.
# If the intention is to generate output for several systems,
# use ./lib.nix instead.

{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,

  # the dream2nix cli depends on some nix 2.4 features
  nix ? pkgs.writeScriptBin "nix" ''
    #!${pkgs.bash}/bin/bash
    ${pkgs.nixUnstable}/bin/nix --option experimental-features "nix-command flakes" "$@"
  '',

  # default to empty dream2nix config
  config ?
    # if called via CLI, load cnfig via env
    if builtins ? getEnv && builtins.getEnv "d2nConfigFile" != "" then
      builtins.toPath (builtins.getEnv "d2nConfigFile")
    # load from default directory
    else
      {},

  # dependencies of dream2nix
  externalSources ?
    lib.genAttrs
      (lib.attrNames (builtins.readDir externalDir))
      (inputName: "${externalDir}/${inputName}"),

  # will be defined if called via flake
  externalPaths ? null,

  # required for non-flake mode
  externalDir ?
    # if flake is used, construct external dir from flake inputs
    if externalPaths != null then
      (import ./utils/external-dir.nix {
        inherit externalPaths externalSources pkgs;
      })
    # if called via CLI, load externals via env
    else if builtins ? getEnv && builtins.getEnv "d2nExternalDir" != "" then
      builtins.getEnv "d2nExternalDir"
    # load from default directory
    else
      ./external,

}@args:

let

  b = builtins;

  config = (import ./utils/config.nix).loadConfig args.config or {};

  configFile = pkgs.writeText "dream2nix-config.json" (b.toJSON config);

  # like pkgs.callPackage, but includes all the dream2nix modules
  callPackageDream = f: args: pkgs.callPackage f (args // {
    inherit builders;
    inherit callPackageDream;
    inherit config;
    inherit configFile;
    inherit externals;
    inherit externalSources;
    inherit fetchers;
    inherit dream2nixWithExternals;
    inherit translators;
    inherit utils;
    inherit nix;
  });


  utils = callPackageDream ./utils {};

  # apps for CLI and installation
  apps = callPackageDream ./apps {};

  # builder implementaitons for all subsystems
  builders = callPackageDream ./builders {};

  # fetcher implementations
  fetchers = callPackageDream ./fetchers {};

  # updater modules to find newest package versions
  updaters = callPackageDream ./updaters {};

  # the translator modules and utils for all subsystems
  translators = callPackageDream ./translators {};

  externals = {
    node2nix = nodejs:
      pkgs.callPackage "${externalSources.node2nix}/nix/node-env.nix" {
        inherit nodejs;
      };
    nix-parsec = rec {
      lexer = import "${externalSources.nix-parsec}/lexer.nix" {
        inherit parsec;
      };
      parsec = import "${externalSources.nix-parsec}/parsec.nix";
    };
  };

  dreamOverrides =
    utils.loadOverridesDirs config.overridesDirs pkgs;

  # the location of the dream2nix framework for self references (update scripts, etc.)
  dream2nixWithExternals =
    if b.pathExists (./. + "/external") then
      ./.
    else
      pkgs.runCommand "dream2nix-full-src" {} ''
        cp -r ${./.} $out
        chmod +w $out
        mkdir $out/external
        ls -lah ${externalDir}
        cp -r ${externalDir}/* $out/external/
      '';

  # automatically find a suitable builder for a given dream lock
  findBuilder = dreamLock:
    let
      subsystem = dreamLock._generic.subsystem;
    in
      if ! builders ? "${subsystem}" then
        throw "Could not find any builder for subsystem '${subsystem}'"
      else
        builders."${subsystem}".default;


  # detect if granular or combined fetching must be used
  findFetcher = dreamLock:
      if null != dreamLock._generic.sourcesCombinedHash then
        fetchers.combinedFetcher
      else
        fetchers.defaultFetcher;

  # fetch only sources and do not build
  fetchSources =
    {
      dreamLock,
      fetcher ? null,
      extract ? false,
    }@args:
    let
      # if dream lock is a file, read and parse it
      dreamLock' = (utils.readDreamLock { inherit dreamLock; }).lock;

      fetcher =
        if args.fetcher == null then
          findFetcher dreamLock'
        else
          args.fetcher;

      fetched = fetcher {
        mainPackageName = dreamLock._generic.mainPackageName;
        mainPackageVersion = dreamLock._generic.mainPackageVersion;
        sources = dreamLock'.sources;
        sourcesCombinedHash = dreamLock'._generic.sourcesCombinedHash;
      };

      fetchedSources = fetched.fetchedSources;

    in
      fetched // {
        fetchedSources =
          if extract then
            lib.mapAttrs
              (key: source: utils.extractSource { inherit source; })
              fetchedSources
          else
            fetchedSources;
      };

  
  makeDreamLockForSource =
    {
      source,
      translatorArgs ? {},
    }@args:
    let

      sourceSpec =
        if b.isString args.source && ! lib.isStorePath args.source then
          fetchers.translateShortcut { shortcut = args.source; }
        else
          {
            type = "path";
            path = args.source;
          };

      source = fetchers.fetchSource { source = sourceSpec; };

      translatorsForSource = translators.translatorsForInput {
        inputFiles = [];
        inputDirectories = [ source ];
      };

      t =
        let
          trans = b.filter (t: t.compatible && b.elem t.type [ "pure" "ifd" ]) translatorsForSource;
        in
          if trans != [] then lib.elemAt trans 0 else
            throw "Could not find a suitable translator for input";

      dreamLock' = translators.translators."${t.subsystem}"."${t.type}"."${t.name}".translate
        (translatorArgs // {
          inputFiles = [];
          inputDirectories = [ source ];
        });

      dreamLock = lib.recursiveUpdate dreamLock' {
        sources."${dreamLock'._generic.mainPackageName}"."${dreamLock'._generic.mainPackageVersion}" = {
          type = "path";
          path = "${source}";
        };
      };

    in
      dreamLock;


  # build a dream lock via a specific builder
  callBuilder =
    {
      builder,
      builderArgs,
      fetchedSources,
      dreamLock,
      inject,
      sourceOverrides,
    }@args:
      let

        # inject dependencies
        dreamLock = utils.dreamLock.injectDependencies args.dreamLock inject;

        dreamLockInterface = (utils.readDreamLock { inherit dreamLock; }).interface;

        changedSources = sourceOverrides args.fetchedSources;

        fetchedSources =
          args.fetchedSources // changedSources;

        buildPackageWithOtherBuilder =
          {
            builder,
            name,
            version,
            inject ? {},
          }:
          let
            subDreamLockLoaded =
              utils.readDreamLock {
                dreamLock =
                  utils.dreamLock.getSubDreamLock dreamLock name version;
              };

          in
            callBuilder {
              inherit builder builderArgs inject sourceOverrides;
              dreamLock =
                subDreamLockLoaded.lock;
              inherit fetchedSources;
            };

        outputs = builder ( builderArgs // {

          inherit
            buildPackageWithOtherBuilder
          ;

          inherit (dreamLockInterface)
            subsystemAttrs
            getDependencies
            getCyclicDependencies
            mainPackageName
            mainPackageVersion
            packageVersions
          ;

          getSource = utils.dreamLock.getSource fetchedSources;

        });

      in
        outputs;


  # produce outputs for a dream-lock or a source
  riseAndShine = 
    {
      dreamLock ? null,
      builder ? null,
      fetcher ? null,
      inject ? {},
      source ? null,
      sourceOverrides ? oldSources: {},
      packageOverrides ? {},
      builderArgs ? {},
      translatorArgs ? {},
    }@args:

    # ensure either dreamLock or source is used
    if source != null && dreamLock != null then
      throw "Define either 'dreamLock' or 'source', not both"
    else if source == null && dreamLock == null then
      throw "Define either 'dreamLock' or 'source'"
    else

    let

      dreamLock' =
        if source != null then
          makeDreamLockForSource { inherit source translatorArgs; }
        else
          args.dreamLock;

      # parse dreamLock
      dreamLockLoaded = utils.readDreamLock { dreamLock = dreamLock'; };
      dreamLock = dreamLockLoaded.lock;
      dreamLockInterface = dreamLockLoaded.interface;

      builder' =
        if builder == null then
          findBuilder dreamLock
        else
          builder;

      fetcher' =
        if fetcher == null then
          findFetcher dreamLock
        else
          fetcher;

      fetchedSources = (fetchSources {
        inherit dreamLock;
        fetcher = fetcher';
      }).fetchedSources;

      builderOutputs = callBuilder {
        inherit
          dreamLock
          fetchedSources
          sourceOverrides
        ;
        builder = builder';
        builderArgs = (args.builderArgs or {}) // {
          packageOverrides =
            lib.recursiveUpdate
              (dreamOverrides."${dreamLock._generic.subsystem}" or {})
              (args.packageOverrides or {});
        };
        inject =
          utils.dreamLock.decompressDependencyGraph args.inject or {};
      };

      # Makes the packages tree compatible with flakes schema.
      # For each package the attr `{pname}` will link to the latest release.
      # Other package versions will be inside: `{pname}.versions`
      formattedBuilderOutputs = builderOutputs // {
        packages =
          let
            allPackages = builderOutputs.packages or {};

            latestPackages =
              lib.mapAttrs'
                (pname: releases:
                  let
                    latest =
                      releases."${utils.latestVersion (b.attrNames releases)}";
                  in
                    (lib.nameValuePair
                      "${pname}"
                      (latest // {
                        versions = releases;
                      })))
                allPackages;
          in
            latestPackages;
      };
    in
      formattedBuilderOutputs;
   
in
{
  inherit
    apps
    builders
    dream2nixWithExternals
    fetchers
    fetchSources
    riseAndShine
    translators
    updaters
    utils
  ;
}
