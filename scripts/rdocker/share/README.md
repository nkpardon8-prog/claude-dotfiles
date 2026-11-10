# rdocker share switch (for the owner of a Mac worker)

Your Mac runs rdocker jobs as a separate non-admin user `rd`. You decide how much it gets:

```sh
rdocker-share max      # all job slots; Docker VM 12 CPU / 24 GB
rdocker-share some     # half the job slots; Docker VM 6 CPU / 12 GB
rdocker-share off      # no new jobs (running ones finish); the Docker VM stops once idle
rdocker-share status   # current level and how many jobs run right now
```

It takes effect on the next job, with no restart and no admin password. The level is stored in
`/Users/Shared/rdocker/share` (one word; delete the file = max).

## Install (once, as yourself)

```sh
sudo install -m 755 rdocker-share.sh /usr/local/bin/rdocker-share   # or any dir on your PATH
```

Optional menu-bar toggle: install [SwiftBar](https://swiftbar.app) (or xbar), then copy
`rdocker-share.1m.sh` into its plugin folder and `chmod +x` it. The menu shows the level and has
Off / Some / Max items. The plugin finds the command next to itself or at `/usr/local/bin/rdocker-share`.

Nothing is installed for you; both scripts are plain shell and touch only the share file.
