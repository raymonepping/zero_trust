import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "automation"))
from common import WorkshopError, lock


class Result(Exception):
    def __init__(self, data, failed=False):
        self.data = data
        self.failed = failed


class FakeModule:
    def __init__(self, params, check=False):
        self.params = params
        self.check_mode = check

    def exit_json(self, **data):
        raise Result(data)

    def fail_json(self, **data):
        raise Result(data, True)


def load(name):
    spec = importlib.util.spec_from_file_location(
        "ansible.module_utils.zt_http", ROOT / "ansible/module_utils/zt_http.py"
    )
    util = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(util)
    sys.modules["ansible.module_utils.zt_http"] = util
    spec = importlib.util.spec_from_file_location(
        name, ROOT / "ansible/library" / f"{name}.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Safety(unittest.TestCase):
    def test_connector_preserves_manual_solution(self):
        mod = load("zt_connector")
        with tempfile.TemporaryDirectory() as tmp:
            build = Path(tmp) / "build"
            (build / "backend").mkdir(parents=True)
            connector = build / "backend/connector.js"
            connector.write_text("manual learner solution")
            params = dict(
                root=str(ROOT),
                build=str(build),
                private=tmp + "/private",
                connector="env",
                overwrite=False,
            )
            with patch.object(
                mod, "AnsibleModule", return_value=FakeModule(params)
            ), self.assertRaises(Result) as result:
                mod.main()
            self.assertTrue(result.exception.failed)
            self.assertEqual(connector.read_text(), "manual learner solution")
            params["overwrite"] = True
            with patch.object(
                mod, "AnsibleModule", return_value=FakeModule(params)
            ), self.assertRaises(Result) as result:
                mod.main()
            self.assertFalse(result.exception.failed)
            backups = list((Path(tmp) / "private/learner-backups").glob("*.js"))
            self.assertEqual(backups[0].read_text(), "manual learner solution")

    def test_initialized_vault_missing_custody_never_initializes(self):
        mod = load("zt_bootstrap")
        with tempfile.TemporaryDirectory() as tmp:
            params = dict(address="http://test", private=tmp, unseal_only=False)
            calls = []

            def request(*args, **kwargs):
                calls.append(args[1])
                return 200, {"initialized": True, "sealed": True}

            with patch.object(
                mod, "AnsibleModule", return_value=FakeModule(params)
            ), patch.object(mod, "request", side_effect=request), self.assertRaises(
                Result
            ) as result:
                mod.main()
            self.assertTrue(result.exception.failed)
            self.assertNotIn("v1/sys/init", calls)

    def test_transition_rejects_backward_structure(self):
        mod = load("zt_transition")
        with tempfile.TemporaryDirectory() as tmp:
            private = Path(tmp) / "private"
            (private / "terraform").mkdir(parents=True)
            (private / "terraform/terraform.tfstate").write_text(
                json.dumps({"outputs": {"contract": {"value": {"level": 8}}}})
            )
            params = dict(
                root=str(ROOT),
                build=tmp + "/build",
                private=str(private),
                action="resolve",
                lab="03",
                overwrite=False,
            )
            with patch.object(
                mod, "AnsibleModule", return_value=FakeModule(params)
            ), self.assertRaises(Result) as result:
                mod.main()
            self.assertTrue(result.exception.failed)

    def test_mutation_lock_excludes_duplicate_target(self):
        with lock("test-runtime", "test-project"):
            with self.assertRaises(WorkshopError):
                with lock("test-runtime", "test-project"):
                    pass

    def test_verify_has_no_configuration_dispatch(self):
        import verify

        with tempfile.TemporaryDirectory() as tmp:
            cfg = dict(
                zt_build=tmp,
                zt_private=tmp,
                zt_lab="01",
                zt_digest="test",
                zt_target="runtime",
                zt_port_base=24000,
                zt_manifest=json.loads((ROOT / "labs/manifest.yml").read_text()),
            )
            responses = [
                (200, {"db": "connected"}),
                (200, {"source": "static-config"}),
                (200, [{"id": 1}]),
            ]
            with patch.object(verify, "http", side_effect=responses), patch.object(
                verify, "run"
            ) as executor:
                verify.verify(cfg)
                executor.assert_not_called()
            self.assertEqual(
                json.loads((Path(tmp) / "verification.json").read_text())["result"],
                "passed",
            )

    def test_failed_verify_invalidates_old_success(self):
        import verify

        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp) / "verification.json"
            file.write_text('{"result":"passed"}')
            cfg = dict(
                zt_build=tmp,
                zt_private=tmp,
                zt_lab="01",
                zt_digest="test",
                zt_target="runtime",
                zt_port_base=24000,
                zt_manifest=json.loads((ROOT / "labs/manifest.yml").read_text()),
            )
            with patch.object(
                verify, "http", return_value=(503, {})
            ), self.assertRaises(WorkshopError):
                verify.verify(cfg)
            self.assertEqual(json.loads(file.read_text())["result"], "failed")


