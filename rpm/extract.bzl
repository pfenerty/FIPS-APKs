"""Bazel rules for extracting RPM package contents."""

def _rpm_extract_impl(ctx):
    """Implementation of rpm_extract rule."""
    
    rpm_file = ctx.file.rpm
    extractor = ctx.file._extractor
    
    # Create output tar file
    output_tar = ctx.actions.declare_file(ctx.attr.name + ".tar")
    
    # Extract the RPM and create tar
    ctx.actions.run_shell(
        outputs = [output_tar],
        inputs = [rpm_file, extractor],
        command = """
            set -e
            TMPDIR=$(mktemp -d)
            OUTPUT=$(cd $(dirname {output}) && pwd)/$(basename {output})
            python3 {extractor} {rpm} --output "$TMPDIR" {filter_flag}
            cd "$TMPDIR"
            tar -cf "$OUTPUT" .
            cd /
            chmod -R u+w "$TMPDIR" 2>/dev/null || true
            rm -rf "$TMPDIR"
        """.format(
            extractor = extractor.path,
            rpm = rpm_file.path,
            output = output_tar.path,
            filter_flag = "" if ctx.attr.no_filter else "",
        ),
        mnemonic = "ExtractRPM",
        progress_message = "Extracting RPM: %s" % rpm_file.basename,
        execution_requirements = {"no-sandbox": "1"},
    )
    
    return [DefaultInfo(files = depset([output_tar]))]

rpm_extract = rule(
    implementation = _rpm_extract_impl,
    attrs = {
        "rpm": attr.label(
            mandatory = True,
            allow_single_file = [".rpm"],
            doc = "RPM file to extract",
        ),
        "no_filter": attr.bool(
            default = False,
            doc = "If True, don't filter out docs/man pages",
        ),
        "_extractor": attr.label(
            default = "//tools:rpm_extract.py",
            allow_single_file = True,
        ),
    },
    doc = "Extracts contents from an RPM package",
)