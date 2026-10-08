
def usage_pr_scope($usage_records; $reference_set):
  (reduce ((($usage_records[] | select(.kind == "binding" and (.type == "research" or .type == "declare" or .type == "close")
                and (.ref | type) == "string" and $reference_set[.ref] == true)))
           | .session_id | tojson) as $session ({}; .[$session] = true)) as $session_set
  | {segs: [$usage_records[] | select(.kind == "segment" and $session_set[.session_id | tojson] == true)],
     bindings: [$usage_records[] | select(.kind == "binding" and $session_set[.session_id | tojson] == true)]};
