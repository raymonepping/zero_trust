#!/usr/bin/python
"""Field-scoped Keycloak REST reconciliation; password values are never read back."""

import json
from pathlib import Path
import time
import urllib.request
import urllib.parse
from ansible.module_utils.basic import AnsibleModule
from ansible.module_utils.zt_http import request, save, subset


def main():
    m = AnsibleModule(
        argument_spec=dict(
            address=dict(required=True),
            private=dict(required=True),
            features=dict(type="list", elements="str", required=True),
            frontend_port=dict(type="int", required=True),
        ),
        supports_check_mode=True,
    )
    p = m.params
    base = p["address"]
    changed = False
    if m.check_mode:
        m.exit_json(
            changed=False,
            skipped=True,
            msg="Keycloak check mode is incomplete; live reconciliation required",
        )
    try:
        body = urllib.parse.urlencode(
            dict(
                grant_type="password",
                client_id="admin-cli",
                username="admin",
                password="admin",
            )
        ).encode()
        for _ in range(120):
            try:
                req = urllib.request.Request(
                    base + "/realms/master/protocol/openid-connect/token", data=body
                )
                with urllib.request.urlopen(req, timeout=10) as r:
                    token = json.load(r)["access_token"]
                break
            except OSError:
                time.sleep(2)
        else:
            m.fail_json(msg="Keycloak admin login/readiness failed")
        headers = {"Authorization": "Bearer " + token}

        def api(path, method="GET", data=None):
            code, result = request(base, "admin/" + path, method, data, headers=headers)
            if code not in [200, 201, 204, 404]:
                m.fail_json(msg="Keycloak API operation failed", status=code)
            return code, result

        def ensure(path, desired):
            nonlocal changed
            code, actual = api(path)
            if code == 404 or not subset(actual, desired):
                if code == 404:
                    m.fail_json(msg="Missing Keycloak singleton object")
                api(path, "PUT", {**actual, **desired})
                changed = True
            return actual

        code, realm = api("realms/zero-trust")
        if code == 404:
            api(
                "realms",
                "POST",
                dict(realm="zero-trust", enabled=True, registrationAllowed=False),
            )
            changed = True
            _, realm = api("realms/zero-trust")
        prefix = "realms/zero-trust/"

        def collection(path, key, value, desired):
            nonlocal changed
            code, items = api(prefix + path)
            if code != 200:
                m.fail_json(msg="Keycloak collection read failed")
            matches = [x for x in items if x.get(key) == value]
            if len(matches) > 1:
                m.fail_json(
                    msg="Ambiguous Keycloak object; resolve duplicate names manually"
                )
            if not matches:
                api(prefix + path, "POST", desired)
                changed = True
                _, items = api(prefix + path)
                matches = [x for x in items if x.get(key) == value]
            item = matches[0]
            if not subset(item, desired):
                api(prefix + path + "/" + item["id"], "PUT", {**item, **desired})
                changed = True
            return item

        config = {
            k: [v]
            for k, v in dict(
                enabled="true",
                priority="0",
                editMode="READ_ONLY",
                syncRegistrations="false",
                importEnabled="true",
                vendor="other",
                usernameLDAPAttribute="uid",
                rdnLDAPAttribute="uid",
                uuidLDAPAttribute="entryUUID",
                userObjectClasses="person,organizationalPerson,inetOrgPerson",
                connectionUrl="ldap://openldap:389",
                usersDn="ou=people,dc=my,dc=org",
                authType="simple",
                bindDn="cn=admin,dc=my,dc=org",
                bindCredential="admin",
                trustEmail="true",
                pagination="true",
                searchScope="2",
                batchSizeForSync="1000",
            ).items()
        }
        # Keycloak masks bindCredential; compare other fields, supply it only on creation.
        _, components = api(prefix + "components")
        provider = next((x for x in components if x.get("name") == "zt-ldap"), None)
        desired = dict(
            name="zt-ldap",
            providerId="ldap",
            providerType="org.keycloak.storage.UserStorageProvider",
            parentId=realm["id"],
            config=config,
        )
        if provider:
            desired["config"].pop("bindCredential")
            actual_config = provider.get("config", {})
            if not subset(actual_config, desired["config"]):
                desired["config"] = {**actual_config, **desired["config"]}
                api(
                    prefix + "components/" + provider["id"],
                    "PUT",
                    {**provider, **desired},
                )
                changed = True
        else:
            provider = collection("components", "name", "zt-ldap", desired)
        mapper_config = {
            k: [v]
            for k, v in {
                "groups.dn": "ou=groups,dc=my,dc=org",
                "group.name.ldap.attribute": "cn",
                "group.object.classes": "posixGroup",
                "membership.attribute.type": "UID",
                "membership.ldap.attribute": "memberUid",
                "membership.user.ldap.attribute": "uid",
                "mode": "READ_ONLY",
                "user.roles.retrieve.strategy": "LOAD_GROUPS_BY_MEMBER_ATTRIBUTE",
                "groups.path": "/",
                "drop.non.existing.groups.during.sync": "false",
            }.items()
        }
        collection(
            "components",
            "name",
            "zt-groups",
            dict(
                name="zt-groups",
                providerId="group-ldap-mapper",
                providerType="org.keycloak.storage.ldap.mappers.LDAPStorageMapper",
                parentId=provider["id"],
                config=mapper_config,
            ),
        )
        for name in ["viewer", "support", "admin"]:
            code, _ = api(prefix + "roles/" + name)
            if code == 404:
                api(prefix + "roles", "POST", {"name": name})
                changed = True
        attrs = {}
        if "ciba" in p["features"]:
            attrs = {
                "oidc.ciba.grant.enabled": "true",
                "ciba.backchannel.token.delivery.mode": "poll",
            }
        backend = collection(
            "clients",
            "clientId",
            "backend",
            dict(
                clientId="backend",
                name="backend",
                enabled=True,
                protocol="openid-connect",
                publicClient=False,
                clientAuthenticatorType="client-secret",
                directAccessGrantsEnabled=True,
                standardFlowEnabled=True,
                attributes=attrs,
            ),
        )
        frontend = collection(
            "clients",
            "clientId",
            "zero-trust-app",
            dict(
                clientId="zero-trust-app",
                enabled=True,
                protocol="openid-connect",
                publicClient=True,
                directAccessGrantsEnabled=True,
                standardFlowEnabled=True,
                redirectUris=[f"http://localhost:{p['frontend_port']}/*"],
                webOrigins=[f"http://localhost:{p['frontend_port']}"],
                attributes={"pkce.code.challenge.method": "S256"},
            ),
        )
        _, secret = api(prefix + "clients/" + backend["id"] + "/client-secret")
        sf = Path(p["private"]) / "keycloak.json"
        desired_secret = {"client_secret": secret["value"]}
        if not sf.exists() or json.loads(sf.read_text()) != desired_secret:
            save(sf, desired_secret)
            changed = True
        if "ciba" in p["features"]:
            attributes = {
                **realm.get("attributes", {}),
                "cibaBackchannelTokenDeliveryMode": "poll",
                "cibaExpiresIn": "120",
                "cibaInterval": "5",
                "cibaAuthRequestedUserHint": "login_hint",
            }
            ensure("realms/zero-trust", {"attributes": attributes})
        # Sync only if actual LDAP user/group objects are absent, not every repeat.
        _, users = api(prefix + "users?username=repping&exact=true")
        _, groups = api(prefix + "groups")
        if not users or not all(
            any(g.get("name") == r for g in groups)
            for r in ["viewer", "support", "admin"]
        ):
            api(
                prefix
                + "user-storage/"
                + provider["id"]
                + "/sync?action=triggerFullSync",
                "POST",
            )
            changed = True
            _, groups = api(prefix + "groups")
        for name in ["viewer", "support", "admin"]:
            group = next((g for g in groups if g.get("name") == name), None)
            if not group:
                m.fail_json(msg="LDAP federation has not produced expected groups")
            _, roles = api(prefix + "groups/" + group["id"] + "/role-mappings/realm")
            if not any(r["name"] == name for r in roles):
                _, role = api(prefix + "roles/" + name)
                api(
                    prefix + "groups/" + group["id"] + "/role-mappings/realm",
                    "POST",
                    [role],
                )
                changed = True
        m.exit_json(changed=changed)
    except (OSError, ValueError, KeyError, IndexError):
        m.fail_json(
            msg="Keycloak reconciliation failed; inspect federation readiness and client configuration"
        )


if __name__ == "__main__":
    main()
