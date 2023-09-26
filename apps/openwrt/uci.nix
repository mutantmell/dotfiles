{
  lib,
  ...
}:

{
  render-uci = let
    render-options = prefix: options: (lib.attrsets.mapAttrsToList (opt: value:
      prefix + (builtins.concatStringsSep " " (
        builtins.map (v: "'${v}'")
      )) (if builtins.isList value then value else [value])
    ) options);
  in config: 
    lib.strings.concatStrings (
      lib.attrsets.mapAttrsToList (config-group: sections:
        (lib.lists.foldl' (acc@{
          ixs,
            output
        }: {
          type,
            name ? null,
            options
        }: if options == [] then acc
           else if name != null then {
             ixs = ixs;
             output = output ++ [
               "${config-group}.${name}=${type}"
             ] ++ (
               render-options "${config-group}.${name}.${opt}=" options
             );
           } else let
             type-ix = if ixs ? ${type} then ixs.type + 1 else 0;
           in {
             ixs = ixs // {
               type = type-ix;
             };
             output = output ++ [
               "${config-group}.@${type}[${type-ix}]=${type}"
             ] ++ (
               render-options "${config-group}.@${type}[${type-ix}].${opt}=" options
             );
           }) {
             ixs = {}; output = [];
           } sections
        ).output
      ) config
    );
}
