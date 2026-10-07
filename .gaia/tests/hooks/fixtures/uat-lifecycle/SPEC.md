---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: the shopper's cart holds a "Tea & Biscuits" bundle at C:\shop
    when: they press the confirm button & wait for the receipt
    then: the page shows Confirmed for the shopper's "Tea & Biscuits" order at C:\shop
  - uat_id: UAT-002
    given: a stored order record
    when: the totals helper runs
    then: the total equals the sum of the line items
---
# Fixture SPEC

Fixture data for the lifecycle suite. Nothing reads the body.
