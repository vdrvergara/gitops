#!/usr/bin/env ansible-playbook
- name: Secret injection of validated-patterns
  hosts: localhost
  connection: local
  gather_facts: no
  vars:
    kubeconfig: "{{ lookup('env', 'KUBECONFIG') }}"
    kubeconfig_backup: "{{ lookup('env', 'HOME') }}/.kube/config"
    values_secret: "{{ lookup('env', 'HOME') }}/values-secret.yaml"
    vault_ns: "vault"
    vault_pod: "vault-0"
    vault_path: "secret/hub"
    debug: False

  tasks:
  - name: Check if the kubernetes python module is usable from ansible
    ansible.builtin.shell: "{{ ansible_python_interpreter }} -c 'import kubernetes'"

  - name: Check for existence of "{{ values_secret }}"
    ansible.builtin.stat:
      path: "{{ values_secret }}"
    register: result
    failed_when: not result.stat.exists

  - name: Check if KUBECONFIG is correctly set
    debug:
      msg: "KUBECONFIG is not set, falling back to ~/.kube/config"
    when: kubeconfig is not defined or kubeconfig | length == 0

  - name: Check if ~/.kube/config exists
    ansible.builtin.stat:
      path: "{{ kubeconfig_backup }}"
    register: kubeconfig_result

  - name: Fail if both KUBECONFIG and ~/.kube/config do not exist
    ansible.builtin.fail:
      msg: "{{ kubeconfig_backup }} not found and KUBECONFIG unset. Bailing out."
    failed_when: not kubeconfig_result.stat.exists and (kubeconfig is not defined or kubeconfig | length == 0)

  - name: Parse "{{ values_secret }}"
    ansible.builtin.set_fact:
      all_values: "{{ lookup('file', values_secret) | from_yaml }}"

  - name: Set secrets fact
    ansible.builtin.set_fact:
      secrets: "{{ all_values['secrets'] }}"

  - name: Verify we have any secrets at all
    ansible.builtin.fail:
      msg: "Was not able to parse any secrets from file {{ values_secret }}: {{ all_values }}"
    failed_when:
      secrets is not defined or secrets | length == 0

  - name: Check the value-secret.yaml file for errors
    ansible.builtin.fail:
      msg: >
        "{{ item }}" is not properly formatted. Each key under 'secrets:'
        needs to point to a dictionary of key, value pairs. See values-secret.yaml.template.
    when: >
      item.key | length == 0 or
      item.value is not mapping
    loop:
      "{{ secrets | dict2items }}"
    loop_control:
      label: "{{ item.key }}"

  # Detect here if we have only the following two keys under a password
  # s3.accessKey: <accessKey>
  # s3.secretKey: <secret key>
  # If we do, then detect it and calculate the b64 s3Secret token
  # Note: the vars: line is due to https://github.com/ansible/ansible/issues/40239
  - name: Check if any of the passwords has only s3.[accessKey,secretKey] and generate the combined s3Secret in that case
    ansible.builtin.set_fact:
      s3keys: "{{ s3keys | default({}) | combine({ item.key: {'s3Secret': s3secret | b64encode } }) }}"
    vars:
      s3secret: "{{ 's3.accessKey: ' + item.value['s3.accessKey'] + '\ns3.secretKey: ' + item.value['s3.secretKey'] }}"
    when:
      - '"s3.accessKey" in item.value.keys()'
      - '"s3.secretKey" in item.value.keys()'
      - '"s3Secret" not in item.value.keys()'
    loop:
      "{{ secrets | dict2items }}"
    loop_control:
      label: "{{ item.key }}"

  - name: Merge any s3Secret into the secrets dictionary if we have any
    ansible.builtin.set_fact:
      secrets: "{{ secrets | combine(s3keys) }}"
    when:
      s3keys is defined and s3keys | length > 0

  - name: Check for vault namespace
    kubernetes.core.k8s_info:
      kind: Namespace
      name: "{{ vault_ns }}"
    register: vault_ns_rc
    failed_when: vault_ns_rc.resources | length == 0
    when: not debug | bool

  - name: Check if the vault pod is present
    kubernetes.core.k8s_info:
      kind: Pod
      namespace: "{{ vault_ns }}"
      name: "{{ vault_pod }}"
    register: vault_pod_rc
    failed_when: vault_pod_rc.resources | length == 0
    when: not debug | bool

  # vault status returns 1 on error and 2 on sealed
  # so we can bail out when sealed
  - name: Check if the vault is unsealed
    kubernetes.core.k8s_exec:
      namespace: "{{ vault_ns }}"
      pod: "{{ vault_pod }}"
      command: vault status
    register: vault_status
    failed_when: vault_status.rc|int == 1
    when: not debug | bool

  - name: Check vault status return
    ansible.builtin.fail:
      msg: The vault is still sealed. Please run "make vault-init" first with KUBECONFIG pointing to the HUB cluster
    when:
      - not debug | bool
      - vault_status.rc | int > 0

# The values-secret.yaml file is in the fairly loose form of:
# secrets:
#   group1:
#     key1: value1
#     key2: value2
#   group2:
#     key1: valueA
#     key4: valueC
# The above will generate:
# vault kv put 'secret/hub/group1' key1='value1' key2='value2'
# vault kv put 'secret/hub/group2' key1='valueA' key4='valueC'
# Below we loop on the top level keys (group1, group2) and for each
# sub-top-level key (key1, key2) we create a single 'key1=value1 key2=value2' string
#
# Special note is to be given to the regex_replace which is run against each value aka password:
# A. The need for it is to quote the passwords
# B. Since it needs to cater to multiline strings (certs) and ansible offers no way
#    to specify re.DOTALL and re.MULTILINE we need to use (?ms) at the beginning
#    See https://docs.python.org/3/library/re.html and (?aiLmsux) section
#    and https://github.com/ansible/ansible/blob/devel/lib/ansible/plugins/filter/core.py#L124
# C. The \\A and \\Z match the beginning and end of a string (in case of multiline strings
#    do not want to match every line)
  - name: Set vault commands fact
    ansible.builtin.set_fact:
      vault_cmds: "{{ vault_cmds | default({}) | combine({ item.key: vault_cmd}) }}"
    vars:
      vault_cmd: "vault kv put '{{ vault_path }}/{{ item.key }}' {{ item.value.keys() | zip(item.value.values() | map('regex_replace', '(?ms)\\A(.*)\\Z', \"'\\1'\")) | map('join', '=') | list | join(' ') }}"
    loop:
      "{{ secrets | dict2items }}"
    loop_control:
      label: "{{ item.key }}"

  - name: Debug vault commands
    ansible.builtin.debug:
      msg: "{{ vault_cmds }}"
    when: debug | bool

  - name: Add the actual secrets to the vault
    kubernetes.core.k8s_exec:
      namespace: "{{ vault_ns }}"
      pod: "{{ vault_pod }}"
      command: |
        sh -c "{{ item.value }}"
    loop:
      "{{ vault_cmds | dict2items }}"
    loop_control:
      label: "{{ item.key }}"
    when: not debug | bool
