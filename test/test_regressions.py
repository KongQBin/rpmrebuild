#!/usr/bin/env python3
"""Self-contained regression checks: python3 test/test_regressions.py.

Shell checks need Bash; integration checks additionally need rpm, rpmbuild and
rpm2cpio/cpio. Fixtures and build outputs are confined to a temporary directory.
"""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SRC = REPO / "src"


class RegressionBase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rpmrebuild-regression-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = os.environ.copy()
        self.env.update(LANG="en", RPMREBUILD_BUGREPORT=str(self.root / "bugreport"))
        self.env.pop("FORCE_ARCH", None)
        self.env.pop("RPMREBUILD_OPTS", None)
        self.env.pop("RPMREBUILD_ROOT_DIR", None)

    def run_command(self, args, *, input=None, expected=0, env=None):
        result = subprocess.run(args, input=input, env=env or self.env,
                                cwd=self.root, text=True, capture_output=True)
        if expected is not None:
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def shell(self, code, **kwargs):
        return self.run_command(["bash", "-c", code], **kwargs)

    def source(self, name):
        return "source " + shlex.quote(str(SRC / name)) + "\n"

    @staticmethod
    def record(path, *, file_type="-rw-r--r--", flags="", lang=""):
        return "\n".join([file_type, flags, "100644", "root", "root", "777",
                          lang, "(none)", str(path)]) + "\n"


class RegressionTests(RegressionBase):
    def test_missing_localized_file_is_preserved_in_rpm_mode(self):
        self.env.update(RPMREBUILD_package_flag="--package",
                        RPMREBUILD_COMMENT_MISSING="yes")
        result = self.run_command(["bash", str(SRC / "rpmrebuild_files.sh")],
                                  input=self.record(self.root / "missing", lang="fr"))
        self.assertTrue(result.stdout.startswith("%lang(fr)"), result.stdout)
        self.assertNotIn("# MISSING:", result.stdout)

    def test_installed_missing_file_can_still_be_commented(self):
        self.env.update(RPMREBUILD_package_flag="", RPMREBUILD_COMMENT_MISSING="yes")
        result = self.run_command(["bash", str(SRC / "rpmrebuild_files.sh")],
                                  input=self.record(self.root / "missing"))
        self.assertTrue(result.stdout.startswith("# MISSING:"), result.stdout)

    def test_filename_backslashes_quotes_and_whitespace(self):
        filename = str(self.root / 'back\\slash "quoted" ')  # preserve trailing space
        self.env.update(RPMREBUILD_package_flag="", RPMREBUILD_COMMENT_MISSING="yes")
        Path(filename).touch()
        result = self.run_command(["bash", str(SRC / "rpmrebuild_files.sh")],
                                  input=self.record(filename))
        escaped = filename.replace("\\", "\\\\").replace('"', '\\"')
        self.assertIn('"' + escaped + '"\n', result.stdout)
        self.assertNotIn("# MISSING:", result.stdout)

    def test_copy_keeps_dangling_symlink_and_raw_path(self):
        link = self.root / 'link\\name '
        link.symlink_to("missing-target")
        buildroot = self.root / "buildroot"
        self.run_command(["bash", str(SRC / "rpmrebuild_buildroot.sh"), str(buildroot)],
                         input=self.record(link, file_type="lrwxrwxrwx"))
        copied = buildroot / str(link).lstrip("/")
        self.assertTrue(copied.is_symlink())
        self.assertEqual(os.readlink(copied), "missing-target")

    def test_ghost_keeps_existing_dangling_symlink(self):
        buildroot = self.root / "buildroot"
        buildroot.mkdir()
        link = buildroot / "ghost"
        link.symlink_to(self.root / "outside")
        self.run_command(["bash", str(SRC / "rpmrebuild_ghost.sh"), str(buildroot)],
                         input=self.record("/ghost", flags="g"))
        self.assertTrue(link.is_symlink())
        self.assertFalse((self.root / "outside").exists())

    def test_query_failures_propagate(self):
        for function, setup in [("spec_provides", ""),
                                ("spec_requires", "TestAwk() { return 1; }"),
                                ("spec_requires", "TestAwk() { return 0; }; decode_requires() { cat; }"),
                                ("spec_preamble", "RELEASE_NEW=2")]:
            with self.subTest(function=function, setup=setup):
                self.shell(self.source("rpmrebuild_lib.src") + self.source("spec_func.src") +
                           "spec_query() { return 42; }\n" + setup + "\n" + function,
                           expected=42)

    def test_shellcheck_failure_propagates(self):
        mock = self.root / "shellcheck"
        mock.write_text("#!/bin/sh\nexit 17\n")
        mock.chmod(0o755)
        env = dict(self.env, PATH=str(self.root) + ":" + self.env["PATH"])
        self.run_command(["bash", str(SRC / "shellcheck.sh")], expected=17, env=env)

    def test_additional_flags_preserve_quoting_without_execution(self):
        text = '--define "message hello world" \'literal $(touch marker)\' "" a\\ b'
        code = self.source("rpmrebuild_lib.src")
        code += "ParseBuildArguments " + shlex.quote(text) + "\n"
        code += "printf '%s\\0' \"${RPMREBUILD_PARSED_ARGS[@]}\""
        result = self.shell(code)
        self.assertEqual(result.stdout.split("\0")[:-1],
                         ["--define", "message hello world", "literal $(touch marker)", "", "a b"])
        self.assertFalse((self.root / "marker").exists())
        for invalid in ['"unterminated', 'trailing\\']:
            self.shell(self.source("rpmrebuild_lib.src") +
                       "ParseBuildArguments " + shlex.quote(invalid), expected=1)

    def test_force_arch_rejects_shell_text_and_empty_value(self):
        for arch in ["", "x86_64; touch marker", "$(touch marker)", "x86_64 --showrc"]:
            with self.subTest(arch=arch):
                self.shell(self.source("rpmrebuild_lib.src") +
                           "FORCE_ARCH=" + shlex.quote(arch) + "\nValidateForceArch", expected=1)
        self.assertFalse((self.root / "marker").exists())

    def test_generated_processing_quotes_paths(self):
        # Exercise both direct concatenation and copying an already edited spec.
        for concatenated in ["no", "yes"]:
            with self.subTest(concatenated=concatenated):
                destination = self.root / ("output " + concatenated + "; touch marker; #.spec")
                spec = self.root / 'input "spec"'
                Path(str(spec) + ".1").write_text("fixture\n")
                processing = self.root / ("PROCESSING-" + concatenated)
                code = self.source("processing_func.src") + "\n".join([
                    "spec_concatenate() { printf 'fixture\\n'; }",
                    "spec_concatenated=" + concatenated,
                    "spec_index=1", "FIC_SPEC=" + shlex.quote(str(spec)),
                    "RPMREBUILD_specfile=" + shlex.quote(str(destination)),
                    "Output=" + shlex.quote(str(processing)),
                    "processing_fini", 'source "$Output"',
                ])
                self.shell(code)
                self.assertEqual(destination.read_text(), "fixture\n")
                self.assertFalse((self.root / "marker").exists())

    def test_change_files_uses_literal_buildroot(self):
        buildroot = str(self.root / 'work$(touch marker) "root"')
        self.env["EXPECTED_ROOT"] = buildroot
        processing = self.root / "PROCESSING"
        code = self.source("rpmrebuild_lib.src") + self.source("processing_func.src")
        code += "\n".join([
            "BUILDROOT=" + shlex.quote(buildroot),
            "RPMREBUILD_PROCESSING=" + shlex.quote(str(processing)),
            "LONG_OPTION=change-files",
            "OPTARG=" + shlex.quote('test "$RPM_BUILD_ROOT" = "$EXPECTED_ROOT"'),
            "CreateProcessing change-files", 'source "$RPMREBUILD_PROCESSING"',
        ])
        self.shell(code)
        self.assertFalse((self.root / "marker").exists())


