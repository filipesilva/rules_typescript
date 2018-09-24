# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"Simple development server"

load(
    "@build_bazel_rules_nodejs//internal:node.bzl",
    "sources_aspect",
)
load(
    "@build_bazel_rules_nodejs//internal/js_library:js_library.bzl",
    "write_amd_names_shim",
)

def _ts_devserver(ctx):
    files = depset()
    for d in ctx.attr.deps:
        if hasattr(d, "node_sources"):
            files = depset(transitive = [files, d.node_sources])
        elif hasattr(d, "files"):
            files = depset(transitive = [files, d.files])

    if ctx.label.workspace_root:
        # We need the workspace_name for the target being visited.
        # Skylark doesn't have this - instead they have a workspace_root
        # which looks like "external/repo_name" - so grab the second path segment.
        # TODO(alexeagle): investigate a better way to get the workspace name
        workspace_name = ctx.label.workspace_root.split("/")[1]
    else:
        workspace_name = ctx.workspace_name

    # Create a manifest file with the sources in arbitrary order, and without
    # bazel-bin prefixes ("root-relative paths").
    # TODO(alexeagle): we should experiment with keeping the files toposorted, to
    # see if we can get performance gains out of the module loader.
    ctx.actions.write(ctx.outputs.manifest, "".join([
        workspace_name + "/" + f.short_path + "\n"
        for f in files.to_list()
    ]))

    amd_names_shim = ctx.actions.declare_file(
        "_%s.amd_names_shim.js" % ctx.label.name,
        sibling = ctx.outputs.script,
    )
    write_amd_names_shim(ctx.actions, amd_names_shim, ctx.attr.bootstrap)

    # Requirejs is always needed so its included as the first script
    # in script_files before any user specified scripts for the devserver
    # to concat in order.
    script_files = []
    script_files.extend(ctx.files.bootstrap)
    script_files.append(ctx.file._requirejs_script)
    script_files.append(amd_names_shim)
    script_files.extend(ctx.files.scripts)
    ctx.actions.write(ctx.outputs.scripts_manifest, "".join([
        workspace_name + "/" + f.short_path + "\n"
        for f in script_files
    ]))

    devserver_runfiles = [
        ctx.executable._devserver,
        ctx.outputs.manifest,
        ctx.outputs.scripts_manifest,
    ]
    devserver_runfiles += ctx.files.static_files
    devserver_runfiles += script_files

    serving_arg = ""
    if ctx.attr.serving_path:
        serving_arg = "-serving_path=%s" % ctx.attr.serving_path

    packages = depset(["/".join([workspace_name, ctx.label.package])] + ctx.attr.additional_root_paths)

    # Avoid writing non-normalized paths (workspace/../other_workspace/path)
    if ctx.executable._devserver.short_path.startswith("../"):
      script_path = ctx.executable._devserver.short_path[len("../"):]
    else:
      script_path = "/".join([
          ctx.workspace_name,
          ctx.executable._devserver.short_path,
      ])

    substitutions = {
        "TEMPLATED_main": script_path,
        "TEMPLATED_serving_arg": serving_arg,
        "TEMPLATED_workspace": workspace_name,
        "TEMPLATED_packages": ",".join(packages.to_list()),
        "TEMPLATED_manifest": ctx.outputs.manifest.short_path,
        "TEMPLATED_scripts_manifest": ctx.outputs.scripts_manifest.short_path,
        "TEMPLATED_entry_module": ctx.attr.entry_module,
        "TEMPLATED_port": str(ctx.attr.port),
    }
    ctx.actions.expand_template(
        template=ctx.file._launcher_template,
        output=ctx.outputs.script,
        substitutions=substitutions,
        is_executable=False,
    )

    return [DefaultInfo(
        executable = ctx.outputs.script,
        runfiles = ctx.runfiles(
            files = devserver_runfiles,
            # We don't expect executable targets to depend on the devserver, but if they do,
            # they can see the JavaScript code.
            transitive_files = depset(ctx.files.data, transitive = [files]),
            collect_data = True,
            collect_default = True,
        ),
    )]

