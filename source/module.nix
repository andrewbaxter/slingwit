{ config, pkgs, lib, ... }:
let
  options = {
    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable debug logging";
    };
    environment = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
      default = null;
    };
    tasks = lib.mkOption {
      description = "Each key is the name of a task, values are converted to task json specifications (see puteron task json spec)";
      default = { };
      type = lib.types.attrsOf lib.types.attrs;
    };
    controlSystemd = lib.mkOption {
      description = "A map of systemd unit names to control options or null to disable. Where not null, this will create a `long` or `short` puteron task (depending on whether the options indicate it's a oneshot unit) that invokes the wrapper `puteron-control-systemd` command to control the systemd unit from puteron itself (i.e. when started, it'll start the unit; when stopped, it'll stop the unit). The task name will be in the form `systemd-UNIT-UNITSUFFIX`.";
      default = { };
      type = lib.types.attrsOf
        (lib.types.nullOr (lib.types.submodule {
          options = {
            oneshot = lib.mkOption {
              description = "The systemd unit is a oneshot service (changes how child process exits are handled)";
              default = false;
              type = lib.types.bool;
            };
            exitCode = lib.mkOption
              {
                description = "The unit code considered as a successful exit (default 0)";
                default = null;
                type = lib.types.nullOr lib.types.int;
              };
          };
        }));
    };
    listenSystemd = lib.mkOption
      {
        description = "A map of systemd unit names (with dotted suffix) to a boolean. Where true this will create an `empty` puteron task that is turned on and off to match activation of the corresponding systemd unit. Add the task as a weak upstream of other tasks. Only implemented for `.service`, `.mount`, `.target` at this time. The task name will be in the form `systemd-UNIT-UNITSUFFIX`.";
        default = { };
        type = lib.types.attrsOf (lib.types.nullOr lib.types.bool);
      };
  };
in
{
  options = {
    puteron = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable the puteron service for managing tasks (services). This will create a systemd root and user unit to run puteron, with the task config directory in the Nix store plus an additional directory in `/etc/puteron/tasks` or `~/.config/puteron/tasks`.";
          };
          user = lib.mkOption {
            default = { };
            type = lib.types.submodule { options = options; };
          };
        } // options;
      };
    };
  };
  config =
    let
      pkg = import ./package.nix {
        pkgs = pkgs;
        debug = config.puteron.debug;
      };

      # Build an options level
      build = { levelName, options, wantedBy }:
        let
          # The `empty` systemd task name is based on the systemd unit name + suffix
          mapSystemdTaskName = name:
            let
              mangled = builtins.replaceStrings [ "." "@" ":" ] [ "-" "-" "-" ] name;
            in
            "systemd-${mangled}";

          # Filtered systemd interop lists
          listenSystemd =
            if options.listenSystemd != null
            then lib.attrsets.filterAttrs (name: value: value != null) options.listenSystemd
            else { };
          controlSystemd =
            if options.controlSystemd != null
            then lib.attrsets.filterAttrs (name: value: null != value) options.controlSystemd
            else { };

          # Defined tasks + generated `empty` tasks for systemd units
          tasks = { }
            // (if options.tasks != null then options.tasks else { })
            // (lib.attrsets.mapAttrs'
            (name: value: {
              name = mapSystemdTaskName name;
              value = {
                type = "empty";
              };
            })
            listenSystemd)
            // (lib.attrsets.mapAttrs'
            (name: value: {
              name = mapSystemdTaskName name;
              value =
                if value.oneshot
                then {
                  type = "short";
                  command = {
                    line = [ ]
                      ++ [ "${pkg}/bin/puteron-control-systemd" "--oneshot" ]
                      ++ (if value.exitCode != null then [ "--exit-code" "${builtins.toString value.exitCode}" ] else [ ])
                      ++ [ ];
                  };
                }
                else
                  {
                    type = "long";
                    command = {
                      line = [ ]
                        ++ [ "${pkg}/bin/puteron-control-systemd" ]
                        ++ (if value.exitCode != null then [ "--exit-code" "${builtins.toString value.exitCode}" ] else [ ])
                        ++ [ ];
                    };
                  };
            })
            controlSystemd)
            // { };

          # Build task dir out of tasks
          tasksDir = derivation {
            name = "puteron-${levelName}-tasks-dir";
            system = builtins.currentSystem;
            builder = "${pkgs.python3}/bin/python3";
            args = [
              ./module_gendir.py
              (builtins.toJSON tasks)
            ];
          };

          # Build daemon config
          demonConfig = pkgs.writeTextFile {
            name = "puteron-${levelName}-config";
            text = builtins.toJSON (builtins.listToAttrs (
              [ ]
              ++ (if options.environment != null then [{
                name = "environment";
                value = options.environment;
              }] else [ ])
              ++ [{
                name = "task_dirs";
                value = [ "${tasksDir}" "%E/puteron/tasks" ];
              }]
            ));
            checkPhase = ''
              ${config.system.build.puteron.pkg}/bin/puteron demon run $out --validate
            '';
          };

          # Build hooks for systemd services hooked with `empty` tasks 
          buildSystemdHooks = type:
            let
              suffix = ".${type}";
            in
            lib.attrsets.mapAttrs'
              (name: value: {
                name = lib.strings.removeSuffix suffix name;
                value =
                  {
                    serviceConfig.ExecStartPost = "${pkg}/bin/puteron on ${mapSystemdTaskName name}";
                    serviceConfig.ExecStopPre = "${pkg}/bin/puteron off ${mapSystemdTaskName name}";
                  };
              })
              (lib.attrsets.filterAttrs
                (name: value: lib.strings.hasSuffix suffix name)
                listenSystemd);
          script = pkgs.writeShellScript "puteron-${levelName}-script" (lib.concatStringsSep " " ([ ]
            ++ [ "${pkg}/bin/puteron" "demon" "run" "${demonConfig}" ]
            ++ (if config.puteron.debug then [ "--debug" ] else [ ])
          ));
        in
        {
          script = script;

          systemdServices = { }
            # Root service
            // (if config.puteron.enable then {
            puteron = {
              wantedBy = [ wantedBy ];
              serviceConfig.Type = "simple";
              startLimitIntervalSec = 0;
              serviceConfig.Restart = "on-failure";
              serviceConfig.RestartSec = 60;
              script = "${script}";
            };
          } else { })
            // buildSystemdHooks "service";
          systemdTargets = buildSystemdHooks "target";
          systemdMounts = map
            (mount: {
              where = mount.name;
            } // mount.value)
            (lib.attrsToList (buildSystemdHooks "mount"));
        };

      # Generate at root + user levels
      root = build {
        levelName = "root";
        options = config.puteron;
        wantedBy = "multi-user.target";
      };
      user = build {
        levelName = "user";
        options = config.puteron.user;
        wantedBy = "default.target";
      };
    in
    {
      system.build.puteron.pkg = pkg;

      # Assemble root config
      system.build.puteron.script = root.script;
      systemd.services = root.systemdServices;
      systemd.targets = root.systemdTargets;
      systemd.mounts = root.systemdMounts;

      # Assemble user config
      system.build.puteron.userScript = user.script;
      systemd.user.services = user.systemdServices;
      systemd.user.targets = user.systemdTargets;
    };
}
