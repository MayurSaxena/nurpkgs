# nurpkgs

My personal [NUR](https://github.com/nix-community/NUR) repository.

## Packages

- `scrobblex` — self-hosted Plex-to-Trakt scrobbler.
- `trek` — self-hosted, collaborative travel planner ([liketrek/TREK](https://github.com/liketrek/TREK)).

## NixOS modules

- `nixosModules.scrobblex` — runs scrobblex as a systemd service.
- `nixosModules.trek` — runs TREK as a systemd service.

```nix
{
  imports = [ inputs.nur.repos.msaxena.modules.nixos.scrobblex ];

  services.scrobblex = {
    enable = true;
    environmentFile = "/run/secrets/scrobblex";
  };
}
```

```nix
{
  imports = [ inputs.nur.repos.msaxena.modules.nixos.trek ];

  services.trek = {
    enable = true;
    allowedOrigins = [ "https://trek.example.com" ];
    environmentFile = "/run/secrets/trek"; # ENCRYPTION_KEY, etc.
  };
}
```
