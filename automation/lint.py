"""Run Ansible lint with project module_utils available to argument inspection."""

import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
os.environ["ANSIBLE_HOME"] = str(ROOT / ".cache/ansible-home")
os.environ["ANSIBLE_LOCAL_TEMP"] = str(ROOT / ".cache/ansible/tmp")
os.environ["XDG_CACHE_HOME"] = str(ROOT / ".cache")
import ansible.module_utils

ansible.module_utils.__path__.append(str(ROOT / "ansible/module_utils"))
from ansiblelint.__main__ import main

if __name__ == "__main__":
    sys.exit(main(["--offline", "ansible/workshop.yml"]))