ts_devserver = rule(
    implementation = _ts_devserver,
    attrs = {
        "deps": attr.label_list(
            doc = "Targets that produce JavaScript, such as `ts_library`",
            allow_files = True,
            aspects = [sources_aspect],
        ),
        "serving_path": attr.string(
            doc = """The path you can request from the client HTML which serves the JavaScript bundle.
            If you don't specify one, the JavaScript can be loaded at /_/ts_scripts.js""",
        ),
        "data": attr.label_list(
            doc = "Dependencies that can be require'd while the server is running",
            allow_files = True,
        ),
        "static_files": attr.label_list(
            doc = """Arbitrary files which to be served, such as index.html.
            They are served relative to the package where this rule is declared.""",
            allow_files = True,
        ),
        "scripts": attr.label_list(
            doc = "User scripts to include in the JS bundle before the application sources",
            allow_files = [".js"],
        ),
        "entry_module": attr.string(
            doc = """The entry_module should be the AMD module name of the entry module such as `"__main__/src/index"`
            ts_devserver concats the following snippet after the bundle to load the application:
            `require(["entry_module"]);`
            """,
        ),
        "bootstrap": attr.label_list(
            doc = "Scripts to include in the JS bundle before the module loader (require.js)",
            allow_files = [".js"],
        ),
        "additional_root_paths": attr.string_list(
            doc = """Additional root paths to serve static_files from.
            Paths should include the workspace name such as [\"__main__/resources\"]
            """,
        ),
        "port": attr.int(
            doc = """The port that the devserver will listen on.""",
            default = 5432,
        ),
        "_requirejs_script": attr.label(allow_single_file = True, default = Label("@build_bazel_rules_typescript_devserver_deps//node_modules/requirejs:require.js")),
        "_devserver": attr.label(
            default = Label("//devserver"),
            executable = True,
            cfg = "host",
        ),
        "_launcher_template": attr.label(
            default = Label("//internal/devserver:devserver_launcher.sh"),
            allow_files = True,
            single_file = True
        ),        
    },
    outputs = {
        "manifest": "%{name}.MF",
        "scripts_manifest": "scripts_%{name}.MF",
        "script": "%{name}.sh",
    },
    executable = True,
)
"""ts_devserver is a simple development server intended for a quick "getting started" experience.

Additional documentation at https://github.com/alexeagle/angular-bazel-example/wiki/Running-a-devserver-under-Bazel
"""

def ts_devserver_macro(name, data=[], args=[], visibility=None, tags=[], testonly=0, **kwargs):
    """ibazel wrapper for `ts_devserver`

    This macro re-exposes the `ts_devserver` rule with some extra tags so that
    it behaves correctly under ibazel.

    This is re-exported in `//:defs.bzl` as `ts_devserver` so if you load the rule
    from there, you actually get this macro.

    Args:
      tags: standard Bazel tags, this macro adds a couple for ibazel
      **kwargs: passed through to `ts_devserver`
    """
    ts_devserver(
        name = "%s_bin" % name,
        data = data + ["@bazel_tools//tools/bash/runfiles"],
        testonly = testonly,
        visibility = ["//visibility:private"],
        # Users don't need to know that these tags are required to run under ibazel
        tags = tags + [
            # Tell ibazel not to restart the devserver when its deps change.
            "ibazel_notify_changes",
            # Tell ibazel to serve the live reload script, since we expect a browser will connect to
            # this program.
            "ibazel_live_reload",
        ],      
      **kwargs
    )

    native.sh_binary(
        name = name,
        args = args,
        tags = tags,
        srcs = [":%s_bin.sh" % name],
        data = [":%s_bin" % name],
        testonly = testonly,
        visibility = visibility,
    )
