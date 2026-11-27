# Install the docker command

Boxcar uses the `docker` command to show and control your containers. Docker Desktop, OrbStack, and Rancher Desktop include this command. If you use another container engine, such as Colima, Podman, or VMPal, install the command with [Homebrew](https://brew.sh):

```sh
brew install docker docker-compose
```

> [!NOTE]
> This installs the `docker` CLI command, which is used by Docker-compatible container engines. It does not install Docker Desktop or any other container engine. You also need a container engine that is installed and running.

Then open the Boxcar menu. You do not need to restart Boxcar.

## Optional: use Docker in Terminal

Boxcar works without these steps. If you build images, also install Buildx:

```sh
brew install docker-buildx
```

To use Buildx and `docker compose` (with a space) on a Mac with Apple silicon, add the `cliPluginsExtraDirs` entry to `~/.docker/config.json`:

```json
{
  "cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"]
}
```
