
def usage_pr_scope($usage_records; $reference_set):
  (reduce ((($usage_records[] | select(.kind == "segment" and (.key | type) == "string" and $reference_set[.key] == true)))
           | .session_id | tojson) as $session ({}; .[$session] = true)) as $session_set
  | {segs: [$usage_records[] | select(.kind == "segment" and $session_set[.session_id | tojson] == true)],
     bindings: [$usage_records[] | select(.kind == "binding" and $session_set[.session_id | tojson] == true)]};
