# BRF-Tech Helm charts

A Helm repository for BRF-Tech products. Each chart is published here
automatically when its product releases.

## Use it

```bash
helm repo add brf-tech https://helm.brf.sh
helm repo update
helm search repo brf-tech
helm install filex brf-tech/filex --set ingress.host=files.example.com
```

The same charts are on the GitHub Container Registry as OCI artifacts, with
no `helm repo add` needed:

```bash
helm install filex oci://ghcr.io/brf-tech/charts/filex --set ingress.host=files.example.com
```

### Versions

A chart has its own version, separate from the version of the product it
installs (its `APP VERSION`). List both, then pin the one you want:

```bash
helm search repo brf-tech/filex --versions
helm install filex brf-tech/filex --version <chart version>
helm upgrade filex brf-tech/filex --version <chart version>
```

With OCI, `--version` takes the same chart version
(`helm install filex oci://ghcr.io/brf-tech/charts/filex --version <chart version>`).

### Values

```bash
helm show values brf-tech/filex             # every setting, with comments
helm pull brf-tech/filex --untar            # the whole chart, including example values files
```

## Charts

| Chart | Product | Install guide |
|---|---|---|
| `brf-tech/filex` | [filex](https://github.com/BRF-Tech/filex) - self-hosted file manager | [Kubernetes (Helm)](https://docs.filex.sh/INSTALLATION#kubernetes-helm) |

## Where the charts come from

This repository holds no chart sources. Each chart lives in its product's
repository (filex: [`deploy/helm/filex`](https://github.com/BRF-Tech/filex/tree/main/deploy/helm/filex)),
is versioned and reviewed there, and is released with the product. Report a
problem with a chart in that product's issue tracker.

[`products.yaml`](products.yaml) lists the products and where their charts
are. [`.github/workflows/publish.yml`](.github/workflows/publish.yml) runs
every ten minutes and publishes every release that has no chart here yet:

1. It lists the product repository's published releases (drafts and
   prereleases are skipped) whose tag matches the product's pattern and is
   not older than its `since`.
2. For each one missing from the index, oldest first, it checks out the tag,
   runs `helm lint`, packages the chart and pushes it to
   `oci://ghcr.io/brf-tech/charts`.
3. It merges the package into `index.yaml` on the
   [`gh-pages`](https://github.com/BRF-Tech/helm-charts/tree/gh-pages) branch
   and pushes it. `https://helm.brf.sh` serves that branch.
4. It checks the result the way a user would reach it: the index at the
   commit just pushed, the package next to it, an anonymous OCI pull.

A chart version is published once and never replaced. A release whose chart
reuses a published version with a different app version is refused, and the
run fails until the product repository bumps the chart version (or the tag is
listed under `skip`). Each product and each release is handled on its own, so
one failure does not hold up the rest.

Do not edit `gh-pages` by hand: the workflow owns it.

## Adding a product

1. Make sure the product's release tags carry the chart: each release bumps
   the chart's `version` in `Chart.yaml` (Helm treats a chart version as
   immutable) and sets `appVersion` to the release.
2. Add an entry to [`products.yaml`](products.yaml): the chart name, the
   source repository, the chart's path in it, the tag pattern and the oldest
   release to publish.
3. Run the workflow (Actions -> publish -> Run workflow), or wait for the next
   scheduled run.
4. After the first publish, check that the new OCI package is public. The
   workflow's first push creates it linked to this repository, and it takes
   the repository's visibility; if the verify step warns that an anonymous
   pull fails, open the package's page on GitHub -> Package settings -> Change
   visibility -> Public.
5. Add the chart to the tables in this README and in
   [`site/index.html`](site/index.html) (the page at https://helm.brf.sh).

### Publishing right after a release (optional)

The schedule publishes a release within about ten minutes. A product's release
workflow can make it immediate by sending a `repository_dispatch`, which needs
a token allowed to write to this repository (a fine-grained token with
**Contents: read and write** on `BRF-Tech/helm-charts`, stored as a secret in
the product repository):

```yaml
- name: Publish the Helm chart
  env:
    GH_TOKEN: ${{ secrets.HELM_CHARTS_DISPATCH_TOKEN }}
  run: gh api repos/BRF-Tech/helm-charts/dispatches -f event_type=product-released
```

## Running it by hand

`scripts/publish.sh` needs `bash`, `git`, `gh`, `helm`, `yq` (v4), `jq` and
`curl`. `DRY_RUN=1 scripts/publish.sh` packages and indexes into a local
`gh-pages` worktree (`./pages`) without pushing anything.

## License

[MIT](LICENSE) for the files in this repository. Each chart carries its
product's license.
