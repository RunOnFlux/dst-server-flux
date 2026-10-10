"""Unit tests for scripts/fluxdst.py: the cluster written from the environment and flux/*.json.

Run by tests/test-flux.sh (python3 -m unittest). No server, no Steam: every test gets its own
temporary data and install folders through the FLUX_* variables, and the module is loaded fresh.
"""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "scripts", "fluxdst.py")
HAVE_LUA = shutil.which("lua5.1") is not None


def load(env):
    """fluxdst with exactly these variables (plus the temp folders) in its environment."""
    for k in [k for k in os.environ if k.startswith(("DST_", "FLUX_", "CLUSTER_", "MAX_PLAYERS", "GAME_ADMINS", "MOD_COLLECTION", "PVP"))]:
        del os.environ[k]
    os.environ.update(env)
    spec = importlib.util.spec_from_file_location("fluxdst_under_test", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.data = os.path.join(self.tmp, "data")
        self.server = os.path.join(self.tmp, "server")
        os.makedirs(os.path.join(self.server, "mods"))
        os.makedirs(self.data)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_cmd(self, env, *argv):
        env = {"FLUX_DATA_DIR": self.data, "FLUX_SERVER_DIR": self.server, **env}
        mod = load(env)
        out = StringIO()
        with redirect_stdout(out):
            rc = mod.main(list(argv))
        return rc, out.getvalue(), mod

    def read(self, *parts):
        with open(os.path.join(self.data, "Cluster_1", *parts)) as f:
            return f.read()

    def write(self, rel, text):
        path = os.path.join(self.data, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)


class Ini(Base):
    def test_edits_in_place_and_keeps_the_rest(self):
        mod = load({})
        ini = mod.Ini("; note\n[GAMEPLAY]\nmax_players = 6\n\n[NETWORK]\ncluster_name = A\n")
        ini.set("GAMEPLAY", "pvp", "true")
        ini.set("network", "CLUSTER_NAME", "B")
        ini.set("SHARD", "bind_ip", "127.0.0.1")
        self.assertEqual(ini.text(), "; note\n[GAMEPLAY]\nmax_players = 6\npvp = true\n\n[NETWORK]\ncluster_name = B\n\n[SHARD]\nbind_ip = 127.0.0.1\n")

    def test_duplicates_go_and_none_removes(self):
        mod = load({})
        ini = mod.Ini("[A]\nx = 1\nx = 2\ny = 3\n")
        ini.set("A", "x", "9")
        ini.set("A", "y", None)
        self.assertEqual(ini.text(), "[A]\nx = 9\n")

    def test_same_key_in_another_section_is_another_key(self):
        mod = load({})
        ini = mod.Ini("[STEAM]\nname = s\n[SHARD]\nname = Caves\n")
        self.assertEqual(ini.get("SHARD", "name"), "Caves")
        ini.set("SHARD", "name", None)
        self.assertEqual(ini.get("STEAM", "name"), "s")


class Apply(Base):
    def test_new_cluster(self):
        rc, out, _ = self.run_cmd({"DST_CLUSTER_TOKEN": "pds-g^KU_abcdefgh^1^xyzxyzxyzxyz", "DST_NAME": "Wilson's Camp",
                                   "DST_PASSWORD": "", "DST_MAX_PLAYERS": "8", "DST_PVP": "yes"}, "apply")
        self.assertEqual(rc, 0, out)
        ini = self.read("cluster.ini")
        for line in ("cluster_name = Wilson's Camp", "cluster_password =", "max_players = 8", "pvp = true",
                     "shard_enabled = true", "bind_ip = 127.0.0.1", "master_ip = 127.0.0.1", "master_port = 10888",
                     "console_enabled = true"):
            self.assertIn(line, ini)
        self.assertIn("server_port = 11000", self.read("Master", "server.ini"))
        caves = self.read("Caves", "server.ini")
        self.assertIn("server_port = 10999", caves)
        self.assertIn("is_master = false", caves)
        self.assertIn("name = Caves", caves)
        self.assertEqual(self.read("cluster_token.txt"), "pds-g^KU_abcdefgh^1^xyzxyzxyzxyz\n")
        self.assertEqual(oct(os.stat(os.path.join(self.data, "Cluster_1", "cluster_token.txt")).st_mode & 0o777), "0o600")
        self.assertNotIn("xyzxyz", out, "the token is never printed")

    def test_no_token_is_exit_3_unless_offline(self):
        rc, out, _ = self.run_cmd({}, "apply")
        self.assertEqual(rc, 3)
        self.assertIn("token: MISSING", out)
        rc, _, _ = self.run_cmd({"FLUX_OFFLINE": "true"}, "apply")
        self.assertEqual(rc, 0)
        self.assertIn("offline_cluster = true", self.read("cluster.ini"))

    def test_a_token_that_cannot_be_one_is_not_written(self):
        rc, out, _ = self.run_cmd({"DST_CLUSTER_TOKEN": "two words here and more text"}, "apply")
        self.assertEqual(rc, 3)
        self.assertIn("WARN", out)

    def test_invalid_values_keep_the_file(self):
        self.write("Cluster_1/cluster.ini", "[GAMEPLAY]\nmax_players = 6\n[NETWORK]\ncluster_intention = social\n")
        rc, out, _ = self.run_cmd({"FLUX_OFFLINE": "true", "DST_MAX_PLAYERS": "200", "DST_INTENTION": "chaos"}, "apply")
        ini = self.read("cluster.ini")
        self.assertIn("max_players = 6", ini)
        self.assertIn("cluster_intention = social", ini)
        self.assertEqual(out.count("WARN"), 2)

    def test_unset_variables_leave_the_owners_values(self):
        self.write("Cluster_1/cluster.ini", "[NETWORK]\ncluster_password = secret\ntick_rate = 30\n")
        self.run_cmd({"FLUX_OFFLINE": "true"}, "apply")
        ini = self.read("cluster.ini")
        self.assertIn("cluster_password = secret", ini)
        self.assertIn("tick_rate = 30", ini)

    def test_previous_image_variable_names(self):
        self.run_cmd({"CLUSTER_TOKEN": "pds-g^KU_abcdefgh^1^xyzxyzxyzxyz", "CLUSTER_NAME": "Old", "MAX_PLAYERS": "4", "CLUSTER_PW": "pw"}, "apply")
        ini = self.read("cluster.ini")
        self.assertIn("cluster_name = Old", ini)
        self.assertIn("max_players = 4", ini)
        self.assertIn("cluster_password = pw", ini)

    def test_caves_off(self):
        self.run_cmd({"FLUX_OFFLINE": "true", "DST_CAVES": "false"}, "apply")
        self.assertIn("shard_enabled = false", self.read("cluster.ini"))
        self.assertFalse(os.path.exists(os.path.join(self.data, "Cluster_1", "Caves")))

    def test_the_shared_cluster_key_is_replaced_once(self):
        self.write("Cluster_1/cluster.ini", "[SHARD]\ncluster_key = ThisIsTheSecretKeyForClusterCommunication\n")
        self.run_cmd({"FLUX_OFFLINE": "true"}, "apply")
        key = [l for l in self.read("cluster.ini").splitlines() if l.startswith("cluster_key")][0]
        self.assertNotIn("ThisIsTheSecret", key)
        self.run_cmd({"FLUX_OFFLINE": "true"}, "apply")
        self.assertIn(key, self.read("cluster.ini"))

    def test_admins(self):
        rc, out, _ = self.run_cmd({"FLUX_OFFLINE": "true", "DST_ADMINS": "KU_abcd1234, nope KU_efgh5678,KU_abcd1234"}, "apply")
        self.assertEqual(self.read("adminlist.txt"), "KU_abcd1234\nKU_efgh5678\n")
        self.assertIn("WARN DST_ADMINS: 'nope'", out)


class Worlds(Base):
    def test_unmanaged_caves_get_their_preset_only_once(self):
        self.run_cmd({"FLUX_OFFLINE": "true"}, "apply")
        self.assertIn('worldgen_preset = "DST_CAVE"', self.read("Caves", "worldgenoverride.lua"))
        self.assertFalse(os.path.exists(os.path.join(self.data, "Cluster_1", "Master", "worldgenoverride.lua")))
        self.write("Cluster_1/Caves/worldgenoverride.lua", "return { mine = true }\n")
        self.run_cmd({"FLUX_OFFLINE": "true"}, "apply")
        self.assertEqual(self.read("Caves", "worldgenoverride.lua"), "return { mine = true }\n")

    def test_playstyle_from_the_environment(self):
        self.run_cmd({"FLUX_OFFLINE": "true", "DST_PLAYSTYLE": "Lights Out"}, "apply")
        master = self.read("Master", "worldgenoverride.lua")
        self.assertIn('worldgen_preset = "LIGHTS_OUT"', master)
        self.assertIn('day = "onlynight"', master)
        self.assertIn("survival", [l.split("= ")[1] for l in self.read("cluster.ini").splitlines() if l.startswith("game_mode")])

    def test_world_json_wins_and_is_checked_against_the_catalog(self):
        self.write("flux/world-options.json", json.dumps({
            "forest": {"settings": [{"name": "hounds", "options": [{"data": "never"}, {"data": "often"}]}], "worldgen": []},
            "cave": {"settings": [{"name": "wormlights", "options": [{"data": "often"}]}], "worldgen": []}}))
        self.write("flux/world.json", json.dumps({"playstyle": "relaxed", "forest": {"hounds": "often", "bad": "x"}, "cave": {"wormlights": "often"}}))
        rc, out, _ = self.run_cmd({"FLUX_OFFLINE": "true", "DST_PLAYSTYLE": "survival"}, "apply")
        master = self.read("Master", "worldgenoverride.lua")
        self.assertIn('worldgen_preset = "RELAXED"', master)
        self.assertIn('hounds = "often"', master, "the owner's choice beats the play style's")
        self.assertNotIn("bad", master)
        caves = self.read("Caves", "worldgenoverride.lua")
        self.assertIn('wormlights = "often"', caves)
        self.assertNotIn("hunger", caves, "play style settings the caves do not have are left out")
        self.assertIn("bad = x is not an option", out)

    def test_set_world_validates(self):
        rc, out, _ = self.run_cmd({}, "set-world", json.dumps({"playstyle": "hard", "forest": {"a b": "c"}}))
        self.assertEqual(rc, 2)
        self.assertEqual(len(json.loads(out)["errors"]), 2)
        rc, out, _ = self.run_cmd({}, "set-world", json.dumps({"playstyle": "endless", "forest": {"hounds": "often", "pvp": True}}))
        self.assertEqual(rc, 0, out)
        with open(os.path.join(self.data, "flux", "world.json")) as f:
            self.assertEqual(json.load(f), {"playstyle": "endless", "forest": {"hounds": "often", "pvp": "true"}, "cave": {}})


class Mods(Base):
    def setup_lua(self):
        with open(os.path.join(self.server, "mods", "dedicated_server_mods_setup.lua")) as f:
            return f.read()

    def test_mods_json_writes_both_shards_and_the_downloads(self):
        self.write("flux/mods.json", json.dumps({"mods": [
            {"id": "378160973", "enabled": True, "options": {"SHOWPLAYERSOPTIONS": 3, "NAME": 'a "b"', "ON": False}},
            {"id": "workshop-1207269058", "enabled": False}]}))
        self.run_cmd({"FLUX_OFFLINE": "true", "DST_MODS": "362175979"}, "apply")
        mo = self.read("Master", "modoverrides.lua")
        self.assertIn('["workshop-378160973"] = { enabled = true, configuration_options = { ["SHOWPLAYERSOPTIONS"] = 3, ["NAME"] = "a \\"b\\"", ["ON"] = false } }', mo)
        self.assertIn('["workshop-1207269058"] = { enabled = false }', mo)
        self.assertIn('["workshop-362175979"] = { enabled = true }', mo)
        self.assertEqual(self.read("Caves", "modoverrides.lua"), mo)
        setup = self.setup_lua()
        for i in ("378160973", "1207269058", "362175979"):
            self.assertIn(f'ServerModSetup("{i}")', setup)

    def test_owners_file_is_kept_and_mirrored(self):
        self.write("Cluster_1/Master/modoverrides.lua", 'return { ["workshop-111"] = { enabled = true } }\n')
        self.run_cmd({"FLUX_OFFLINE": "true"}, "apply")
        self.assertEqual(self.read("Master", "modoverrides.lua"), 'return { ["workshop-111"] = { enabled = true } }\n')
        self.assertEqual(self.read("Caves", "modoverrides.lua"), 'return { ["workshop-111"] = { enabled = true } }\n')
        self.assertIn('ServerModSetup("111")', self.setup_lua())

    def test_ids_from_links_and_bad_ids(self):
        mod = load({})
        out = StringIO()
        with redirect_stdout(out):
            ids = mod.split_ids("https://steamcommunity.com/sharedfiles/filedetails/?id=378160973, workshop-42 nope", "DST_MODS")
        self.assertEqual(ids, ["378160973", "42"])
        self.assertIn("'nope'", out.getvalue())

    def test_set_mods_validates(self):
        rc, out, _ = self.run_cmd({}, "set-mods", json.dumps({"mods": [{"id": "abc"}], "collection": "x"}))
        self.assertEqual(rc, 2)
        self.assertEqual(len(json.loads(out)["errors"]), 2)
        rc, out, _ = self.run_cmd({}, "set-mods", json.dumps({"mods": [{"id": "1", "enabled": False}, {"id": "1"}]}))
        self.assertEqual(rc, 0)
        with open(os.path.join(self.data, "flux", "mods.json")) as f:
            self.assertEqual(json.load(f)["mods"], [{"id": "1", "enabled": False, "options": {}}])

    def test_lua_strings(self):
        mod = load({})
        self.assertEqual(mod.lua_value({"a": [1, "x\n\x01"]}), '{ ["a"] = { 1, "x\\n\\001" } }')


class Migrate(Base):
    def test_previous_image_layout(self):
        self.write("My Server/cluster.ini", "[NETWORK]\ncluster_name = My Server\n")
        self.write("My Server/Master/save/x", "world")
        self.write("dst_server/bin64/dontstarve", "")
        rc, out, _ = self.run_cmd({}, "migrate")
        self.assertEqual(sorted(os.listdir(self.data)), ["Cluster_1"])
        self.assertEqual(self.read("Master", "save", "x"), "world")

    def test_a_current_cluster_is_never_replaced(self):
        self.write("Cluster_1/cluster.ini", "[NETWORK]\n")
        self.write("Other/cluster.ini", "[NETWORK]\n")
        self.run_cmd({}, "migrate")
        self.assertTrue(os.path.exists(os.path.join(self.data, "Other", "cluster.ini")))

    def test_a_folder_that_is_not_the_game_is_not_deleted(self):
        self.write("dst_server/notes.txt", "mine")
        self.run_cmd({}, "migrate")
        self.assertTrue(os.path.exists(os.path.join(self.data, "dst_server", "notes.txt")))


class KleiJson(Base):
    def test_apostrophe_escape(self):
        mod = load({})
        self.assertEqual(mod.klei_json('{"a":"Winter\\\'s","b":"x\\\\","c":"\\\\\'"}'), {"a": "Winter's", "b": "x\\", "c": "\\'"})


@unittest.skipUnless(HAVE_LUA, "lua5.1 is not installed here (the image test covers it)")
class Lua(Base):
    def lua(self, *args):
        out = subprocess.run(["lua5.1", os.path.join(HERE, "..", "scripts", "flux-lua.lua"), *args], capture_output=True, text=True)
        return out.returncode, json.loads(out.stdout)

    def test_modinfo(self):
        path = os.path.join(HERE, "fixtures", "modinfo.lua")
        rc, data = self.lua("modinfo", path, "workshop-1")
        self.assertEqual(rc, 0, data)
        self.assertEqual(data["name"], "Test Mod")
        self.assertEqual(data["configuration_options"][0]["options"][1], {"description": "Hide", "data": False})

    def test_sandbox(self):
        path = os.path.join(self.tmp, "evil.lua")
        with open(path, "w") as f:
            f.write("os.execute('touch /tmp/pwned') return {}")
        rc, data = self.lua("table", path)
        self.assertEqual(rc, 1)
        self.assertIn("os", data["error"])

    def test_klei_header(self):
        path = os.path.join(self.tmp, "w.lua")
        with open(path, "w") as f:
            f.write('KLEI     1 return { overrides = { hounds = "often" } }')
        self.assertEqual(self.lua("table", path), (0, {"overrides": {"hounds": "often"}}))


if __name__ == "__main__":
    unittest.main()