@unittest.skipUnless(all(shutil.which(x) for x in ["rpm", "rpmbuild", "rpm2cpio", "cpio"]),
                     "RPM integration tools unavailable")
class IntegrationTests(RegressionBase):
    # Reuse helpers, without running the shell tests a second time.
    def setUp(self):
        super().setUp()
        self.top = self.root / "build"
        self.spec = self.root / "fixture.spec"
        self.spec.write_text("""Name: audit-rpmrebuild
Version: 1
Release: 1
Summary: regression fixture
License: MIT
BuildArch: x86_64
AutoReqProv: no
Provides: audit-custom = 7
Provides: audit-rpmrebuild(custom) = 9
%description
regression fixture
%install
mkdir -p %{buildroot}/opt/audit-rpmrebuild
printf 'hello\\n' > %{buildroot}/opt/audit-rpmrebuild/plain
printf 'bonjour\\n' > %{buildroot}/opt/audit-rpmrebuild/fr.txt
%files
/opt/audit-rpmrebuild/plain
%lang(fr) /opt/audit-rpmrebuild/fr.txt
""")
        self.run_command(["rpmbuild", "-bb", "--quiet", "--define", "_topdir " + str(self.top),
                          "--define", "_tmppath " + str(self.root / "tmp"), str(self.spec)])
        self.fixture = self.top / "RPMS/x86_64/audit-rpmrebuild-1-1.x86_64.rpm"

    def rebuild(self, *options, expected=0, env=None):
        env = dict(env or self.env)
        env.setdefault("RPMREBUILD_TMPDIR", str(self.root / "work"))
        return self.run_command(["bash", str(SRC / "rpmrebuild.sh"), "-b", "-p",
                                 "-d", str(self.root / "output"),
                                 "-D", "_tmppath " + str(self.root / "tmp"),
                                 *options, str(self.fixture)], expected=expected, env=env)

    def test_rebuild_content_and_architecture(self):
        for arch in ["x86_64", "noarch", "aarch64"]:
            with self.subTest(arch=arch):
                self.rebuild(*([] if arch == "x86_64" else ["--force-arch=" + arch]))
                output = self.root / ("output/" + arch + "/audit-rpmrebuild-1-1." + arch + ".rpm")
                files = self.run_command(["rpm", "-qpl", str(output)]).stdout.splitlines()
                self.assertEqual(files, ["/opt/audit-rpmrebuild/fr.txt", "/opt/audit-rpmrebuild/plain"])
                archive = subprocess.run(["rpm2cpio", str(output)], capture_output=True, env=self.env)
                self.assertEqual(archive.returncode, 0)
                payload = subprocess.run(["cpio", "--quiet", "-i", "--to-stdout",
                                          "./opt/audit-rpmrebuild/fr.txt"],
                                         input=archive.stdout, capture_output=True,
                                         cwd=self.root, env=self.env)
                self.assertEqual(payload.returncode, 0, payload.stderr)
                self.assertEqual(payload.stdout, b"bonjour\n")
                provides = self.run_command(["rpm", "-qp", "--provides", str(output)]).stdout
                self.assertIn("audit-custom = 7", provides)
                self.assertIn("audit-rpmrebuild(custom) = 9", provides)
                if arch != "x86_64":
                    self.assertNotIn("audit-rpmrebuild(x86-64)", provides)
                if arch == "aarch64":
                    self.assertIn("audit-rpmrebuild(aarch-64) = 1-1", provides)
                self.assertEqual(self.run_command(["rpm", "-qp", "--qf", "%{ARCH}", str(output)]).stdout, arch)

    def test_forced_arch_handles_epoch_and_foreign_source(self):
        self.spec.write_text(self.spec.read_text().replace("Version: 1", "Epoch: 3\nVersion: 1"))
        self.run_command(["rpmbuild", "-bb", "--quiet", "--define", "_topdir " + str(self.top),
                          "--define", "_tmppath " + str(self.root / "tmp"), str(self.spec)])
        self.rebuild("--force-arch=aarch64")
        foreign = self.root / "output/aarch64/audit-rpmrebuild-1-1.aarch64.rpm"
        provides = self.run_command(["rpm", "-qp", "--provides", str(foreign)]).stdout
        self.assertNotIn("audit-rpmrebuild(x86-64)", provides)
        self.assertIn("audit-rpmrebuild(aarch-64) = 3:1-1", provides)
        self.fixture = foreign
        self.rebuild("--force-arch=x86_64")
        native = self.root / "output/x86_64/audit-rpmrebuild-1-1.x86_64.rpm"
        provides = self.run_command(["rpm", "-qp", "--provides", str(native)]).stdout
        self.assertNotIn("audit-rpmrebuild(aarch-64)", provides)
        self.assertIn("audit-rpmrebuild(x86-64) = 3:1-1", provides)

    def test_spec_path_and_filter_with_space_in_workdir(self):
        destination = self.root / "output spec.spec"
        env = dict(self.env, RPMREBUILD_TMPDIR=str(self.root / "work with spaces"))
        args = ["bash", str(SRC / "rpmrebuild.sh"), "-b", "-p", "-s", str(destination),
                "--change-spec-description=cat", str(self.fixture)]
        self.run_command(args, env=env)
        self.assertIn("regression fixture", destination.read_text())
        self.assertFalse((self.root / "output").exists())

    def test_rebuild_with_spaces_in_workdir(self):
        self.rebuild(env=dict(self.env, RPMREBUILD_TMPDIR=str(self.root / "work with spaces")))

    def test_invalid_arch_from_cli_and_environment(self):
        self.rebuild("--force-arch=x86_64; touch marker", expected=1)
        self.rebuild("--force-arch=", expected=1)
        self.rebuild(env=dict(self.env, FORCE_ARCH="$(touch marker)"), expected=1)
        self.assertFalse((self.root / "marker").exists())

    def test_additional_and_define_keep_literal_arguments(self):
        self.rebuild("-a", "--define 'audit_message hello world'",
                     "-D", "audit_literal $(touch marker)")
        self.assertFalse((self.root / "marker").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
