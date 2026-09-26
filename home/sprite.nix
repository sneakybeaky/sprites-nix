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
{pkgs, ...}: {
  home.username = "sprite";
  home.homeDirectory = "/home/sprite";
  home.stateVersion = "26.11";

  # Not NixOS: fixes XDG_DATA_DIRS, LOCALE_ARCHIVE and nix profile sourcing
  # against the Ubuntu filesystem layout.
  targets.genericLinux.enable = true;

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
      safe.directory = "*"; # the overlay filesystem confuses git's ownership check
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
    # `sprite console` starts an interactive, non-login shell, which never
    # reads ~/.profile. Source the session vars from .bashrc too, otherwise
    # PATH, EDITOR and XDG_DATA_DIRS are silently missing in every console.
    initExtra = ''
      if [ -f "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh" ]; then
        . "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"
      fi
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
