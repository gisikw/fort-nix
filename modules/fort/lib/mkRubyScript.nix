{ pkgs, ruby ? pkgs.ruby }:

let
  inherit (pkgs.lib) concatStringsSep escapeShellArg;

  toRuby = val:
    if builtins.isBool val then
      if val then "true" else "false"
    else if builtins.isInt val then
        builtins.toString val
    else
      ''"${val}"'';

in

# mkRubyScript ./script.rb [ "redis" "nokogiri" ] { foo = 1; bar = "baz"; }
path: deps: attrs:
let
  rubyWithDeps = ruby.withPackages (ps: builtins.map (name: ps.${name}) deps);

  vars = concatStringsSep "\n"
    (builtins.attrValues (builtins.mapAttrs (name: val:
      "@${name} = ${toRuby val}"
    ) attrs));

  rubyScript = pkgs.writeText "script.rb" ''
    ${vars}

    ${builtins.readFile path}
  '';
in
  "${rubyWithDeps}/bin/ruby ${rubyScript}"