if __name__ == "__main__":
    unittest.main()


class License(unittest.TestCase):
    def test_dotenv_license_is_literal_and_never_shell_evaluated(self):
        module = load("zt_license")
        self.assertEqual(
            module.dotenv_license('OTHER=private\nVAULT_LICENSE="example-only"\n'),
            "example-only",
        )
        self.assertEqual(
            module.dotenv_license("export VAULT_LICENSE='literal-$(command)'\n"),
            "literal-$(command)",
        )
        self.assertEqual(module.dotenv_license('VAULT_LICENSE=""\n'), "")


class Ownership(unittest.TestCase):
    def test_terraform_has_no_secret_value_resources_or_provisioners(self):
        text = "\n".join(
            p.read_text() for p in (ROOT / "terraform/workshop").glob("*.tf")
        )
        for forbidden in [
            "vault_generic_secret",
            "vault_kv_secret",
            "vault_token",
            "local-exec",
            "remote-exec",
            "ignore_changes",
            "secret_id",
        ]:
            self.assertNotIn(forbidden, text)

    def test_new_playbook_never_executes_legacy_setup_scripts(self):
        text = "\n".join(p.read_text() for p in (ROOT / "ansible").rglob("*.yml"))
        for forbidden in [
            "scripts/setup_",
            "scripts/seed_db.sh",
            "scripts/switch_connector.sh",
            "scripts/unseal_vault.sh",
        ]:
            self.assertNotIn(forbidden, text)

    def test_license_delivery_matches_reference_environment_approach(self):
        compose = (ROOT / "ansible/templates/compose.yml.j2").read_text()
        self.assertIn("VAULT_LICENSE: '${VAULT_LICENSE:-}'", compose)
        self.assertNotIn("vault_v2.hclic", compose)
        self.assertNotIn(
            "license_path", (ROOT / "ansible/templates/vault.hcl.j2").read_text()
        )

    def test_required_manual_lab_links_exist(self):
        for row in json.loads((ROOT / "labs/manifest.yml").read_text())["labs"]:
            self.assertTrue((ROOT / "labs" / f"{row['id']}.md").is_file())


class ComposeDiagnostics(unittest.TestCase):
    def test_failure_text_is_useful_and_masks_environment_values(self):
        mod = load("zt_compose")
        with tempfile.TemporaryDirectory() as tmp:
            env = Path(tmp) / "x.env"
            env.write_text(
                "VAULT_LICENSE=abc-license-value\nVAULT_IMAGE=docker.io/a/b:1\n"
            )
            text = (
                "couldn't find env file: /work/config/defaults.env\n"
                "pull docker.io/a/b:1 failed\nlicense abc-license-value\n"
                "EXTRA_TOKEN=plain hvs.ABCDEF\n" + "Z" * 50
            )
            out = mod.safe_output(text, [str(env), tmp + "/absent.env"])
        self.assertIn("/work/config/defaults.env", out)
        self.assertIn("docker.io/a/b:1", out)
        for secret in ["abc-license-value", "plain", "hvs.ABCDEF", "Z" * 50]:
            self.assertNotIn(secret, out)

    def test_missing_env_files_are_named(self):
        import cli

        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(len(cli.missing_inputs(Path(tmp))), 2)
            (Path(tmp) / ".env").write_text("")
            self.assertIn("config/defaults.env", cli.missing_inputs(Path(tmp))[0])


