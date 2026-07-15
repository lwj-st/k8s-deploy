# Offline Package Repository Configurations

The Docker download scripts mount this directory read-only at `/repo-config`.
When `config/package-repos/<os_id>/<os_version>/` exists, `apply.sh` replaces
the container's default package repositories with that version-specific
configuration before resolving packages.

Only add a configuration when the base image does not already provide a
version-pinned usable repository. Use official repositories or official vaults.
The selected configuration must contain either:

- `apt/`: files copied to `/etc/apt/`
- `yum.repos.d/`: `.repo` files copied to `/etc/yum.repos.d/`

The current fixed configurations include CentOS 7.9.2009 and 8.4.2105, and
Rocky Linux 8.10, 9.2 through 9.6, and 10.2. Ubuntu, openEuler, and Kylin use
the repositories already included in their version-specific images unless a
matching configuration is added here.
