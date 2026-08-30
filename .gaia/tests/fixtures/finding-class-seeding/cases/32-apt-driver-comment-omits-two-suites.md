# 32-apt-driver-comment-omits-two-suites

**Path**: `.github/workflows/audit-ci-tests.yml`
**Line**: 614

## Title

The comment naming which suites drive the apt install list names most of them, and two
suites that also drive it are absent from the comment.

## Failure mode

The comment above the `fromJSON` list exists so a maintainer editing a suite knows
whether the edit can change what the job installs. It names the suites the writer walked
and stops there; two further suites in other shards also require a package from that
list. A maintainer editing one of the two reads the comment, does not find their suite,
and concludes the apt list is unaffected. The `fromJSON` list itself is derived and
correct, so nothing executes the comment and nothing reds; the cost lands on the next
person who trusts it to scope their change.

## Verified by

Derived the real driver set by grepping each shard's suites for the packages named in
the list, and compared it against the names in the comment: two suites drive the list
and appear nowhere in it.

## Suggested fix

Derive the comment's set the same way the list is derived, or drop the names and point
at the derivation, so the comment cannot be shorter than the set it describes.