class Fixtures(unittest.TestCase):
    def test_seed_data_is_complete_and_uses_fictional_people(self):
        root = ROOT / "data/fixtures"
        users = json.loads((root / "users.json").read_text())
        activity = json.loads((root / "activity.json").read_text())
        self.assertGreaterEqual(len(users), 6)
        self.assertEqual(
            {x["classification"] for x in activity["orders"]},
            {"public", "internal", "confidential", "restricted"},
        )
        ids = {x["id"] for x in users}
        self.assertTrue({x["user_id"] for x in activity["orders"]} <= ids)
        text = "".join(p.read_text() for p in root.glob("*.json"))
        for name in ["Epping", "Duncan", "Cojan", "Ballegooijen"]:
            self.assertNotIn(name, text)

    def test_legacy_connectors_are_not_lab_references(self):
        manifest = json.loads((ROOT / "labs/manifest.yml").read_text())
        used = {x["connector"] for x in manifest["labs"]}
        self.assertNotIn("approle", used)
        self.assertNotIn("agent-dynamic", used)
        self.assertIn(
            "database/creds", (ROOT / "data/connector.approle.js").read_text()
        )


class Progression(unittest.TestCase):
    def test_up_resumes_the_reference_stage(self):
        mod = load("zt_transition")
        with tempfile.TemporaryDirectory() as tmp:
            build = Path(tmp) / "build"
            (build / "backend").mkdir(parents=True)
            (build / "backend/connector.js").write_bytes(
                (ROOT / "data/connector.lab-approle.js").read_bytes()
            )
            params = dict(
                root=str(ROOT),
                build=str(build),
                private=tmp + "/private",
                action="up",
                lab="",
                overwrite=False,
            )
            with patch.object(
                mod, "AnsibleModule", return_value=FakeModule(params)
            ), self.assertRaises(Result) as result:
                mod.main()
            self.assertFalse(result.exception.failed)
            self.assertEqual(result.exception.data["level"], 4)

    def test_prepare_preserves_a_verified_previous_manual_solution(self):
        import cli
        import verify
        import contextlib
        import os

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            private = root / ".secrets/test"
            private.mkdir(parents=True)
            (private / "compose.yml").write_text("existing project")
            learner = root / ".build/test/backend/connector.js"
            learner.parent.mkdir(parents=True)
            learner.write_text("a manually completed previous exercise")
            with patch.object(cli, "ROOT", root), patch.object(
                cli,
                "manifest",
                return_value=json.loads((ROOT / "labs/manifest.yml").read_text()),
            ), patch.object(
                cli,
                "discover",
                return_value={
                    "engine": "docker",
                    "compose": ["docker-compose"],
                    "identity": "test",
                },
            ), patch.object(
                cli, "digest", return_value="digest"
            ), patch.object(
                cli, "run", return_value="revision"
            ), patch.object(
                cli, "lock", return_value=contextlib.nullcontext()
            ), patch.object(
                cli, "prepare_existing"
            ) as reconcile, patch.object(
                verify, "verify"
            ) as grader, patch.dict(
                os.environ,
                {"INSTANCE": "test", "PORT_BASE": "24000", "RUNTIME": "docker"},
            ):
                cli.main(["--goals", "prepare", "--lab", "05"])
                reconcile.assert_not_called()
                self.assertEqual(grader.call_args.args[0]["zt_lab"], "04")
            self.assertEqual(
                learner.read_text(), "a manually completed previous exercise"
            )
            self.assertEqual(
                json.loads((root / ".build/test/prepared.json").read_text())["lab"],
                "05",
            )


class SQLComparison(unittest.TestCase):
    def test_sql_whitespace_normalization_preserves_literals(self):
        module = load("zt_vault")
        self.assertEqual(
            module.canonical_sql('GRANT  SELECT\n ON users TO "db-role";'),
            'GRANT SELECT ON users TO "db-role";',
        )
        self.assertNotEqual(
            module.canonical_sql("SELECT 'two  spaces'"),
            module.canonical_sql("SELECT 'two spaces'"),
        )
        self.assertNotEqual(
            module.canonical_sql('SELECT "two  spaces"'),
            module.canonical_sql('SELECT "two spaces"'),
        )


class BootstrapBoundary(unittest.TestCase):
    def test_tune_metadata_permissions_are_read_only(self):
        module = load("zt_bootstrap")
        for line in module.TF_POLICY.splitlines():
            if '/tune"' in line:
                self.assertIn('["read"]', line)
                self.assertNotIn("sudo", line)
                self.assertNotIn("update", line)
