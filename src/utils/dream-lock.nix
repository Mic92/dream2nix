{
  lib,

  # dream2nix
  utils,
  ...
}:
let

  b = builtins;

  readDreamLock = 
    {
      dreamLock,
    }@args:
    let

      lockMaybeCompressed =
        if b.isPath dreamLock
            || b.isString dreamLock
            || lib.isDerivation dreamLock then
          b.fromJSON (b.readFile dreamLock)
        else
          dreamLock;

      lock =
        if lockMaybeCompressed.decompressed or false then
          lockMaybeCompressed
        else
          decompressDreamLock lockMaybeCompressed;

      mainPackageName = lock._generic.mainPackageName;
      mainPackageVersion = lock._generic.mainPackageVersion;

      subsystemAttrs = lock._subsystem;

      sources = lock.sources;

      dependencyGraph = lock.dependencies;

      packageVersions =
        lib.mapAttrs
          (name: versions: lib.attrNames versions)
          dependencyGraph;

      cyclicDependencies = lock.cyclicDependencies;

      getDependencies = pname: version:
        b.filter
          (dep: ! b.elem dep cyclicDependencies."${pname}"."${version}" or [])
          dependencyGraph."${pname}"."${version}" or [];
      
      getCyclicDependencies = pname: version:
        cyclicDependencies."${pname}"."${version}" or [];

    in
      {
        inherit lock;
        interface = rec {

          inherit
            mainPackageName
            mainPackageVersion
            subsystemAttrs
            getCyclicDependencies
            getDependencies
            packageVersions
          ;
        };
      };

  getMainPackageSource = dreamLock:
    dreamLock.sources
      ."${dreamLock._generic.mainPackageName}"
      ."${dreamLock._generic.mainPackageVersion}";

  getSource = fetchedSources: pname: version:
    let
      key = "${pname}#${version}";
    in
      if fetchedSources ? "${key}"
          && fetchedSources."${key}" != "unknown" then
        fetchedSources."${key}"
      else
        throw ''
          The source for ${key} is not defined.
          This can be fixed via an override. Example:
          ```
            dream2nix.riseAndShine {
              ...
              sourceOverrides = oldSources: {
                "${key}" = builtins.fetchurl { ... };
              };
              ...
            }
          ```
        '';

    # generate standalone dreamLock for a depenndency of an existing dreamLock
    getSubDreamLock = dreamLock: name: version:
      let
        lock = (readDreamLock { inherit dreamLock; }).lock;
      
      in
        lock // {
          _generic = lock._generic // {
            mainPackageName = name;
            mainPackageVersion = version;
          };
        };

    injectDependencies = dreamLock: inject:
      if inject == {} then dreamLock else
      let
        lock = (readDreamLock { inherit dreamLock; }).lock;

        oldDependencyGraph = lock.dependencies;

        newDependencyGraph =
          lib.zipAttrsWith
            (name: versions:
              lib.zipAttrsWith
                (version: deps: lib.unique (lib.flatten deps))
                versions)
            [
              oldDependencyGraph
              inject
            ];

      in
        lib.recursiveUpdate lock {
          dependencies = newDependencyGraph;
        };

    decompressDependencyGraph = compGraph:
      lib.mapAttrs
        (name: versions:
          lib.mapAttrs
            (version: deps:
              map
                (dep: {
                  name = b.elemAt dep 0;
                  version = b.elemAt dep 1;
                })
                deps)
            versions)
          compGraph;

    compressDependencyGraph = decompGraph:
      lib.mapAttrs
        (name: versions:
          lib.mapAttrs
            (version: deps: map ( dep: [ dep.name dep.version ]) deps)
            versions)
        decompGraph;

    decompressDreamLock = comp:
      let
        dependencyGraphDecomp =
          decompressDependencyGraph (comp.dependencies or {});

        cyclicDependencies =
          decompressDependencyGraph (comp.cyclicDependencies or {});

        emptyDependencyGraph =
          lib.mapAttrs
            (name: versions:
              lib.mapAttrs
                (version: source: [])
                versions)
            comp.sources;

        dependencyGraph =
          lib.recursiveUpdate
            emptyDependencyGraph
            dependencyGraphDecomp;

      in
        comp // {
          decompressed = true;
          cyclicDependencies = cyclicDependencies;
          dependencies = dependencyGraph;
        };

    compressDreamLock = uncomp:
      let
        dependencyGraphComp =
          compressDependencyGraph
            uncomp.dependencies;

        cyclicDependencies =
          compressDependencyGraph
            uncomp.cyclicDependencies;

        dependencyGraph =
          lib.filterAttrs
            (name: versions: versions != {})
            (lib.mapAttrs
              (name: versions:
                lib.filterAttrs
                  (version: deps: deps != [])
                  versions)
              dependencyGraphComp);
      in
      (b.removeAttrs uncomp [ "decompressed" ]) // {
        inherit cyclicDependencies;
        dependencies = dependencyGraph;
      };

    toJSON = dreamLock:
      let
        lock =
          if dreamLock.decompressed or false then
            compressDreamLock dreamLock
          else
            dreamLock;

        json = b.toJSON lock;

      in
        json;

in
  {
    inherit
      compressDreamLock
      decompressDreamLock
      decompressDependencyGraph
      getMainPackageSource
      getSource
      getSubDreamLock
      readDreamLock
      injectDependencies
      toJSON
    ;
  }
