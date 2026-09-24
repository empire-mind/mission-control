name: Bug report
description: Something isn't working as documented
labels: [bug]
body:
  - type: markdown
    attributes:
      value: |
        Thanks for reporting. Before opening, please check the README's
        "Honest limits" section — the behavior you saw may be a documented limit.
  - type: input
    id: version
    attributes:
      label: Version / commit
      description: Output of `--version`, or the commit SHA you ran.
    validations:
      required: true
  - type: textarea
    id: repro
    attributes:
      label: Minimal reproduction
      description: The smallest command / input that shows the bug.
      placeholder: |
        python3 guardian.py --cmd 'rm -rf /tmp/build'
        # expected: WARN rm_recursive
        # actual: clean
    validations:
      required: true
  - type: textarea
    id: context
    attributes:
      label: Environment
      description: OS, Python version, how you installed it.
