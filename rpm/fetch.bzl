"""Bazel rules for fetching RPM packages from Rocky Linux repositories."""

def _rpm_fetch_impl(ctx):
    """Implementation of rpm_fetch rule."""
    
    # Get the downloader script
    downloader = ctx.file._downloader
    
    # Output file
    rpm_file = ctx.actions.declare_file(ctx.attr.name + ".rpm")
    
    # Create a temporary directory for download
    # Then move the downloaded RPM to the output location
    ctx.actions.run_shell(
        outputs = [rpm_file],
        inputs = [downloader],
        command = """
            set -e
            TMPDIR=$(mktemp -d)
            python3 {downloader} {package} --repo {repo} --output "$TMPDIR"
            # Find the downloaded RPM and move it
            RPM=$(find "$TMPDIR" -name "*.rpm" | head -1)
            if [ -z "$RPM" ]; then
                echo "Error: No RPM file found" >&2
                exit 1
            fi
            mv "$RPM" {output}
            rm -rf "$TMPDIR"
        """.format(
            downloader = downloader.path,
            package = ctx.attr.package,
            repo = ctx.attr.repo,
            output = rpm_file.path,
        ),
        mnemonic = "FetchRPM",
        progress_message = "Fetching RPM: %s" % ctx.attr.package,
    )
    
    return [DefaultInfo(files = depset([rpm_file]))]

rpm_fetch = rule(
    implementation = _rpm_fetch_impl,
    attrs = {
        "package": attr.string(
            mandatory = True,
            doc = "Name of the RPM package to fetch",
        ),
        "repo": attr.string(
            default = "baseos",
            values = ["baseos", "appstream"],
            doc = "Rocky Linux repository to fetch from",
        ),
        "_downloader": attr.label(
            default = "//tools:rpm_downloader.py",
            allow_single_file = True,
        ),
    },
    doc = "Fetches an RPM package from Rocky Linux repositories",
)