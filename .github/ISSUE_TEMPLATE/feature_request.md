name: Feature request
description: Propose a new check, command, or improvement
labels: [enhancement]
body:
  - type: textarea
    id: problem
    attributes:
      label: What problem does this solve?
      description: Who hits this, and what goes wrong today?
    validations:
      required: true
  - type: textarea
    id: proposal
    attributes:
      label: Proposed change
      description: Concrete behavior. Include an example if you can.
  - type: checkboxes
    id: willing
    attributes:
      label: Are you willing to implement this?
      options:
        - label: Yes, I'd like to take this on (we'll help you scope it)
