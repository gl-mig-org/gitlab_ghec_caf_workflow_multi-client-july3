## Contributing

[fork]: https://github.com/github/gl-exporter/fork
[pr]: https://github.com/github/gl-exporter/compare
[style]: https://github.com/styleguide/ruby
[code-of-conduct]: CODE_OF_CONDUCT.md

Hi there! We're thrilled that you'd like to contribute to this project. Your help is essential for keeping it great.

Please note that this project is released with a [Contributor Code of Conduct][code-of-conduct]. By participating in this project you agree to abide by its terms.

## Submitting an issue

Thanks for bringing up issues to our attention! We value your feedback and would love to hear about any bugs you may encounter or features you'd like to see developed. Feel free to open an [issue](https://github.com/github/gl-exporter/issues) and update the pre-populated issue template with the relevant details of the issue.

**DISCLOSURE**: Please note that other GitLab Exporter users will be using this repository. This project will also be publicly distributed as an open source project in the near future. Please do not disclose sensitive information about your migration as you open any issues. Instead, please email sensitive information to services@github.com.

## Submitting a pull request

0. [Fork][fork] and clone the repository
0. Configure and install the dependencies: `script/bootstrap`
0. Make sure the tests pass on your machine: `rspec`
0. Create a new branch: `git checkout -b my-branch-name`
0. Make your change, add tests, and make sure the tests still pass
0. Push to your fork and [submit a pull request][pr]
0. Pat your self on the back and wait for your pull request to be reviewed and merged.

Here are a few things you can do that will increase the likelihood of your pull request being accepted:

- Follow the [style guide][style].
- Write tests.
- Keep your change as focused as possible. If there are multiple changes you would like to make that are not dependent upon each other, consider submitting them as separate pull requests.
- Write a [good commit message](http://tbaggery.com/2008/04/19/a-note-about-git-commit-messages.html).

## Cutting a Release branch
---

### 1. Prepare Version Bump PR
Update version references and open a PR:

**`lib/gl_exporter/version.rb`**
```ruby
- VERSION = "1.7.9".freeze
+ VERSION = "1.7.10".freeze
```

**`Gemfile.lock`**
```diff
- gl_exporter (1.7.9)
+ gl_exporter (1.7.10)
```

---

### 2. Create and Push Release Tag
After merging the version bump PR into `master`:

```bash
git checkout master
git pull origin master
git tag v1.7.10
git push origin v1.7.10
```

---

### 3. Publish Draft Release
1. Once the tag is pushed, go to [GitHub Releases](https://github.com/github/gl-exporter/releases).
2. Create a **new draft release** with the new tag, e.g. `v1.7.10`.
3. Add release notes (summary of changes).
4. Save as draft until functional test passes.

---

### 4. Run Functional Test
Verify the new version works against GitLab:

```bash
export GITLAB_API_ENDPOINT=https://gitlab.com/api/v4
export GITLAB_USERNAME=username
export GITLAB_API_PRIVATE_TOKEN=abc123
export GITLAB_NAMESPACE=
export GITLAB_PROJECT=repo1

versions=(v1.7.9 v1.7.10)

# Build Docker images
for version in "${versions[@]}"; do
  git checkout $version
  docker build --tag gl-exporter:$version .
done

# Run export with both versions
for version in "${versions[@]}"; do
  docker run --rm     --env GITLAB_API_ENDPOINT     --env GITLAB_USERNAME     --env GITLAB_API_PRIVATE_TOKEN     --volume $(pwd)/shared:/shared     gl-exporter:$version     gl_exporter --namespace $GITLAB_NAMESPACE --project $GITLAB_PROJECT     --out-file /shared/$GITLAB_PROJECT-$version.tar.gz
done

# Extract archives
for version in "${versions[@]}"; do
  mkdir shared/$GITLAB_PROJECT-$version
  tar -zxf shared/$GITLAB_PROJECT-$version.tar.gz -C shared/$GITLAB_PROJECT-$version
done

# Compare logs
diff -r shared/repo1-v1.7.9/log/gl-exporter.log shared/repo1-v1.7.10/log/gl-exporter.log
```

✅ Expected: Only timestamp differences in logs and JSON output.

---

### 5. Upload Release Artifacts
1. Package the tarball (`.tar.gz`) and zip (`.zip`).
2. Upload them to [Google Drive - GitLab Exporter](https://drive.google.com/drive/u/0/folders/15K-FD7sKq0yMabFOMbj2y8IOFHBhxZRx).
   Place them alongside previous versions.
---

### 6. Finalize Release
- Publish the GitHub release.
- Announce in the team channel with the release notes and link to the artifacts.

## Resources

- [How to Contribute to Open Source](https://opensource.guide/how-to-contribute/)
- [Using Pull Requests](https://help.github.com/articles/about-pull-requests/)
- [GitHub Help](https://help.github.com)
