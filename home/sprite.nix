#
# Home Manager configuration applied inside a Fly.io Sprite.
#
# The guest is an Ubuntu base image with a writable overlay, default user
# `sprite`, home at /home/sprite. Two guest facts shape everything below:
#
#   1. The filesystem persists across hibernation; RAM does not. Long-running
#      processes belong in `sprite-env services create`, not systemd units.
#   2. There is no systemd session bus to talk to, so no systemd.user services.
#
{
  config,
  pkgs,
  ...
}: {
  home.username = "sprite";
  home.homeDirectory = "/home/sprite";
  home.stateVersion = "26.11";

  # Not NixOS: fixes XDG_DATA_DIRS, LOCALE_ARCHIVE and nix profile sourcing
  # against the Ubuntu filesystem layout.
  targets.genericLinux.enable = true;

  # ...but a Sprite is a headless microVM with no display. The GPU integration
  # defaults to on with genericLinux and drags in mesa (272 MiB unpacked) plus
  # two non-nixos-gpu derivations for nothing.
  targets.genericLinux.gpu.enable = false;

  # The guest has no USER or LOGNAME (sprite exec hands over a minimal
  # environment), and nix's own profile script starts with
  #   if [ -n "$HOME" ] && [ -n "$USER" ]
  # so without them nothing nix-related reaches PATH. Setting them here is what
  # fixes every shell at once: home-manager emits sessionVariables *before*
  # sessionVariablesExtra, and targets.genericLinux appends the `. nix.sh` line
  # to the latter. The fish module babelfish-translates the same file.
  home.sessionVariables = {
    USER = config.home.username;
    LOGNAME = config.home.username;
  };

  # Nix itself is installed and configured by scripts/bootstrap-guest.sh.
  #
  # Do not let Home Manager manage it: home.packages is installed into the same
  # ~/.nix-profile that the single-user installer uses for `nix`, so setting
  # nix.package here makes activation fail with a file conflict on bin/nix.
  nix.enable = false;

  # No systemd in the guest. Without this, activation tries to talk to a
  # session bus that does not exist.
  systemd.user.startServices = false;

  home.packages = with pkgs; [
    bat
    curl
    eza
    fd
    gh
    gnumake
    go
    htop
    jq
    ripgrep
    tree
    unzip
    wget

    # Agent CLIs from numtide/llm-agents.nix, exposed as pkgs.llm-agents by
    # the overlay in flake.nix. Same source as the host config, so the two
    # stay on matching versions.
    llm-agents.hermes-agent
    llm-agents.claude-code

    # The rest of the workbench, mirroring the host's ai.nix/ai-personal.nix.
    # Note the base image already provides node, python+uv, rust, go, gh, git,
    # sqlite and jq; the Nix copies above/below shadow them on purpose so the
    # versions are pinned rather than whatever Fly baked in.
    llm-agents.crush
    llm-agents.ccusage
    llm-agents.agent-browser
    llm-agents.skills
    llm-agents.herdr
    llm-agents.nono
  ];

  programs.home-manager.enable = true;

  programs.delta = {
    enable = true;
    enableGitIntegration = true;
  };

  programs.git = {
    enable = true;
    settings = {
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
    };
    # Set your identity here, or leave it to `gh auth setup-git` / per-repo config.
    # userName = "you";
    # userEmail = "you@example.com";
  };

  programs.bash = {
    enable = true;
    historyControl = ["ignoredups" "ignorespace"];
    shellAliases = {
      ls = "eza";
      ll = "eza -l --git";
      la = "eza -la --git";
      cat = "bat --paging=never";
    };
    # Two guest quirks, fixed in order:
    #
    # 1. `sprite exec`/`console` provide no USER or LOGNAME, and Nix's
    #    profile script no-ops unless USER is set, so nix would be missing
    #    from PATH.
    # 2. `sprite console` is an interactive, non-login shell, so it never
    #    reads ~/.profile and would miss the session vars entirely.
    initExtra = ''
      : "''${USER:=$(id -un)}"
      : "''${LOGNAME:=$USER}"
      export USER LOGNAME

      if [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
        . "$HOME/.nix-profile/etc/profile.d/nix.sh"
      fi
      if [ -f "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh" ]; then
        . "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"
      fi
    '';
  };

  # `sprite console` inherits your *local* $SHELL, so on a fish host you land
  # in the guest's fish (4.2.1, from the base image) — which read no nix
  # config at all before this. Enabling the module also gives fish the
  # starship/direnv/fzf/zoxide integrations that were bash-only.
  programs.fish = {
    enable = true;

    # Off for two reasons. It builds one <pkg>-fish-completions derivation for
    # every entry in home.packages (37 extra local builds here), and each one
    # runs fish, which creates its config dirs in $HOME — i.e. in
    # /homeless-shelter, which then makes every later build fail nix's
    # no-sandbox purity check.
    generateCompletions = false;
    shellInit = ''
      # Belt and braces for a shell started without sourcing hm-session-vars.
      if test -z "$USER"
        set -gx USER (id -un)
      end
      if test -z "$LOGNAME"
        set -gx LOGNAME $USER
      end

      # Fish cannot source the POSIX nix.sh; use the fish variant the
      # installer ships, then make sure the profile is on PATH regardless.
      if test -e $HOME/.nix-profile/etc/profile.d/nix.fish
        source $HOME/.nix-profile/etc/profile.d/nix.fish
      end
      if not contains $HOME/.nix-profile/bin $PATH
        set -gx PATH $HOME/.nix-profile/bin $PATH
      end
    '';
  };

  programs.starship = {
    enable = true;
    settings = {
      add_newline = false;
      hostname.ssh_only = false;
      hostname.format = "[sprite](bold cyan) ";
    };
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.fzf.enable = true;
  programs.zoxide.enable = true;

  programs.tmux = {
    enable = true;
    mouse = true;
    escapeTime = 10;
  };

  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
  };
}
